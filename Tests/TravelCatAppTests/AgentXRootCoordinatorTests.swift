import XCTest
@testable import TravelCatApp

final class AgentXRootCoordinatorTests: XCTestCase {
    func testOfflineMigrationPublishesRootRebindingEvidenceWithoutEditingSource() throws {
        let base = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("RootEvidence-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("old"), destination = base.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("state".utf8).write(to: source.appendingPathComponent("data"))
        let coordinator = AgentXRootCoordinator(locator: base.appendingPathComponent("host/location.json"))
        try coordinator.migrate(from: source, to: destination, isIdle: true)
        let marker = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: destination.appendingPathComponent("manager/root-relocation.json"))) as? [String: Any])
        XCTAssertEqual(marker["version"] as? Int, 1)
        XCTAssertEqual(marker["sourceRoot"] as? String, source.path)
        XCTAssertEqual(marker["destinationRoot"] as? String, destination.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent("manager/root-relocation.json").path))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("data")), Data("state".utf8))
    }
    func testHistoryImportExcludesLiveRuntimeAndPreservesOriginal() throws {
        let base = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("AgentXRoots-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("legacy"), target = base.appendingPathComponent("imported")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("native-runtime"), withIntermediateDirectories: true)
        try Data("history".utf8).write(to: source.appendingPathComponent("workbench.sealed"))
        try Data("live".utf8).write(to: source.appendingPathComponent("native-runtime/session"))
        try AgentXRootCoordinator(locator: base.appendingPathComponent("locator.json")).importVerifiedTree(from: source, to: target, isIdle: true, excludedTopLevel: ["native-runtime"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("workbench.sealed").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("native-runtime").path))
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("native-runtime/session"), encoding: .utf8), "live")
    }
    func testOfflineImportPreservesSourceAndDoesNotChangeLocator() throws {
        let base = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("AgentXRoots-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("legacy"), target = base.appendingPathComponent("root/apps/blackcat/state/travel")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("history".utf8).write(to: source.appendingPathComponent("events.json"))
        let coordinator = AgentXRootCoordinator(locator: base.appendingPathComponent("host/location.json"))
        XCTAssertThrowsError(try coordinator.importVerifiedTree(from: source, to: target, isIdle: false))
        try coordinator.importVerifiedTree(from: source, to: target, isIdle: true)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("events.json")), try Data(contentsOf: target.appendingPathComponent("events.json")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: coordinator.locator.path))
    }
    func testSavedRootMustExistInsteadOfInitializingEmptyData() throws {
        let base = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("AgentXRoots-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let locator = base.appendingPathComponent("location.json")
        try JSONSerialization.data(withJSONObject: ["version": 1, "path": base.appendingPathComponent("missing").path]).write(to: locator)
        XCTAssertThrowsError(try AgentXRootCoordinator(locator: locator).resolve(fallback: base))
    }
    func testMigrationVerifiesContentsPreservesSourceAndPublishesLocator() throws {
        let base = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("AgentXRoots-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("old"), target = base.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("apps/a/state"), withIntermediateDirectories: true)
        let bytes = Data("app-owned data".utf8)
        try bytes.write(to: source.appendingPathComponent("apps/a/state/data"))
        let coordinator = AgentXRootCoordinator(locator: base.appendingPathComponent("host/location.json"))
        XCTAssertEqual(try coordinator.resolve(fallback: source), source)
        try coordinator.migrate(from: source, to: target, isIdle: true)
        XCTAssertEqual(try coordinator.resolve(fallback: source).path, target.path)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("apps/a/state/data")), bytes)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("apps/a/state/data")), bytes)
    }
    func testBusyAndVerificationFailureLeaveLocatorAndSourceUnchanged() throws {
        let base = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("AgentXRoots-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("old"), target = base.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: source.appendingPathComponent("file"))
        let coordinator = AgentXRootCoordinator(locator: base.appendingPathComponent("host/location.json"))
        XCTAssertThrowsError(try coordinator.migrate(from: source, to: target, isIdle: false))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertThrowsError(try coordinator.migrate(from: source, to: target, isIdle: true, verifyCopy: { url in
            try Data("corrupt".utf8).write(to: url.appendingPathComponent("file"))
        }))
        XCTAssertEqual(try coordinator.resolve(fallback: source), source)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("file"), encoding: .utf8), "original")
    }
    func testExistingDestinationAndLinkedDataAreRejected() throws {
        let base = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("AgentXRoots-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("old"), target = base.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let coordinator = AgentXRootCoordinator(locator: base.appendingPathComponent("host/location.json"))
        XCTAssertThrowsError(try coordinator.migrate(from: source, to: target, isIdle: true))
        XCTAssertThrowsError(try coordinator.migrate(from: source, to: source.appendingPathComponent("nested"), isIdle: true))
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("outside"), withDestinationURL: target)
        XCTAssertThrowsError(try coordinator.migrate(from: source, to: base.appendingPathComponent("third"), isIdle: true))
    }
}
