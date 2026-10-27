import Foundation
import XCTest
@testable import TravelCatApp

@MainActor private final class AuditCredentials: TravelServiceCredentialStoring {
    private var storageKeys: [String: String] = [:]
    func read(id: String) throws -> String? { ["workbench-content-v1", "audit-journal-v1"].contains(id) ? storageKeys[id] : "fixture-key" }
    func save(_ secret: String?, id: String) throws { storageKeys[id] = secret }
}
private final class AuditFixtureStore: AgentAuditStoring {
    var saved: [[String: Any]] = []
    var reject = false
    func append(record: [String: Any]) throws { if reject { throw WorkbenchFailure("unwritable") }; saved.append(record) }
    func records(taskID: UUID) throws -> [[String: Any]] { saved }
}
@MainActor private final class AuditFixtureRuntime: AgentRuntimeClient {
    var onEvent: (([String: Any]) -> Void)?
    var onExit: (() -> Void)?
    var requests: [(String, [String: Any])] = []
    var afterRequest: ((String, [String: Any]) -> Void)?
    func launch(python: String) throws {}
    func request(_ method: String, _ params: [String: Any], timeout: UInt64) async throws -> [String: Any] {
        requests.append((method, params)); afterRequest?(method, params)
        return method == "start" ? ["sessionId": "fixture"] : [:]
    }
    func shutdown() { onExit?() }
}
final class AgentAuditModelTests: XCTestCase {
    @MainActor func testAcknowledgementFollowsStorageAndContentStaysOutOfSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = AuditFixtureRuntime(), audit = AuditFixtureStore()
        let model = AgentWorkbenchModel(root: root, credentials: AuditCredentials(), client: runtime, auditStore: audit)
        var agent = WorkbenchInstance(name: "test", image: "a@sha256:" + String(repeating: "a", count: 64), command: ["a"])
        agent.provider.model = "test"
        try model.save(instance: agent, newKey: "")
        await model.start(instanceID: agent.id, text: "test")
        let task = try XCTUnwrap(model.state.tasks.first)
        let ack = expectation(description: "durable ack")
        runtime.afterRequest = { method, params in
            if method == "audit_ack" { XCTAssertEqual(audit.saved.count, 1); XCTAssertEqual(params["accepted"] as? Bool, true); ack.fulfill() }
        }
        runtime.onEvent?(["event": "audit", "taskId": task.id.uuidString, "data": ["receiptId": UUID().uuidString, "record": ["eventId": UUID().uuidString, "taskId": task.id.uuidString, "callId": "call", "kind": "model.request", "body": "audit-private-payload", "requestHash": "hash"]]])
        await fulfillment(of: [ack], timeout: 2)
        model.shutdown()
        XCTAssertFalse(try String(decoding: Data(contentsOf: root.appendingPathComponent("workbench.sealed")), as: UTF8.self).contains("audit-private-payload"))
    }
    @MainActor func testApprovalRequiresDurableMatchingRequestAndBindsDecision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = AuditFixtureRuntime(), audit = AuditFixtureStore()
        let model = AgentWorkbenchModel(root: root, credentials: AuditCredentials(), client: runtime, auditStore: audit)
        var agent = WorkbenchInstance(name: "test", image: "a@sha256:" + String(repeating: "a", count: 64), command: ["a"])
        agent.provider.model = "test"
        try model.save(instance: agent, newKey: "")
        await model.start(instanceID: agent.id, text: "test")
        let taskID = try XCTUnwrap(model.state.tasks.first?.id), callID = UUID()
        let approval: [String: Any] = ["event": "modelApproval", "taskId": taskID.uuidString, "data": ["callId": callID.uuidString, "requestHash": "frozen"]]
        runtime.onEvent?(approval)
        XCTAssertTrue(model.modelApprovals.isEmpty)
        audit.saved = [["eventId": UUID().uuidString, "taskId": taskID.uuidString, "kind": "model.request", "callId": callID.uuidString, "requestHash": "other", "destination": "https://example.test", "model": "test"]]
        runtime.onEvent?(approval)
        XCTAssertTrue(model.modelApprovals.isEmpty)
        audit.saved[0]["requestHash"] = "frozen"
        runtime.onEvent?(approval)
        let request = try XCTUnwrap(model.modelApprovals.first)
        XCTAssertEqual(request.destination, "https://example.test")
        await model.respondModel(request, allow: true)
        let sent = try XCTUnwrap(runtime.requests.last)
        XCTAssertEqual(sent.0, "model_permission")
        XCTAssertEqual(sent.1["requestHash"] as? String, "frozen")
        XCTAssertEqual(sent.1["callId"] as? String, callID.uuidString)
        XCTAssertTrue(model.modelApprovals.isEmpty)
        let count = runtime.requests.count
        await model.respondModel(request, allow: true)
        XCTAssertEqual(runtime.requests.count, count)
        XCTAssertEqual(runtime.requests.first(where: { $0.0 == "start" })?.1["modelPolicy"] as? String, "review")
        model.shutdown()
    }
    @MainActor func testUnwritableAuditSendsNegativeAcknowledgement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = AuditFixtureRuntime(), audit = AuditFixtureStore(); audit.reject = true
        let model = AgentWorkbenchModel(root: root, credentials: AuditCredentials(), client: runtime, auditStore: audit)
        var agent = WorkbenchInstance(name: "test", image: "a@sha256:" + String(repeating: "a", count: 64), command: ["a"])
        agent.provider.model = "test"
        try model.save(instance: agent, newKey: "")
        await model.start(instanceID: agent.id, text: "test")
        let taskID = try XCTUnwrap(model.state.tasks.first?.id)
        let ack = expectation(description: "negative ack")
        runtime.afterRequest = { method, params in
            if method == "audit_ack" { XCTAssertEqual(params["accepted"] as? Bool, false); ack.fulfill() }
        }
        runtime.onEvent?(["event": "audit", "taskId": taskID.uuidString, "data": ["receiptId": UUID().uuidString, "record": ["eventId": UUID().uuidString, "taskId": taskID.uuidString, "kind": "model.request"]]])
        await fulfillment(of: [ack], timeout: 2)
        XCTAssertNotNil(model.auditError)
        model.shutdown()
    }
}
