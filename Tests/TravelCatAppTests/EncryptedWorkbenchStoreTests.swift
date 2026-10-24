import Foundation
import XCTest
@testable import TravelCatApp

final class EncryptedWorkbenchStoreTests: XCTestCase {
    private let key = Data(repeating: 42, count: 32)
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func snapshot() -> WorkbenchSnapshot {
        let instance = WorkbenchInstance(name: "private-instance-canary", image: "private-image", command: ["private-command"])
        var task = WorkbenchTask(instanceID: instance.id, title: "private-title")
        task.messages = [WorkbenchMessage(role: "user", text: "plaintext-canary")]
        task.status = .running
        return WorkbenchSnapshot(instances: [instance], tasks: [task])
    }
    func testMigratesAndReopensWithoutPlaintextPreservingIdentityAndDates() throws {
        let root = try directory(), original = snapshot()
        let legacy = WorkbenchStore(root: root)
        try legacy.save(original)
        let store = WorkbenchStore(root: root, keyData: key)
        let recovered = try store.load()
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.url.path))
        XCTAssertEqual(store.url.lastPathComponent, "workbench.sealed")
        XCTAssertEqual(recovered.instances, original.instances)
        XCTAssertEqual(recovered.tasks[0].id, original.tasks[0].id)
        XCTAssertEqual(recovered.tasks[0].messages, original.tasks[0].messages)
        XCTAssertEqual(recovered.tasks[0].createdAt, original.tasks[0].createdAt)
        XCTAssertEqual(recovered.tasks[0].status, .unknown)
        let data = try Data(contentsOf: store.url)
        XCTAssertNil(data.range(of: Data("plaintext-canary".utf8)))
        XCTAssertNil(data.range(of: Data("private-instance-canary".utf8)))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try store.load().tasks[0].messages, original.tasks[0].messages)
    }
    func testWrongKeyNeverFallsBackToLegacy() throws {
        let root = try directory(), original = snapshot()
        let store = WorkbenchStore(root: root, keyData: key)
        try store.save(original)
        try WorkbenchStore(root: root).save(original)
        XCTAssertThrowsError(try WorkbenchStore(root: root, keyData: Data(repeating: 2, count: 32)).load())
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("workbench.json").path))
    }
    func testCorruptLegacyRemainsUntouched() throws {
        let root = try directory(), bytes = Data("broken".utf8)
        let legacy = root.appendingPathComponent("workbench.json")
        try bytes.write(to: legacy)
        let store = WorkbenchStore(root: root, keyData: key)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: legacy), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
    }
    func testConflictingFilesPreservedAndMatchingRunningSnapshotRecovered() throws {
        let root = try directory(), original = snapshot()
        let store = WorkbenchStore(root: root, keyData: key), legacy = WorkbenchStore(root: root)
        try store.save(original)
        let sealed = try Data(contentsOf: store.url)
        var other = original; other.tasks[0].title = "conflict"
        try legacy.save(other)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: store.url), sealed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.url.path))
        try legacy.save(original)
        XCTAssertEqual(try store.load().tasks[0].status, .unknown)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.url.path))
    }
    func testSymlinkFileAndDirectoryAreRejected() throws {
        let root = try directory(), target = try directory()
        let store = WorkbenchStore(root: root, keyData: key)
        try FileManager.default.createSymbolicLink(at: store.url, withDestinationURL: target.appendingPathComponent("missing"))
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(snapshot()))
        let link = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try WorkbenchStore(root: link, keyData: key).save(snapshot()))
    }
}

@MainActor
private final class EncryptedWorkbenchTestCredentials: TravelServiceCredentialStoring {
    var value: String?
    var writes = 0
    var ignoreWrites = false
    var readFailure = false
    func read(id: String) throws -> String? {
        XCTAssertEqual(id, "workbench-content-v1")
        if readFailure { throw WorkbenchFailure("test read failure") }
        return value
    }
    func save(_ secret: String?, id: String) throws {
        XCTAssertEqual(id, "workbench-content-v1")
        writes += 1
        if !ignoreWrites { value = secret }
    }
}

extension EncryptedWorkbenchStoreTests {
    @MainActor
    func testFactoryPreservesSealedDataWhenKeyMissingOrInvalid() throws {
        let root = try directory(), store = WorkbenchStore(root: root, keyData: key)
        try store.save(snapshot())
        let bytes = try Data(contentsOf: store.url), credentials = EncryptedWorkbenchTestCredentials()
        XCTAssertThrowsError(try WorkbenchStore.encrypted(root: root, credentials: credentials))
        credentials.value = "invalid"
        XCTAssertThrowsError(try WorkbenchStore.encrypted(root: root, credentials: credentials))
        XCTAssertEqual(credentials.writes, 0)
        XCTAssertEqual(try Data(contentsOf: store.url), bytes)
    }
    @MainActor
    func testFactoryRequiresCredentialReadbackAndNeverSwallowsReadFailure() throws {
        let root = try directory(), credentials = EncryptedWorkbenchTestCredentials()
        credentials.ignoreWrites = true
        XCTAssertThrowsError(try WorkbenchStore.encrypted(root: root, credentials: credentials))
        credentials.ignoreWrites = false
        credentials.readFailure = true
        XCTAssertThrowsError(try WorkbenchStore.encrypted(root: root, credentials: credentials))
        XCTAssertEqual(credentials.writes, 1)
        credentials.readFailure = false
        let store = try WorkbenchStore.encrypted(root: root, credentials: credentials)
        try store.save(snapshot())
        let reopened = try WorkbenchStore.encrypted(root: root, credentials: credentials)
        XCTAssertEqual(try reopened.load().tasks[0].messages[0].text, "plaintext-canary")
        XCTAssertEqual(credentials.writes, 2)
    }
    func testUnknownSchemaEnumAndOversizedLegacyStayUntouched() throws {
        let root = try directory(), store = WorkbenchStore(root: root, keyData: key)
        var original = snapshot()
        original.schemaVersion = 99
        let unknownSchema = try JSONEncoder().encode(original)
        original.schemaVersion = 1
        let encoded = try JSONEncoder().encode(original)
        let unknownEnum = Data(String(decoding: encoded, as: UTF8.self).replacingOccurrences(of: "running", with: "future-status").utf8)
        for bytes in [unknownSchema, unknownEnum] {
            try bytes.write(to: store.legacyURL)
            XCTAssertThrowsError(try store.load())
            XCTAssertEqual(try Data(contentsOf: store.legacyURL), bytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
        }
        let handle = try FileHandle(forWritingTo: store.legacyURL)
        try handle.truncate(atOffset: UInt64(64 * 1024 * 1024 + 1)); try handle.close()
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: store.legacyURL.path)[.size] as? NSNumber)?.intValue, 64 * 1024 * 1024 + 1)
    }
    func testCorruptCiphertextCannotBeOverwrittenOrReplacedByLegacy() throws {
        let root = try directory(), store = WorkbenchStore(root: root, keyData: key)
        try store.save(snapshot())
        var bytes = try Data(contentsOf: store.url)
        bytes[bytes.count - 1] ^= 1
        try bytes.write(to: store.url)
        try WorkbenchStore(root: root).save(snapshot())
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(snapshot()))
        XCTAssertEqual(try Data(contentsOf: store.url), bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.legacyURL.path))
    }
}
