import Foundation
import XCTest
import AgentXAppSDK
@testable import TravelCatApp

final class AgentXAppLifecycleHostTests: XCTestCase {
    func fixture() throws -> URL {
        let base = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("AppHost-\(UUID())")
        var state = AgentXState()
        state.apps += [.init(id: "a", name: "Alpha", kind: .chat), .init(id: "b", name: "Beta", kind: .chat)]
        try AgentXRepository(root: base.appendingPathComponent("root")).save(state)
        try Data("private user state".utf8).write(to: base.appendingPathComponent("root/apps/a/state/note"))
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return base
    }
    func manifest(_ version: String = "1", id: String = "a", name: String = "Alpha", schema: Int = 1) -> AppManifest {
        AppManifest(id: id, name: name, version: version, dataSchemaVersion: schema, hostAPIMajor: 1, kind: "chat", runtime: "native", modules: [])
    }
    func testRegistrationExportUpgradeAndRollbackPreserveStateAndYAML() throws {
        let base = try fixture(), root = base.appendingPathComponent("root")
        let host = try AgentXAppLifecycleHost(root: root, hostAPIMajor: 1, writersHaveStopped: { true })
        let settings = try Data(contentsOf: root.appendingPathComponent("agentx.yaml"))
        let sibling = try Data(contentsOf: root.appendingPathComponent("apps/b/app.yaml"))
        try host.register(appID: "a", manifest: manifest())
        let exported = base.appendingPathComponent("package")
        try host.exportPackage(appID: "a", to: exported)
        XCTAssertFalse(FileManager.default.fileExists(atPath: exported.appendingPathComponent("state").path))
        try JSONEncoder().encode(manifest("2", name: "Alpha Two")).write(to: exported.appendingPathComponent("manifest.json"))
        try Data("new code".utf8).write(to: exported.appendingPathComponent("payload/code"))
        let receipt = try host.upgrade(appID: "a", package: exported)
        XCTAssertEqual(try AgentXRepository(root: root).load().apps.first { $0.id == "a" }?.name, "Alpha Two")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("apps/a/state/note"), encoding: .utf8), "private user state")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("agentx.yaml")), settings)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("apps/b/app.yaml")), sibling)
        try host.rollback(receipt)
        XCTAssertEqual(try AgentXRepository(root: root).load().apps.first { $0.id == "a" }?.name, "Alpha")
    }
    func testImportRejectsOverwriteAndRunsAndExportsNoUserData() throws {
        let base = try fixture(), root = base.appendingPathComponent("root")
        let host = try AgentXAppLifecycleHost(root: root, hostAPIMajor: 1, writersHaveStopped: { true })
        try host.register(appID: "a", manifest: manifest())
        let package = base.appendingPathComponent("package")
        try host.exportPackage(appID: "a", to: package)
        XCTAssertThrowsError(try host.importPackage(from: package))
        try JSONEncoder().encode(manifest(id: "c", name: "Gamma")).write(to: package.appendingPathComponent("manifest.json"))
        try host.importPackage(from: package)
        XCTAssertTrue(try AgentXRepository(root: root).load().apps.contains { $0.id == "c" })
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("apps/c/state/note").path))
        let busy = try AgentXAppLifecycleHost(root: root, hostAPIMajor: 1, writersHaveStopped: { false })
        XCTAssertThrowsError(try busy.exportPackage(appID: "a", to: base.appendingPathComponent("blocked")))
        var state = try AgentXRepository(root: root).load()
        state.runs = [.init(id: "run", appID: "a", instanceID: "unused", prompt: "p", status: .running)]
        // Write a real persisted run without requiring an unrelated instance/provider fixture.
        try JSONEncoder().encode(state.runs[0]).write(to: root.appendingPathComponent("apps/a/runs/run.json"))
        XCTAssertThrowsError(try host.exportPackage(appID: "a", to: base.appendingPathComponent("running")))
    }
    func testMissingBaselineAndMaliciousPackageAreRejectedWithoutStateChanges() throws {
        let base = try fixture(), root = base.appendingPathComponent("root")
        let host = try AgentXAppLifecycleHost(root: root, hostAPIMajor: 1, writersHaveStopped: { true })
        XCTAssertThrowsError(try host.exportPackage(appID: "a", to: base.appendingPathComponent("no-baseline")))
        XCTAssertThrowsError(try host.register(appID: "a", manifest: manifest(id: "b")))
        try host.register(appID: "a", manifest: manifest())
        let package = base.appendingPathComponent("package")
        try host.exportPackage(appID: "a", to: package)
        try FileManager.default.createSymbolicLink(at: package.appendingPathComponent("payload/link"), withDestinationURL: root.appendingPathComponent("apps/b"))
        XCTAssertThrowsError(try host.upgrade(appID: "a", package: package))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("apps/a/state/note"), encoding: .utf8), "private user state")
    }
    func testFullBackupIncludesStateButPendingUpgradeBlocksImport() throws {
        let base = try fixture(), root = base.appendingPathComponent("root")
        let host = try AgentXAppLifecycleHost(root: root, hostAPIMajor: 1, writersHaveStopped: { true })
        try host.register(appID: "a", manifest: manifest())
        let backup = base.appendingPathComponent("a-full-backup")
        try host.backupApplication(appID: "a", to: backup)
        XCTAssertEqual(try String(contentsOf: backup.appendingPathComponent("state/note"), encoding: .utf8), "private user state")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.appendingPathComponent("app.yaml").path))
        let package = base.appendingPathComponent("package")
        try host.exportPackage(appID: "a", to: package)
        try JSONEncoder().encode(manifest(id: "c", name: "Gamma")).write(to: package.appendingPathComponent("manifest.json"))
        let pending = root.appendingPathComponent("backups/apps/c")
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: pending.appendingPathComponent("pending.json"))
        XCTAssertThrowsError(try host.importPackage(from: package))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("apps/c").path))
    }

}
