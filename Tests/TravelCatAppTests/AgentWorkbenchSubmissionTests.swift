import Foundation
import XCTest
@testable import TravelCatApp

@MainActor
private final class SubmissionCredentials: TravelServiceCredentialStoring {
    var key: String? = "test-only"
    private var storageKeys: [String: String] = [:]
    func read(id: String) throws -> String? { ["workbench-content-v1", "audit-journal-v1"].contains(id) ? storageKeys[id] : key }
    func save(_ secret: String?, id: String) throws { storageKeys[id] = secret }
}

@MainActor
private final class SubmissionRuntime: AgentRuntimeClient {
    var onEvent: (([String: Any]) -> Void)?
    var onExit: (() -> Void)?
    var calls: [String] = []
    var launches = 0
    var promptTexts: [String] = []
    var startResult: [String: Any] = ["sessionId": "session"]
    var startFailure: Error?
    var launchFailure: Error?
    var promptFailure: Error?
    var beforeStart: (() async -> Void)?
    var duringPrompt: (() -> Void)?
    func launch(python: String) throws { launches += 1; if let launchFailure { throw launchFailure } }
    func request(_ method: String, _ params: [String: Any], timeout: UInt64) async throws -> [String: Any] {
        calls.append(method)
        if method == "start" {
            await beforeStart?()
            if let startFailure { throw startFailure }
            return startResult
        }
        if method == "prompt" { promptTexts.append(params["text"] as? String ?? ""); duringPrompt?(); if let promptFailure { throw promptFailure } }
        return [:]
    }
    func shutdown() { onExit?() }
}

final class AgentWorkbenchSubmissionTests: XCTestCase {
    @MainActor
    private func fixture() throws -> (AgentWorkbenchModel, SubmissionRuntime, SubmissionCredentials, URL, UUID) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let runtime = SubmissionRuntime(), credentials = SubmissionCredentials()
        let model = AgentWorkbenchModel(root: root, credentials: credentials, client: runtime)
        var instance = WorkbenchInstance(name: "Test", image: "agent@sha256:" + String(repeating: "a", count: 64), command: ["test-acp"])
        instance.provider.model = "test"
        try model.save(instance: instance, newKey: "")
        return (model, runtime, credentials, root, instance.id)
    }
    @MainActor
    func testOversizedInputIsRejectedWithoutTruncationOrRuntimeCall() async throws {
        let (model, runtime, _, root, id) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        await model.start(instanceID: id, text: String(repeating: "字", count: 100_001))
        XCTAssertTrue(runtime.calls.isEmpty)
        XCTAssertTrue(model.state.tasks.isEmpty)
        XCTAssertNotNil(model.error)
    }
    @MainActor
    func testMissingSessionDoesNotSendPromptAndRetainsUnknownTaskForCleanup() async throws {
        let (model, runtime, _, root, id) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        runtime.startResult = [:]
        await model.start(instanceID: id, text: "keep draft")
        XCTAssertEqual(runtime.calls, ["start"])
        XCTAssertEqual(model.state.tasks.first?.status, .unknown)
        XCTAssertTrue(model.isLive(try XCTUnwrap(model.state.tasks.first?.id)))
    }
}

