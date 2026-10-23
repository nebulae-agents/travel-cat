import Foundation
import XCTest
@testable import TravelCatApp

@MainActor private final class SecureModelCredentials: TravelServiceCredentialStoring {
    var values: [String: String] = [:]
    var readError: Error?
    func read(id: String) throws -> String? { if let readError { throw readError }; return values[id] }
    func save(_ secret: String?, id: String) throws { values[id] = secret }
}
final class AgentSecureStorageModelTests: XCTestCase {
    @MainActor func testExportCannotTargetInternalDataOrSymlinkAlias() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let alias = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: alias); try? FileManager.default.removeItem(at: root) }
        let model = AgentWorkbenchModel(root: root, credentials: SecureModelCredentials())
        model.shutdown()
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        let original = try Data(contentsOf: root.appendingPathComponent("workbench.sealed"))
        for url in [root.appendingPathComponent("workbench.json"), root.appendingPathComponent("audit-v1/export.json"), alias.appendingPathComponent("audit-v1/export.json")] {
            XCTAssertThrowsError(try model.exportAudit(taskID: nil, includeContents: true, to: url))
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("workbench.sealed")), original)
        XCTAssertEqual(try model.auditInventory().records, 0)
    }
    @MainActor func testManualCleanupRecoversFullyExhaustedJournalWithNoAutomaticPolicy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let audit = try AgentAuditStore(root: root.appendingPathComponent("audit-v1"), keyData: Data(repeating: 7, count: 32), recordLimit: 34)
        for _ in 0..<34 { try audit.append(record: ["eventId": UUID().uuidString, "taskId": UUID().uuidString, "kind": "audit.export", "timestamp": "2020-01-01T00:00:00Z"]) }
        let model = AgentWorkbenchModel(root: root, credentials: SecureModelCredentials(), auditStore: audit)
        XCTAssertNil(model.state.auditRetentionDays)
        XCTAssertThrowsError(try model.setAuditRetention(days: 7))
        let cutoff = Date().addingTimeInterval(-7 * 86400)
        let preview = try model.retentionPreview(before: cutoff)
        XCTAssertEqual(preview.removableCount, 34)
        try model.pruneAudit(before: cutoff, expectedHead: preview.head)
        XCTAssertEqual(try model.auditInventory().records, 0)
        XCTAssertNil(model.state.auditRetentionDays)
        try model.setAuditRetention(days: 7)
        XCTAssertEqual(model.state.auditRetentionDays, 7)
        model.shutdown()
    }
    @MainActor func testModelMigratesLegacyAndReopensEncryptedConversation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var snapshot = WorkbenchSnapshot()
        var task = WorkbenchTask(instanceID: UUID(), title: "private-title-canary")
        task.messages = [.init(role: "user", text: "private-message-canary")]
        snapshot.tasks = [task]
        try WorkbenchStore(root: root).save(snapshot)
        let credentials = SecureModelCredentials()
        let model = AgentWorkbenchModel(root: root, credentials: credentials)
        XCTAssertEqual(model.state.tasks.first?.messages.first?.text, "private-message-canary")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("workbench.json").path))
        let sealed = try Data(contentsOf: root.appendingPathComponent("workbench.sealed"))
        XCTAssertFalse(String(decoding: sealed, as: UTF8.self).contains("private-message-canary"))
        model.shutdown()
        let reopened = AgentWorkbenchModel(root: root, credentials: credentials)
        XCTAssertEqual(reopened.state.tasks.first?.id, task.id)
        XCTAssertEqual(reopened.state.tasks.first?.messages.first?.text, "private-message-canary")
        reopened.shutdown()
    }
    @MainActor func testMissingKeyPreservesCiphertextAndDisablesWrites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = SecureModelCredentials()
        let model = AgentWorkbenchModel(root: root, credentials: credentials)
        model.shutdown()
        let url = root.appendingPathComponent("workbench.sealed")
        let before = try Data(contentsOf: url)
        credentials.values.removeValue(forKey: "workbench-content-v1")
        let reopened = AgentWorkbenchModel(root: root, credentials: credentials)
        XCTAssertNotNil(reopened.error)
        reopened.shutdown()
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertNil(credentials.values["workbench-content-v1"])
    }
    @MainActor func testStorageReadErrorPreservesActionableKeychainReason() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = SecureModelCredentials()
        credentials.readError = TravelServiceCredentialError.keychain(-25308)
        let model = AgentWorkbenchModel(root: root, credentials: credentials)
        XCTAssertTrue(model.error?.contains("-25308") == true)
        XCTAssertTrue(model.error?.contains("钥匙串") == true)
        model.shutdown()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("workbench.sealed").path))
    }

}
