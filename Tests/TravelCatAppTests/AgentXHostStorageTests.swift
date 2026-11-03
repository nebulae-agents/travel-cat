import XCTest
@testable import TravelCatApp

final class AgentXHostStorageTests: XCTestCase {
    func testRootOverridesHaveSeparateHostLocatorsAndSkipLegacyImport() throws {
        let base = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("HostIsolation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let support = base.appendingPathComponent("production")
        let a = try AgentXHostEnvironment(environment: ["AGENTX_ROOT": base.appendingPathComponent("a").path], applicationSupport: support)
        let b = try AgentXHostEnvironment(environment: ["AGENTX_ROOT": base.appendingPathComponent("b").path], applicationSupport: support)
        XCTAssertNotEqual(a.hostDirectory, b.hostDirectory)
        XCTAssertFalse(a.importsLegacyData)
        XCTAssertFalse(b.importsLegacyData)
        let host = AgentXHostStorage(root: a.fallbackRoot, hostDirectory: a.hostDirectory)
        try host.prepareAppData(at: host.blackCatRoot, legacy: nil)
        try host.requestMigration(to: base.appendingPathComponent("moved"))
        XCTAssertFalse(AgentXHostStorage(root: b.fallbackRoot, hostDirectory: b.hostDirectory).hasPendingMigration)
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.path))
    }
    func testDefaultHostPathsAndExplicitIsolatedHostOverride() throws {
        let support = URL(fileURLWithPath: "/private/tmp/fixture-support")
        let normal = try AgentXHostEnvironment(environment: [:], applicationSupport: support)
        XCTAssertEqual(normal.hostDirectory.path, support.appendingPathComponent("AgentXHost").path)
        XCTAssertTrue(normal.importsLegacyData)
        let isolated = try AgentXHostEnvironment(environment: ["AGENTX_ROOT": "/private/tmp/a", "AGENTX_HOST_DIRECTORY": "/private/tmp/custom-host"], applicationSupport: support)
        XCTAssertEqual(isolated.hostDirectory.path, "/private/tmp/custom-host")
        XCTAssertThrowsError(try AgentXHostEnvironment(environment: ["AGENTX_ROOT": "relative"], applicationSupport: support))
    }

    func testLegacyAutoImportCannotQueueAlongsideApplicationOperation() throws {
        let base = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("ImportConflict-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let host = AgentXHostStorage(root: base.appendingPathComponent("root"), hostDirectory: base.appendingPathComponent("host"))
        let legacy = base.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data([1]).write(to: legacy.appendingPathComponent("history"))
        try host.offlineLifecycle.request(.exportPackage(appID: "blackcat", destination: base.appendingPathComponent("export").path))
        XCTAssertThrowsError(try host.prepareAppData(at: host.blackCatRoot, legacy: legacy))
        XCTAssertFalse(host.hasPendingMigration)
        XCTAssertTrue(host.offlineLifecycle.hasPendingOperation)
        XCTAssertEqual(try Data(contentsOf: legacy.appendingPathComponent("history")), Data([1]))
    }

    func testNativeLiveDaemonPreventsRootPublish() throws {
        let base = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("DaemonGate-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let host = AgentXHostStorage(root: base.appendingPathComponent("root"), hostDirectory: base.appendingPathComponent("host"))
        let profile = host.workbenchRoot.appendingPathComponent("native-runtime/\(UUID().uuidString.lowercased())")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["pid": getpid()]).write(to: profile.appendingPathComponent("travelcat-daemon.json"))
        try host.requestMigration(to: base.appendingPathComponent("new"))
        XCTAssertFalse(host.nativeDaemonsHaveExited())
        XCTAssertThrowsError(try host.applyPendingMigration(writersHaveStopped: { true }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("new").path))
    }

    @MainActor
    func testShutdownPermanentlySealsExternalExecutors() async throws {
        let executor = CodexTravelExecutor()
        let stopped = await executor.shutdownAndWait(timeout: .seconds(1))
        XCTAssertTrue(stopped)
        do {
            _ = try await executor.run(prompt: "ignored", workspace: URL(fileURLWithPath: "/private/tmp"))
            XCTFail("Shutdown executor must reject new launches")
        } catch is CancellationError {} catch { XCTFail("Expected shutdown cancellation, got \(error)") }
        let sidecar = AgentSidecarClient()
        sidecar.shutdown()
        do {
            try sidecar.launch(python: "/private/tmp/nonexistent-shutdown-test-python")
            XCTFail("Shutdown sidecar must reject new launches")
        } catch is CancellationError {} catch { XCTFail("Expected shutdown cancellation, got \(error)") }
    }
    func testAppDataRejectsSymlinkDestination() throws {
        let base = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("Host-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let host = AgentXHostStorage(root: base.appendingPathComponent("root"), hostDirectory: base.appendingPathComponent("host"))
        let outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: host.blackCatRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: host.blackCatRoot, withDestinationURL: outside)
        XCTAssertThrowsError(try host.prepareAppData(at: host.blackCatRoot, legacy: base.appendingPathComponent("missing")))
    }
    func testReadOnlyWorkbenchDoesNotMigrateLegacyFile() throws {
        let base = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("ReadOnly-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let bytes = try JSONEncoder().encode(WorkbenchSnapshot())
        try bytes.write(to: base.appendingPathComponent("workbench.json"))
        let read = try EncryptedWorkbenchStorage(root: base, keyData: Data(repeating: 7, count: 32)).loadReadOnly()
        XCTAssertEqual(read, bytes)
        XCTAssertEqual(try Data(contentsOf: base.appendingPathComponent("workbench.json")), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("workbench.sealed").path))
    }
    func testLegacyImportRunsOnlyAfterOfflineReceiptAndKeepsSource() throws {
        let base = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("Import-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let legacy = base.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("history".utf8).write(to: legacy.appendingPathComponent("history"))
        let host = AgentXHostStorage(root: base.appendingPathComponent("root"), hostDirectory: base.appendingPathComponent("host"))
        XCTAssertThrowsError(try host.prepareAppData(at: host.workbenchRoot, legacy: legacy))
        XCTAssertTrue(host.hasPendingMigration)
        XCTAssertThrowsError(try host.applyPendingMigration(writersHaveStopped: { false }))
        _ = try host.applyPendingMigration(writersHaveStopped: { true })
        XCTAssertTrue(host.workbenchNeedsRebinding)
        XCTAssertEqual(try Data(contentsOf: host.workbenchRoot.appendingPathComponent("history")), Data("history".utf8))
        XCTAssertEqual(try Data(contentsOf: legacy.appendingPathComponent("history")), Data("history".utf8))
    }
    func testLayoutUsesRelativeAppDirectories() throws {
        let base = URL(fileURLWithPath: "/private/tmp/host-layout")
        let host = AgentXHostStorage(root: base, hostDirectory: base.appendingPathComponent("host"))
        XCTAssertEqual(host.blackCatRoot.path, base.appendingPathComponent("apps/blackcat/state/travel").path)
        XCTAssertEqual(host.workbenchRoot.path, base.appendingPathComponent("apps/workbench/state/runtime").path)
    }
    func testPendingMigrationDoesNotMoveUntilQuiescenceAndPreservesSource() throws {
        let base = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("Host-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("root"), target = base.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("history".utf8).write(to: root.appendingPathComponent("data"))
        let host = AgentXHostStorage(root: root, hostDirectory: base.appendingPathComponent("host"))
        try host.requestMigration(to: target)
        XCTAssertThrowsError(try host.applyPendingMigration(writersHaveStopped: { false }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try host.applyPendingMigration(writersHaveStopped: { true }).path, target.path)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("data")), Data("history".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("data").path))
    }
    func testLegacyDataRequiresExplicitOfflineImportAndDoesNotOverwrite() throws {
        let base = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("Host-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let legacy = base.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: legacy.appendingPathComponent("history"))
        let host = AgentXHostStorage(root: base.appendingPathComponent("root"), hostDirectory: base.appendingPathComponent("host"))
        XCTAssertThrowsError(try host.prepareAppData(at: host.blackCatRoot, legacy: legacy))
        XCTAssertFalse(FileManager.default.fileExists(atPath: host.blackCatRoot.path))
        try FileManager.default.createDirectory(at: host.blackCatRoot, withIntermediateDirectories: true)
        XCTAssertNoThrow(try host.prepareAppData(at: host.blackCatRoot, legacy: legacy))
        XCTAssertEqual(try Data(contentsOf: legacy.appendingPathComponent("history")), Data("legacy".utf8))
    }
}
