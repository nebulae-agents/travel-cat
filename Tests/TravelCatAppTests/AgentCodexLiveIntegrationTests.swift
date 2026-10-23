import Foundation
import XCTest
@testable import TravelCatApp

@MainActor
private final class LiveIntegrationCredentials: TravelServiceCredentialStoring {
    private var values: [String: String] = [:]
    func read(id: String) throws -> String? { values[id] }
    func save(_ secret: String?, id: String) throws { values[id] = secret }
}

/// Opt-in local integration check. It deliberately denies the first model call, so no model API request is made.
final class AgentCodexLiveIntegrationTests: XCTestCase {
    @MainActor
    func testRealSidecarCodexApprovalAuditAndCleanup() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["TRAVEL_CAT_CODEX_LIVE_TEST"] == "1" else {
            throw XCTSkip("Requires isolated local Docker/ACP image; opt in with TRAVEL_CAT_CODEX_LIVE_TEST=1.")
        }
        let image = try XCTUnwrap(env["TRAVEL_CAT_CODEX_LIVE_IMAGE"])
        let context = try XCTUnwrap(env["TRAVEL_CAT_CODEX_LIVE_CONTEXT"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("travelcat-codex-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = LiveIntegrationCredentials()
        let model = AgentWorkbenchModel(root: root, credentials: credentials, client: AgentSidecarClient())
        defer { model.shutdown() }
        var instance = WorkbenchInstance(name: "Codex integration fixture", image: image,
                                         command: ["/opt/travelcat-acp/node_modules/.bin/codex-acp"])
        instance.dockerContext = context
        instance.provider.baseURL = "https://127.0.0.1/v1"
        instance.provider.model = "integration-test-model"
        try model.save(instance: instance, newKey: "test-only-invalid-key")
        XCTAssertNil(model.auditError)

        print("live-integration start \(Date())")
        let prompt = Task { await model.start(instanceID: instance.id, text: "Reply with HELLO only.") }
        var approval: WorkbenchModelApproval?
        for _ in 0..<240 {
            if let first = model.modelApprovals.first { approval = first; break }
            if model.state.tasks.first?.status == .failed { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        guard let approval else {
            if let taskID = model.state.tasks.first?.id { await model.stop(taskID) }
            prompt.cancel()
            XCTFail("The real ACP adapter did not reach an audited model approval: \(model.error ?? model.auditError ?? "unknown")")
            return
        }
        print("live-integration approval \(Date())")
        let taskID = approval.taskID
        let before = model.auditRecords(taskID: taskID)
        XCTAssertTrue(before.contains { $0["kind"] as? String == "model.request" })
        XCTAssertEqual(approval.destination, "https://127.0.0.1/v1/responses")
        await model.respondModel(approval, allow: false)
        print("live-integration denied \(Date())")
        await prompt.value
        print("live-integration prompt-returned \(Date())")
        let records = model.auditRecords(taskID: taskID)
        let kinds = records.compactMap { $0["kind"] as? String }
        XCTAssertTrue(kinds.contains("model.decision"), "Recorded: \(kinds)")
        XCTAssertTrue(kinds.contains("model.failed"), "Recorded: \(kinds)")
        XCTAssertFalse(kinds.contains("model.completed"))
        XCTAssertNil(model.auditError)
        await model.stop(taskID)
        print("live-integration stopped \(Date())")
        XCTAssertFalse(model.isLive(taskID), "Container cleanup must be confirmed before test data is removed")
        XCTAssertTrue(model.auditRecords(taskID: taskID).contains { $0["kind"] as? String == "operation.stop" })
        let sealed = try Data(contentsOf: root.appendingPathComponent("workbench.sealed"))
        XCTAssertFalse(String(decoding: sealed, as: UTF8.self).contains("Reply with HELLO"))
    }
}
