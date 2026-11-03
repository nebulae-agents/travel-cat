import Foundation
import XCTest
@testable import TravelCatApp

final class AgentXHostRestartTests: XCTestCase {
    private func temporaryRoot() -> URL {
        URL(fileURLWithPath: "/private/tmp").appendingPathComponent("AgentXRestart-\(UUID())")
    }
    private func write(_ text: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    /// Simulates a verified old-host receipt, but exercises real OS PID liveness.
    private func receipt(hostDirectory: URL, processID: Int32) throws {
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
            hostDirectory.appendingPathComponent("pending-migration.json"))) as? [String: Any])
        let requestID = try XCTUnwrap(request["id"] as? String)
        try JSONSerialization.data(withJSONObject: ["requestID": requestID, "processID": processID])
            .write(to: hostDirectory.appendingPathComponent("migration-exit.json"), options: .atomic)
    }
    private func exitedProcessID() throws -> Int32 {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run(); process.waitUntilExit()
        return process.processIdentifier
    }

    func testNextStartWaitsForRecordedOldProcessThenResolvesMovedRoot() throws {
        let base = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("source"), target = base.appendingPathComponent("target")
        let hostDirectory = base.appendingPathComponent("host")
        let repository = AgentXRepository(root: source)
        try repository.save(AgentXState())
        let relative = "apps/blackcat/state/travel/grants.yaml"
        let grants = "app: blackcat\nworkspace: apps/blackcat/workspace\n"
        try write(grants, at: source.appendingPathComponent(relative))
        let old = AgentXHostStorage(root: source, hostDirectory: hostDirectory)
        try old.requestMigration(to: target)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sleep"); process.arguments = ["1"]
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        try receipt(hostDirectory: hostDirectory, processID: process.processIdentifier)
        let next = AgentXHostStorage(root: source, hostDirectory: hostDirectory)
        XCTAssertFalse(next.previousHostHasExited())
        XCTAssertThrowsError(try next.applyPendingMigration(writersHaveStopped: next.previousHostHasExited))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        process.waitUntilExit()
        XCTAssertTrue(next.previousHostHasExited())
        XCTAssertEqual(try next.applyPendingMigration(writersHaveStopped: next.previousHostHasExited).path, target.path)
        XCTAssertEqual(try next.coordinator.resolve(fallback: source).path, target.path)
        XCTAssertEqual(try AgentXRepository(root: target).load().apps, AgentXState().apps)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent(relative), encoding: .utf8), grants)
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent(relative), encoding: .utf8), grants)
        XCTAssertFalse(next.hasPendingMigration)
    }

    func testNextStartDestinationConflictLeavesLocatorSourceAndRequestIntact() throws {
        let base = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("source"), target = base.appendingPathComponent("target")
        let host = AgentXHostStorage(root: source, hostDirectory: base.appendingPathComponent("host"))
        try write("original", at: source.appendingPathComponent("history"))
        try host.requestMigration(to: target)
        try receipt(hostDirectory: host.hostDirectory, processID: exitedProcessID())
        try write("unrelated", at: target.appendingPathComponent("keep"))
        XCTAssertThrowsError(try host.applyPendingMigration(writersHaveStopped: host.previousHostHasExited))
        XCTAssertEqual(try host.coordinator.resolve(fallback: source).path, source.path)
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("history"), encoding: .utf8), "original")
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("keep"), encoding: .utf8), "unrelated")
        XCTAssertTrue(host.hasPendingMigration)
        try host.revokeExitReceipt()
        XCTAssertFalse(host.previousHostHasExited())
    }

    func testNextStartImportsBlackCatBeforeBlockedWorkbenchAndCanRetry() throws {
        let base = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("source")
        let blackCat = base.appendingPathComponent("old-cat"), workbench = base.appendingPathComponent("old-workbench")
        try write("cat history", at: blackCat.appendingPathComponent("history"))
        try write("workbench history", at: workbench.appendingPathComponent("history"))
        try write("live runtime remains here", at: workbench.appendingPathComponent("native-runtime/profile/db"))
        let first = AgentXHostStorage(root: source, hostDirectory: base.appendingPathComponent("host"))
        XCTAssertThrowsError(try first.prepareAppData(at: first.workbenchRoot, legacy: workbench))
        XCTAssertThrowsError(try first.prepareAppData(at: first.blackCatRoot, legacy: blackCat))
        try receipt(hostDirectory: first.hostDirectory, processID: exitedProcessID())
        let next = AgentXHostStorage(root: source, hostDirectory: first.hostDirectory)
        XCTAssertThrowsError(try next.applyPendingMigration(writersHaveStopped: next.previousHostHasExited,
            inspectLegacyWorkbench: { _ in throw CocoaError(.fileReadNoPermission) }))
        XCTAssertEqual(try String(contentsOf: next.blackCatRoot.appendingPathComponent("history"), encoding: .utf8), "cat history")
        XCTAssertFalse(FileManager.default.fileExists(atPath: next.workbenchRoot.path))
        XCTAssertTrue(next.hasPendingMigration)
        try next.revokeExitReceipt()
        XCTAssertThrowsError(try next.applyPendingMigration(writersHaveStopped: next.previousHostHasExited))
        try receipt(hostDirectory: next.hostDirectory, processID: exitedProcessID())
        _ = try next.applyPendingMigration(writersHaveStopped: next.previousHostHasExited)
        XCTAssertTrue(next.workbenchNeedsRebinding)
        XCTAssertFalse(FileManager.default.fileExists(atPath: next.workbenchRoot.appendingPathComponent("native-runtime").path))
        XCTAssertEqual(try String(contentsOf: next.workbenchRoot.appendingPathComponent("history"), encoding: .utf8), "workbench history")
        XCTAssertEqual(try String(contentsOf: workbench.appendingPathComponent("native-runtime/profile/db"), encoding: .utf8), "live runtime remains here")
        XCTAssertEqual(try String(contentsOf: blackCat.appendingPathComponent("history"), encoding: .utf8), "cat history")
        XCTAssertFalse(next.hasPendingMigration)
    }

    func testSymlinkAncestorCannotReceiveImportOrRebindingMarker() throws {
        let base = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let legacy = base.appendingPathComponent("legacy"), outside = base.appendingPathComponent("outside")
        let host = AgentXHostStorage(root: base.appendingPathComponent("root"), hostDirectory: base.appendingPathComponent("host"))
        try write("history", at: legacy.appendingPathComponent("history"))
        XCTAssertThrowsError(try host.prepareAppData(at: host.workbenchRoot, legacy: legacy))
        try FileManager.default.createDirectory(at: host.root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: host.root.appendingPathComponent("apps"), withDestinationURL: outside)
        XCTAssertThrowsError(try host.applyPendingMigration(writersHaveStopped: { true }))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        XCTAssertTrue(host.hasPendingMigration)
    }
}
