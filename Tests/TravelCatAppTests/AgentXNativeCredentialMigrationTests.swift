import XCTest
@testable import TravelCatApp

final class AgentXNativeCredentialMigrationTests: XCTestCase {
    func testSymlinkedProfileIsRejectedBeforeReadingCredentials() throws {
        let base = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("KeyringSymlink-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("old"), target = base.appendingPathComponent("new")
        let directory = source.appendingPathComponent("apps/workbench/state/runtime/native-runtime")
        let outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent(UUID().uuidString), withDestinationURL: outside)
        var reads = 0
        let migrator = AgentXNativeCredentialMigration(read: { _ in reads += 1; return nil }, insert: { _, _ in XCTFail("must not insert") })
        XCTAssertThrowsError(try migrator.migrate(from: source, to: target))
        XCTAssertEqual(reads, 0)
    }
    func testCopiesOnlyManagedProfileCredentialsAndPreservesSource() throws {
        let base = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("KeyringFixture-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("old"), target = base.appendingPathComponent("new")
        let relative = "apps/workbench/state/runtime/native-runtime/11111111-1111-1111-1111-111111111111"
        let old = source.appendingPathComponent(relative), new = target.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        let a = AgentXNativeCredentialMigration.account(profile: old), b = AgentXNativeCredentialMigration.account(profile: new)
        var entries = [a: Data("opaque-test-fixture".utf8), "unrelated": Data([9])]
        let migrator = AgentXNativeCredentialMigration(read: { entries[$0] }, insert: { entries[$0] = $1 })
        try migrator.migrate(from: source, to: target)
        XCTAssertEqual(entries[a], entries[b])
        XCTAssertEqual(entries["unrelated"], Data([9]))
        XCTAssertEqual(entries.count, 3)
        try migrator.migrate(from: source, to: target)
        entries[b] = Data([8])
        XCTAssertThrowsError(try migrator.migrate(from: source, to: target))
        XCTAssertEqual(entries[b], Data([8]))
    }
    func testFailureOfTrustedHookDoesNotPublishLocatorOrDeleteSource() throws {
        let base = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("CredentialHook-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("old"), target = base.appendingPathComponent("new"), locator = base.appendingPathComponent("host/location.json")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data([7]).write(to: source.appendingPathComponent("source"))
        XCTAssertThrowsError(try AgentXRootCoordinator(locator: locator).migrate(from: source, to: target, isIdle: true, beforePublish: { _, _ in throw AgentXNativeCredentialMigration.Failure.conflict }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: locator.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("source")), Data([7]))
    }
}
