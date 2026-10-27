import Foundation
import XCTest
@testable import TravelCatApp

final class AgentAuditStoreTests: XCTestCase {
    @MainActor func testInvalidDirectoryDoesNotReplaceKey() throws {
        final class Credentials: TravelServiceCredentialStoring {
            var saves = 0
            func read(id: String) throws -> String? { nil }
            func save(_ secret: String?, id: String) throws { saves += 1 }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not-a-directory".utf8).write(to: root)
        let credentials = Credentials()
        XCTAssertThrowsError(try AgentAuditStore.open(root: root, credentials: credentials))
        XCTAssertEqual(credentials.saves, 0)
    }
    func testEncryptedJournalRoundTripAndTamperDetection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = Data(repeating: 7, count: 32)
        let task = UUID()
        let store = try AgentAuditStore(root: root, keyData: key)
        try store.append(record: ["eventId": UUID().uuidString, "taskId": task.uuidString, "kind": "model.request", "body": "private-canary-content"])
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        let file = try XCTUnwrap(files.first)
        let bytes = try Data(contentsOf: file)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("private-canary-content"))
        let reopened = try AgentAuditStore(root: root, keyData: key)
        XCTAssertEqual(try reopened.records(taskID: task).first?["body"] as? String, "private-canary-content")
        var damaged = bytes; damaged[damaged.count / 2] ^= 1
        try damaged.write(to: file)
        XCTAssertThrowsError(try reopened.records(taskID: task))
        XCTAssertThrowsError(try AgentAuditStore(root: root, keyData: key))
    }
    func testWrongKeyAndMissingEventFailClosed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = Data(repeating: 1, count: 32)
        let store = try AgentAuditStore(root: root, keyData: key)
        for _ in 0..<2 { try store.append(record: ["eventId": UUID().uuidString, "taskId": UUID().uuidString, "kind": "test"]) }
        XCTAssertThrowsError(try AgentAuditStore(root: root, keyData: Data(repeating: 2, count: 32)))
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
        try FileManager.default.removeItem(at: files[0])
        XCTAssertThrowsError(try AgentAuditStore(root: root, keyData: key))
    }
    func testSizeLimitAndPrivateFileMode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AgentAuditStore(root: root, keyData: Data(repeating: 3, count: 32))
        XCTAssertThrowsError(try store.append(record: ["eventId": UUID().uuidString, "taskId": UUID().uuidString, "kind": "test", "body": String(repeating: "x", count: 2 * 1024 * 1024)]))
        try store.append(record: ["eventId": UUID().uuidString, "taskId": UUID().uuidString, "kind": "test"])
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}
