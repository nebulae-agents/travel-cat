import Foundation
import XCTest
@testable import TravelCatApp

final class AgentXAuditHelperTests: XCTestCase {
    @MainActor final class Credentials: TravelServiceCredentialStoring {
        var value: String?
        var saves = 0
        var reads = 0
        func read(id: String) throws -> String? { reads += 1; return value }
        func save(_ secret: String?, id: String) throws { value = secret; saves += 1 }
    }
    @MainActor func testVersionTwoMarkerOnlyAuthorizesExplicitMembers() throws {
        let root = URL(fileURLWithPath: "/private/tmp/agentx-audit-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent(".agentxd-pilot.json")
        func writeMarker(_ apps: [String]) throws {
            let body: [String: Any] = ["root": root.path, "version": 2, "apps": apps.map { ["appID": $0] }]
            try JSONSerialization.data(withJSONObject: body).write(to: marker, options: .atomic)
        }

        try writeMarker(["pilot", "second"])
        let helper = try AgentXAuditHelper(root: root.path, appID: "second", credentials: Credentials())
        XCTAssertThrowsError(try AgentXAuditHelper(root: root.path, appID: "third", credentials: Credentials()))
        let request = Data(#"{"op":"verify"}"#.utf8)
        XCTAssertEqual(try helper.execute(request)["ok"] as? Bool, true)
        try writeMarker(["pilot"])
        XCTAssertThrowsError(try helper.execute(request))
    }

    @MainActor func testAuditAuthorizesBothAppsWhenTheirBindingsExceedTheLegacyMarkerLimit() throws {
        let root = URL(fileURLWithPath: "/private/tmp/agentx-audit-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let binding = ["instanceID": "member", "providerID": "provider", "model": "model",
                       "baseURL": "https://openrouter.ai/api/v1", "systemPrompt": String(repeating: "x", count: 34_000)]
        let apps: [[String: Any]] = ["pilot", "second"].map { ["appID": $0, "pi": binding] }
        let data = try JSONSerialization.data(withJSONObject: ["root": root.path, "version": 2, "apps": apps])
        XCTAssertGreaterThan(data.count, 65_536)
        try data.write(to: root.appendingPathComponent(".agentxd-pilot.json"))
        let request = Data(#"{"op":"verify"}"#.utf8)
        for appID in ["pilot", "second"] {
            let helper = try AgentXAuditHelper(root: root.path, appID: appID, credentials: Credentials())
            XCTAssertEqual(try helper.execute(request)["ok"] as? Bool, true)
        }
    }

    @MainActor func testHelperEncryptedIdempotencyAndValidation() throws {
        let root = URL(fileURLWithPath: "/private/tmp/agentx-audit-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try JSONSerialization.data(withJSONObject: ["appID": "pilot", "root": root.path]).write(to: root.appendingPathComponent(".agentxd-pilot.json"))
        let credentials = Credentials()
        let helper = try AgentXAuditHelper(root: root.path, appID: "pilot", credentials: credentials)
        let run = UUID().uuidString
        var record: [String: Any] = ["eventId": UUID().uuidString, "taskId": run, "appId": "pilot", "instanceId": "worker", "providerId": "provider", "model": "model", "promptBytes": 12, "requestTextBytes": 18, "kind": "model.request.started", "timestamp": "2026-11-15T00:00:00Z"]
        func send(_ value: [String: Any]) throws -> [String: Any] { try helper.execute(JSONSerialization.data(withJSONObject: value)) }
        _ = try send(["op": "append", "record": record])
        _ = try send(["op": "append", "record": record])
        XCTAssertEqual((try send(["op": "records", "runId": run])["records"] as? [[String: Any]])?.count, 1)
        var invalid = record; invalid["promptBytes"] = true
        XCTAssertThrowsError(try send(["op": "append", "record": invalid]))
        invalid = record; invalid["responseBytes"] = 0
        XCTAssertThrowsError(try send(["op": "append", "record": invalid]))
        XCTAssertThrowsError(try send(["op": "verify", "unexpected": true]))
        XCTAssertThrowsError(try helper.execute(Data(repeating: 32, count: 16385)))
        record["model"] = "changed"
        XCTAssertThrowsError(try send(["op": "append", "record": record]))
        record["eventId"] = UUID().uuidString; record["prompt"] = "secret"
        XCTAssertThrowsError(try send(["op": "append", "record": record]))
        record.removeValue(forKey: "prompt"); record["appId"] = "other"
        XCTAssertThrowsError(try send(["op": "append", "record": record]))
        XCTAssertThrowsError(try AgentXAuditHelper(root: root.path, appID: "other", credentials: credentials))
        let file = root.appendingPathComponent("audit/pilot/00000000000000000001.event")
        let bytes = try Data(contentsOf: file)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("provider"))
        credentials.value = nil
        XCTAssertThrowsError(try AgentXAuditHelper(root: root.path, appID: "pilot", credentials: credentials))
        XCTAssertEqual(credentials.saves, 1)
        try Data("corrupt".utf8).write(to: file)
        XCTAssertThrowsError(try send(["op": "verify"]))
    }
    @MainActor func testSessionReusesCredentialsAndRejectsChangedPilot() throws {
        let root = URL(fileURLWithPath: "/private/tmp/agentx-audit-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent(".agentxd-pilot.json")
        try JSONSerialization.data(withJSONObject: ["appID": "pilot", "root": root.path]).write(to: marker)
        let credentials = Credentials(); credentials.value = Data(repeating: 7, count: 32).base64EncodedString()
        let helper = try AgentXAuditHelper(root: root.path, appID: "pilot", credentials: credentials)
        for _ in 0..<5 { _ = try helper.execute(Data("{\"op\":\"verify\"}".utf8)) }
        XCTAssertEqual(credentials.reads, 1)
        try JSONSerialization.data(withJSONObject: ["appID": "other", "root": root.path]).write(to: marker)
        XCTAssertThrowsError(try helper.execute(Data("{\"op\":\"verify\"}".utf8)))
    }

    @MainActor func testExistingKeyReadDoesNotNeedCreationLock() throws {
        let root = URL(fileURLWithPath: "/private/tmp/agentx-audit-existing-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = Credentials(); credentials.value = Data(repeating: 6, count: 32).base64EncodedString()
        let creationLock = try AgentAuditProcessLock()
        defer { withExtendedLifetime(creationLock) {} }
        _ = try AgentAuditStore.open(root: root, credentials: credentials)
        XCTAssertEqual(credentials.reads, 1)
        XCTAssertEqual(credentials.saves, 0)
    }
    private struct FixedAsyncCredentials: AsyncTravelServiceCredentialStoring {
        func read(id: String) async throws -> String? { Data(repeating: 6, count: 32).base64EncodedString() }
        func save(_ secret: String?, id: String) async throws { throw WorkbenchFailure("unexpected key replacement") }
    }
    @MainActor func testExistingAsyncKeyReadDoesNotNeedCreationLock() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/agentx-audit-existing-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let creationLock = try AgentAuditProcessLock()
        defer { withExtendedLifetime(creationLock) {} }
        _ = try await AgentAuditStore.open(root: root, credentials: FixedAsyncCredentials())
    }

    func testIndependentStoresSerializeAndDeduplicate() throws {
        let root = URL(fileURLWithPath: "/private/tmp/agentx-audit-store-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = Data(repeating: 1, count: 32)
        let first = try AgentAuditStore(root: root, keyData: key)
        let second = try AgentAuditStore(root: root, keyData: key)
        let record: [String: Any] = ["eventId": UUID().uuidString, "taskId": UUID().uuidString, "kind": "test"]
        var held: AgentAuditProcessLock? = try AgentAuditProcessLock(directory: root)
        XCTAssertThrowsError(try first.appendIdempotent(record: record))
        XCTAssertThrowsError(try second.inventory())
        withExtendedLifetime(held) {}
        held = nil
        try first.appendIdempotent(record: record)
        try second.appendIdempotent(record: record)
        XCTAssertEqual(try second.inventory().records, 1)
        XCTAssertThrowsError(try first.append(record: record))
    }
    func testIdempotentRetryMustConfirmDirectoryDurability() throws {
        let root = URL(fileURLWithPath: "/private/tmp/agentx-audit-sync-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var failSync = true
        var syncAttempts = 0
        let store = try AgentAuditStore(root: root, keyData: Data(repeating: 1, count: 32), synchronizeDirectory: { _ in
            syncAttempts += 1
            if failSync { throw WorkbenchFailure("injected sync failure") }
        })
        let record: [String: Any] = ["eventId": UUID().uuidString, "taskId": UUID().uuidString, "kind": "test"]
        XCTAssertThrowsError(try store.appendIdempotent(record: record))
        XCTAssertEqual(try store.inventory().records, 1)
        XCTAssertThrowsError(try store.appendIdempotent(record: record))
        failSync = false
        try store.appendIdempotent(record: record)
        XCTAssertEqual(syncAttempts, 3)
        XCTAssertEqual(try store.inventory().records, 1)
    }
    @MainActor func testRejectsSymlinkAndPublicRootWithoutCreatingKey() throws {
        let root = URL(fileURLWithPath: "/private/tmp/agentx-audit-path-" + UUID().uuidString)
        let link = URL(fileURLWithPath: root.path + "-link")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: link) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        let credentials = Credentials()
        XCTAssertThrowsError(try AgentXAuditHelper(root: root.path, appID: "pilot", credentials: credentials))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertThrowsError(try AgentXAuditHelper(root: link.path, appID: "pilot", credentials: credentials))
        XCTAssertEqual(credentials.saves, 0)
    }

}
