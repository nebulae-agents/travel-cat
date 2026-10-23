import Foundation
import XCTest
@testable import TravelCatApp

final class AgentAuditLifecycleTests: XCTestCase {
    @MainActor func testAuditKeyFactoryRejectsUnpersistedAndMalformedKeys() throws {
        final class Credentials: TravelServiceCredentialStoring {
            var value: String?; var saves = 0
            func read(id: String) throws -> String? { value }
            func save(_ secret: String?, id: String) throws { saves += 1 }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = Credentials()
        XCTAssertThrowsError(try AgentAuditStore.open(root: root, credentials: credentials))
        credentials.value = "invalid-key"; credentials.saves = 0
        XCTAssertThrowsError(try AgentAuditStore.open(root: root, credentials: credentials))
        XCTAssertEqual(credentials.saves, 0)
    }
    func testInterruptedPrefixCleanupRecoversAndContinuesChain() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = Data(repeating: 5, count: 32), task = UUID()
        let store = try AgentAuditStore(root: root, keyData: key)
        try store.append(record: ["eventId": UUID().uuidString, "taskId": task.uuidString, "kind": "test", "timestamp": "2020-01-01T00:00:00Z"])
        let retired = root.appendingPathComponent("00000000000000000001.event")
        let bytes = try Data(contentsOf: retired)
        let preview = try store.retentionPreview(before: Date())
        _ = try store.prune(before: Date(), expectedHead: preview.head)
        try bytes.write(to: retired)
        let reopened = try AgentAuditStore(root: root, keyData: key)
        XCTAssertFalse(FileManager.default.fileExists(atPath: retired.path))
        try reopened.append(record: ["eventId": UUID().uuidString, "taskId": task.uuidString, "kind": "test"])
        XCTAssertEqual(try reopened.records(taskID: task).count, 1)
        XCTAssertEqual(try reopened.inventory().retiredRecords, 1)
    }
    func testCapacityReservesManagementAndTamperStillBlocksExport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AgentAuditStore(root: root, keyData: Data(repeating: 6, count: 32), recordLimit: 34)
        let task = UUID()
        func event(_ kind: String) -> [String: Any] { ["eventId": UUID().uuidString, "taskId": task.uuidString, "kind": kind, "timestamp": "2020-01-01T00:00:00Z"] }
        try store.append(record: event("model.request")); try store.append(record: event("model.response"))
        XCTAssertThrowsError(try store.append(record: event("model.request")))
        try store.append(record: event("audit.export"))
        XCTAssertFalse(try store.exportData(taskID: nil, includeContents: false).isEmpty)
        let preview = try store.retentionPreview(before: Date())
        XCTAssertEqual(try store.prune(before: Date(), expectedHead: preview.head), 3)
        try store.append(record: event("model.request"))
        let file = root.appendingPathComponent("00000000000000000004.event")
        var bytes = try Data(contentsOf: file); bytes[0] ^= 1; try bytes.write(to: file)
        XCTAssertThrowsError(try store.exportData(taskID: nil, includeContents: false))
        XCTAssertThrowsError(try store.append(record: event("audit.export")))
    }
    func testRetentionPreservesChainAndMonotonicSequence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = Data(repeating: 8, count: 32), taskID = UUID()
        let store = try AgentAuditStore(root: root, keyData: key)
        for time in ["2020-01-01T00:00:00Z", "2026-10-18T00:00:00Z"] {
            try store.append(record: ["eventId": UUID().uuidString, "taskId": taskID.uuidString, "kind": "model.request", "timestamp": time, "body": "private-payload"])
        }
        let cutoff = Date(timeIntervalSince1970: 1_700_000_000)
        let preview = try store.retentionPreview(before: cutoff)
        XCTAssertEqual(preview.removableCount, 1)
        XCTAssertEqual(try store.prune(before: cutoff, expectedHead: preview.head), 1)
        XCTAssertEqual(try store.records(taskID: taskID).count, 1)
        let reopened = try AgentAuditStore(root: root, keyData: key)
        try reopened.append(record: ["eventId": UUID().uuidString, "taskId": taskID.uuidString, "kind": "test"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("00000000000000000003.event").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("00000000000000000001.event").path))
        XCTAssertEqual(try reopened.inventory().retiredRecords, 1)
    }
    func testExportSummaryExcludesPayloadAndRawUsage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AgentAuditStore(root: root, keyData: Data(repeating: 9, count: 32)), task = UUID()
        try store.append(record: ["eventId": UUID().uuidString, "taskId": task.uuidString, "kind": "model.request", "body": "private-canary", "toolCall": ["rawInput": "private-canary"], "usage": ["totalInput": 12, "rawUsage": ["secret": "private-canary"]]])
        try store.append(record: ["eventId": UUID().uuidString, "taskId": task.uuidString, "kind": "audit.export", "exportId": "export-fixture", "includesContents": true, "scope": "all", "sha256": "digest", "days": 7])
        let summary = try store.exportData(taskID: task, includeContents: false)
        let envelope = try XCTUnwrap(try JSONSerialization.jsonObject(with: summary) as? [String: Any])
        let exportedRecords = try XCTUnwrap(envelope["records"] as? [[String: Any]])
        XCTAssertEqual(exportedRecords.last?["exportId"] as? String, "export-fixture")
        XCTAssertEqual(exportedRecords.last?["includesContents"] as? Bool, true)
        XCTAssertEqual(exportedRecords.last?["days"] as? Int, 7)
        XCTAssertFalse(String(decoding: summary, as: UTF8.self).contains("private-canary"))
        XCTAssertTrue(String(decoding: try store.exportData(taskID: task, includeContents: true), as: UTF8.self).contains("private-canary"))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: summary) as? [String: Any])?["includesContents"] as? Bool, false)
    }
    func testStalePreviewAndTamperedCheckpointFailClosed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = Data(repeating: 4, count: 32), store = try AgentAuditStore(root: root, keyData: Data(repeating: 4, count: 32))
        let task = UUID()
        func event() -> [String: Any] { ["eventId": UUID().uuidString, "taskId": task.uuidString, "kind": "test", "timestamp": "2020-01-01T00:00:00Z"] }
        try store.append(record: event())
        let stale = try store.retentionPreview(before: Date())
        try store.append(record: event())
        XCTAssertThrowsError(try store.prune(before: Date(), expectedHead: stale.head))
        let valid = try store.retentionPreview(before: Date())
        XCTAssertEqual(try store.prune(before: Date(), expectedHead: valid.head), 2)
        let checkpoint = root.appendingPathComponent("retention.sealed")
        var bytes = try Data(contentsOf: checkpoint); bytes[bytes.count / 2] ^= 1; try bytes.write(to: checkpoint)
        XCTAssertThrowsError(try AgentAuditStore(root: root, keyData: key))
    }
}