extension AgentWorkbenchSubmissionTests {
    @MainActor
    func testPreflightAndLaunchFailuresPreserveDraft() async throws {
        let (model, runtime, credentials, root, id) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        var draft = WorkbenchSubmissionDraft()
        draft.text = "original"; draft.files = [["name": "input"]]; draft.parentTaskID = UUID()
        let snapshot = draft
        credentials.key = nil
        await model.start(instanceID: id, text: draft.text) { draft.clear(ifUnchangedSince: snapshot.revision) }
        XCTAssertEqual(draft, snapshot)
        credentials.key = "test"
        runtime.launchFailure = WorkbenchFailure("launch failed")
        await model.start(instanceID: id, text: draft.text) { draft.clear(ifUnchangedSince: snapshot.revision) }
        XCTAssertEqual(draft, snapshot)
        XCTAssertFalse(model.isStarting)
        XCTAssertTrue(runtime.calls.isEmpty)
    }
    @MainActor
    func testFailedOrUnknownStartNeverAcknowledgesDraft() async throws {
        let (model, runtime, _, root, id) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        var acknowledgements = 0
        for failure in [WorkbenchFailure("failed", taskRetained: false), WorkbenchFailure("unknown")] {
            runtime.startFailure = failure
            await model.start(instanceID: id, text: "retain") { acknowledgements += 1 }
            XCTAssertFalse(model.isStarting)
        }
        runtime.startFailure = nil; runtime.startResult = ["sessionId": "  "]
        await model.start(instanceID: id, text: "retain") { acknowledgements += 1 }
        XCTAssertEqual(acknowledgements, 0)
        XCTAssertEqual(runtime.calls, ["start", "start", "start"])
    }
    @MainActor
    func testAcknowledgementWaitsForPromptConfirmationAndUnlocksNewTasks() async throws {
        let (model, runtime, _, root, id) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        var draft = WorkbenchSubmissionDraft()
        draft.text = "original"; draft.files = [["name": "input"]]; draft.parentTaskID = UUID()
        let snapshot = draft
        runtime.beforeStart = {
            XCTAssertTrue(model.isStarting)
            await model.start(instanceID: id, text: "duplicate")
            XCTAssertEqual(draft, snapshot)
        }
        runtime.duringPrompt = {
            XCTAssertFalse(model.isStarting, "Do not lock the composer for the hour-long prompt")
            XCTAssertEqual(draft, snapshot, "Creating a session does not confirm the prompt was submitted")
        }
        var acknowledged = 0
        await model.start(instanceID: id, text: snapshot.text, files: snapshot.files, parentTaskID: snapshot.parentTaskID) {
            acknowledged += 1; draft.clear(ifUnchangedSince: snapshot.revision)
        }
        XCTAssertEqual(acknowledged, 1)
        XCTAssertTrue(draft.text.isEmpty)
        XCTAssertEqual(runtime.calls, ["start", "prompt"])
    }
    func testNewEditsIncludingRevertedTextSurviveOldAcknowledgement() {
        var draft = WorkbenchSubmissionDraft()
        draft.text = "old"
        let revision = draft.revision
        draft.text = "new"; draft.text = "old"
        draft.files = [["name": "new-input"]]; draft.parentTaskID = UUID()
        let edited = draft
        draft.clear(ifUnchangedSince: revision)
        XCTAssertEqual(draft, edited)
    }
    @MainActor
    func testDisconnectDuringStartNeverAcknowledgesOrReplays() async throws {
        let (model, runtime, _, root, id) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        runtime.beforeStart = { runtime.onExit?() }
        var acknowledged = false
        await model.start(instanceID: id, text: "retain") { acknowledged = true }
        XCTAssertFalse(acknowledged)
        XCTAssertEqual(runtime.calls, ["start"])
        XCTAssertEqual(model.state.tasks.first?.status, .unknown)
    }
    @MainActor
    func testOversizedFollowUpDoesNotSendOrAppendTruncatedText() async throws {
        let (model, runtime, _, root, id) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        await model.start(instanceID: id, text: "initial")
        let task = try XCTUnwrap(model.state.tasks.first)
        let accepted = await model.followUp(taskID: task.id, text: String(repeating: "x", count: 100_001))
        XCTAssertFalse(accepted)
        XCTAssertEqual(runtime.calls, ["start", "prompt"])
        XCTAssertEqual(model.state.tasks.first?.messages.count, task.messages.count)
    }
}


