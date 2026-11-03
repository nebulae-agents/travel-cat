import Foundation
import XCTest
@testable import TravelCatApp

@MainActor
final class AgentXRunAuditTests: XCTestCase {
    func root() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("RunAudit-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func configured(_ root: URL, credentials: AgentXTestCredentials, respond: @escaping AgentXController.Responder) throws -> AgentXController {
        let controller = AgentXController(repository: .init(root: root), credentials: credentials, respond: respond)
        try controller.addProvider(name: "Test", address: "http://localhost:1234/v1", models: "m", secret: "secret-canary")
        try controller.addDefinition(name: "D", prompt: "system-canary")
        try controller.addInstance(name: "I", appID: "blackcat", definitionID: controller.state.definitions[0].id, providerID: controller.state.providers[0].id, model: "m")
        return controller
    }
    func testRequestAndCompletionUseOriginalAppAndEncryptedMetadataOnly() async throws {
        let root = try root(), credentials = AgentXTestCredentials()
        let controller = try configured(root, credentials: credentials, respond: { _, _, _, _ in "response-canary" })
        let instance = try XCTUnwrap(controller.state.instances.first)
        controller.send("prompt-canary", instanceID: instance.id)
        try controller.addApp(name: "Other")
        controller.selectedAppID = try XCTUnwrap(controller.state.apps.last?.id)
        await controller.waitForRuns()
        let run = try XCTUnwrap(controller.state.runs.first)
        let records = try AgentXRunAudit(root: root, credentials: credentials).records(appID: "blackcat", runID: run.id)
        XCTAssertEqual(records.compactMap { $0["kind"] as? String }, ["model.request.started", "model.request.completed"])
        XCTAssertTrue(records.allSatisfy { $0["appId"] as? String == "blackcat" && $0["providerId"] as? String == instance.providerID && $0["model"] as? String == "m" })
        let decoded = String(decoding: try JSONSerialization.data(withJSONObject: records), as: UTF8.self)
        for canary in ["prompt-canary", "system-canary", "response-canary", "secret-canary"] { XCTAssertFalse(decoded.contains(canary)) }
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("audit/blackcat"), includingPropertiesForKeys: nil)
        XCTAssertEqual(files.filter { $0.pathExtension == "event" }.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("audit/\(controller.selectedAppID)").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("apps/blackcat/audit").path))
    }
    func testCorruptAuditBlocksNewModelRequest() async throws {
        let root = try root(), credentials = AgentXTestCredentials()
        var calls = 0
        let controller = try configured(root, credentials: credentials, respond: { _, _, _, _ in calls += 1; return "not sent" })
        let audit = root.appendingPathComponent("audit/blackcat")
        try FileManager.default.createDirectory(at: audit, withIntermediateDirectories: true)
        try Data("broken-encrypted-chain".utf8).write(to: audit.appendingPathComponent("00000000000000000001.event"))
        controller.send("must not send", instanceID: controller.state.instances[0].id)
        await controller.waitForRuns()
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(controller.state.runs.isEmpty)
        XCTAssertTrue(controller.errorMessage?.contains("审计") == true)
    }
    func testTerminalAuditFailureKeepsResponseAndPersistsWarning() async throws {
        let root = try root(), credentials = AgentXTestCredentials()
        let controller = try configured(root, credentials: credentials, respond: { _, _, _, _ in
            try Data("corrupted after dispatch".utf8).write(to: root.appendingPathComponent("audit/blackcat/00000000000000000001.event"))
            return "retained response"
        })
        controller.send("hello", instanceID: controller.state.instances[0].id)
        await controller.waitForRuns()
        let run = try XCTUnwrap(AgentXRepository(root: root).load().runs.first)
        XCTAssertEqual(run.response, "retained response")
        XCTAssertEqual(run.status, .completed)
        XCTAssertNotNil(run.auditFailure)
        XCTAssertTrue(controller.errorMessage?.contains("审计") == true)
    }
    func testCancellationIsAuditedWithoutInventedUsageOrMoney() async throws {
        let root = try root(), credentials = AgentXTestCredentials()
        let controller = try configured(root, credentials: credentials, respond: { _, _, _, _ in try await Task.sleep(for: .seconds(30)); return "unused" })
        controller.send("hello", instanceID: controller.state.instances[0].id)
        controller.cancelAll()
        await controller.waitForRuns()
        let run = try XCTUnwrap(controller.state.runs.first)
        let records = try AgentXRunAudit(root: root, credentials: credentials).records(appID: "blackcat", runID: run.id)
        XCTAssertEqual(records.compactMap { $0["kind"] as? String }, ["model.request.started", "model.request.cancel_requested", "model.request.cancelled"])
        for record in records { XCTAssertNil(record["cost"]); XCTAssertNil(record["tokens"]); XCTAssertNil(record["usage"]) }
    }
    func testManagedWorkbenchUsesPlatformAuditAndPreservesLegacyFiles() throws {
        let root = try root(), credentials = AgentXTestCredentials()
        let content = root.appendingPathComponent("apps/workbench/state/runtime")
        let oldRoot = content.appendingPathComponent("audit-v1")
        let oldStore = try AgentAuditStore.open(root: oldRoot, credentials: credentials)
        let historicalTask = UUID()
        try oldStore.append(record: ["eventId": UUID().uuidString, "taskId": historicalTask.uuidString, "kind": "historical.request"])
        let old = oldRoot.appendingPathComponent("00000000000000000001.event")
        let original = try Data(contentsOf: old)
        let model = AgentWorkbenchModel(root: content, managedRoot: root, credentials: credentials)
        defer { model.shutdown() }
        XCTAssertTrue(model.isStorageReady)
        let task = UUID()
        try XCTUnwrap(model.auditStore).append(record: ["eventId": UUID().uuidString, "taskId": task.uuidString, "kind": "model.request"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("audit/workbench/00000000000000000001.event").path))
        XCTAssertEqual(try Data(contentsOf: old), original)
        XCTAssertEqual(model.auditRecords(taskID: historicalTask).first?["kind"] as? String, "historical.request")
    }
    func testHistoricalAuditReadOnlyOpenDoesNotMutateOrPermitAppend() throws {
        let root = try root(), key = Data(repeating: 7, count: 32), task = UUID()
        let original = try AgentAuditStore(root: root, keyData: key)
        try original.append(record: ["eventId": UUID().uuidString, "taskId": task.uuidString, "kind": "historical"])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        let reader = try AgentAuditStore(root: root, keyData: key, readOnly: true)
        XCTAssertEqual(try reader.records(taskID: task).count, 1)
        XCTAssertThrowsError(try reader.append(record: ["eventId": UUID().uuidString, "taskId": task.uuidString, "kind": "forbidden"]))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?.intValue, 0o755)
    }

}