extension AgentWorkbenchSubmissionTests {
    @MainActor
    func testUnicodeByteOverflowPreservesDraftBeforeLaunching() async throws {
        let (model, runtime, _, root, id) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        var draft = WorkbenchSubmissionDraft()
        draft.text = String(repeating: "👨‍👩‍👧‍👦", count: 22_000)
        draft.files = [["name": "input"]]; draft.parentTaskID = UUID()
        let submitted = draft
        XCTAssertLessThan(draft.text.count, 100_000)
        XCTAssertGreaterThan(draft.text.utf8.count, 512 * 1024)
        await model.start(instanceID: id, text: draft.text) { draft.clear(ifUnchangedSince: submitted.revision) }
        XCTAssertTrue(draft == submitted, "Oversized draft must remain intact")
        XCTAssertEqual(runtime.launches, 0)
        XCTAssertTrue(runtime.calls.isEmpty)
        XCTAssertTrue(model.state.tasks.isEmpty)
        XCTAssertNotNil(model.error)
    }
    @MainActor
    func testRoleAndInstructionOverheadCountTowardByteLimit() async throws {
        let (model, runtime, _, root, id) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let text = String(repeating: "x", count: 100_000)
        var instance = try XCTUnwrap(model.state.instances.first)
        let overhead = "角色说明：\n\n任务：".utf8.count
        instance.role = String(repeating: "r", count: 512 * 1024 - text.utf8.count - overhead + 1)
        try model.save(instance: instance, newKey: "")
        var acknowledged = false
        await model.start(instanceID: id, text: text) { acknowledged = true }
        XCTAssertFalse(acknowledged)
        XCTAssertEqual(runtime.launches, 0)
        XCTAssertTrue(runtime.calls.isEmpty)
        XCTAssertTrue(model.state.tasks.isEmpty)
        XCTAssertNotNil(model.error)
    }
    @MainActor
    func testExactlyByteLimitWithFullBodyAndRoleIsSentWithoutTruncation() async throws {
        let (model, runtime, _, root, id) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let text = String(repeating: "x", count: 100_000)
        var instance = try XCTUnwrap(model.state.instances.first)
        let overhead = "角色说明：\n\n任务：".utf8.count
        instance.role = String(repeating: "r", count: 512 * 1024 - text.utf8.count - overhead)
        try model.save(instance: instance, newKey: "")
        let expected = "角色说明：\(instance.role)\n\n任务：\(text)"
        XCTAssertEqual(expected.utf8.count, 512 * 1024)
        var acknowledged = false
        await model.start(instanceID: id, text: text) { acknowledged = true }
        XCTAssertTrue(acknowledged)
        XCTAssertEqual(runtime.promptTexts, [expected])
    }
    @MainActor
    func testUnicodeByteOverflowFollowUpKeepsTaskAndDoesNotSend() async throws {
        let (model, runtime, _, root, id) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        await model.start(instanceID: id, text: "initial")
        let task = try XCTUnwrap(model.state.tasks.first)
        let accepted = await model.followUp(taskID: task.id, text: String(repeating: "👨‍👩‍👧‍👦", count: 22_000))
        XCTAssertFalse(accepted)
        XCTAssertEqual(runtime.calls, ["start", "prompt"])
        XCTAssertEqual(model.state.tasks.first?.messages.count, task.messages.count)
        XCTAssertEqual(model.state.tasks.first?.status, task.status)
        XCTAssertNotNil(model.error)
    }
}

extension AgentWorkbenchSubmissionTests {
    @MainActor
    func testPromptTransportFailureNeverAcknowledgesDraft() async throws {
        let (model, runtime, _, root, id) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        runtime.promptFailure = WorkbenchFailure("transport result unknown")
        var acknowledged = false
        await model.start(instanceID: id, text: "preserve") { acknowledged = true }
        XCTAssertFalse(acknowledged)
        XCTAssertEqual(model.state.tasks.first?.status, .unknown)
    }
}

extension AgentWorkbenchSubmissionTests {
    @MainActor func testACPTaskAndSessionAreDurableBeforePromptReachesRuntime() async throws {
        let (model, runtime, _, root, id) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        runtime.duringPrompt = {
            do {
                let saved = try XCTUnwrap(model.store.load().tasks.first)
                XCTAssertEqual(saved.sessionID, "session", "Recovery needs the accepted session before content is sent")
                XCTAssertEqual(saved.messages.first?.text, "durable submission")
            } catch { XCTFail("Task checkpoint missing before prompt: \(error)") }
        }
        await model.start(instanceID: id, text: "durable submission")
        XCTAssertEqual(runtime.calls, ["start", "prompt"])
    }
}
