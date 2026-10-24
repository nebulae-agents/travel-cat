import AppKit
import XCTest
@testable import TravelCatApp

@MainActor
private final class NavigationCredentials: TravelServiceCredentialStoring {
    private var storageKeys: [String: String] = [:]
    func read(id: String) throws -> String? { ["workbench-content-v1", "audit-journal-v1"].contains(id) ? storageKeys[id] : "test-only" }
    func save(_ secret: String?, id: String) throws { storageKeys[id] = secret }
}

@MainActor
private final class NavigationRuntime: AgentRuntimeClient {
    var onEvent: (([String: Any]) -> Void)?
    var onExit: (() -> Void)?
    var calls: [String] = []
    func launch(python: String) throws {}
    func request(_ method: String, _ params: [String: Any], timeout: UInt64) async throws -> [String: Any] {
        calls.append(method)
        return method == "start" ? ["sessionId": "local-test-session"] : [:]
    }
    func shutdown() { onExit?() }
    func state(_ task: UUID, _ status: WorkbenchTaskStatus) {
        onEvent?(["event": "state", "taskId": task.uuidString, "data": ["status": status.rawValue]])
    }
    func permission(_ task: UUID) {
        onEvent?(["event": "permission", "taskId": task.uuidString,
                  "data": ["requestId": task.uuidString, "options": []]])
    }
}

final class AgentWorkbenchNavigationTests: XCTestCase {
    @MainActor
    private func fixture() throws -> (AgentWorkbenchModel, NavigationRuntime, URL, WorkbenchInstance, WorkbenchInstance) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let runtime = NavigationRuntime()
        let model = AgentWorkbenchModel(root: root, credentials: NavigationCredentials(), client: runtime)
        var a = WorkbenchInstance(name: "A", image: "agent@sha256:" + String(repeating: "a", count: 64), command: ["test-acp"])
        a.provider.baseURL = "https://example.com/v1"; a.provider.model = "test-model"
        var b = WorkbenchInstance(name: "B", image: a.image, command: a.command)
        b.provider.baseURL = a.provider.baseURL; b.provider.model = a.provider.model
        try model.save(instance: a, newKey: "")
        try model.save(instance: b, newKey: "")
        return (model, runtime, root, a, b)
    }
    @MainActor
    func testInstanceNavigationPrioritizesPermissionUnreadActiveThenRecentAndRelocatesRepeatedClick() async throws {
        let (model, runtime, root, a, b) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        var tasks: [UUID] = []
        for title in ["permission", "unread", "active", "recent"] {
            await model.start(instanceID: a.id, text: title)
            tasks.append(try XCTUnwrap(model.selectedTaskID))
            model.markRead(model.selectedTaskID) // Simulate a rendered detail before moving to another task.
        }
        await model.start(instanceID: b.id, text: "other instance")
        let other = try XCTUnwrap(model.selectedTaskID)
        runtime.permission(tasks[0]); runtime.state(tasks[1], .completed); runtime.state(tasks[2], .running)
        model.openInstance(a.id)
        XCTAssertEqual(model.preferredInstanceID, a.id)
        XCTAssertEqual(model.selectedTaskID, tasks[0])
        model.selectedTaskID = other
        model.openInstance(a.id)
        XCTAssertEqual(model.selectedTaskID, tasks[0], "Repeated clicks must relocate even when the instance ID is unchanged")
        runtime.state(tasks[0], .completed); model.markRead(tasks[0])
        model.openInstance(a.id)
        XCTAssertEqual(model.selectedTaskID, tasks[1])
        model.markRead(tasks[1])
        model.openInstance(a.id)
        XCTAssertEqual(model.selectedTaskID, tasks[2])
        runtime.state(tasks[2], .completed); model.markRead(tasks[2])
        model.openInstance(a.id)
        XCTAssertEqual(model.selectedTaskID, tasks[3])
    }
    @MainActor
    func testGeneralLauncherPreservesInstanceAndTaskSelection() async throws {
        let (model, _, root, a, _) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        await model.start(instanceID: a.id, text: "selected")
        let selected = model.selectedTaskID
        model.preferredInstanceID = a.id
        let launcher = AgentLauncherController(model: model) {}
        defer { launcher.hide() }
        launcher.refresh()
        XCTAssertEqual(model.preferredInstanceID, a.id)
        XCTAssertEqual(model.selectedTaskID, selected)
    }
    @MainActor
    func testEmptyInstanceClearsOtherTaskAndRemovalSelectsRemainingInstance() async throws {
        let (model, _, root, a, b) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        await model.start(instanceID: a.id, text: "other task")
        let launcher = AgentLauncherController(model: model) {}
        defer { launcher.hide() }
        model.openInstance(b.id)
        XCTAssertEqual(model.preferredInstanceID, b.id)
        XCTAssertNil(model.selectedTaskID)
        model.remove(instanceID: b.id)
        XCTAssertEqual(model.preferredInstanceID, a.id)
        XCTAssertEqual(model.selectedTaskID, model.state.tasks.first?.id)
    }
    @MainActor
    func testRuntimeExitProducesUnreadMailboxFailure() async throws {
        let (model, runtime, root, a, _) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        await model.start(instanceID: a.id, text: "running")
        let id = try XCTUnwrap(model.selectedTaskID)
        runtime.state(id, .running)
        model.markRead(id)
        runtime.permission(id)
        runtime.onExit?()
        XCTAssertTrue(model.permissions.isEmpty)
        let inbox = MailboxInbox.project(tasks: model.state.tasks, pendingTaskIDs: [], postcards: [])
        XCTAssertEqual(inbox.singleEntry?.destination, .task(id))
        XCTAssertEqual(inbox.singleEntry?.kind, .failure)
    }

    @MainActor
    func testSelectedTaskCompletionWithoutVisibleDetailRemainsUnread() async throws {
        let (model, runtime, root, a, _) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        await model.start(instanceID: a.id, text: "background completion")
        let id = try XCTUnwrap(model.selectedTaskID)
        model.markRead(id)
        runtime.state(id, .completed)
        XCTAssertEqual(model.selectedTaskID, id)
        XCTAssertTrue(try XCTUnwrap(model.state.tasks.first { $0.id == id }).unread)
    }

    @MainActor
    func testMailboxRefreshDoesNotConsumeUnreadAndOpensExactTask() async throws {
        let (model, runtime, root, a, b) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        await model.start(instanceID: a.id, text: "mailbox result")
        let target = try XCTUnwrap(model.selectedTaskID)
        await model.start(instanceID: b.id, text: "other task")
        let other = model.selectedTaskID
        runtime.state(target, .completed)
        var opened = 0
        let launcher = AgentLauncherController(model: model) { opened += 1 }
        launcher.refresh()
        XCTAssertEqual(model.selectedTaskID, other)
        XCTAssertTrue(try XCTUnwrap(model.state.tasks.first { $0.id == target }).unread)
        launcher.openEntry("task-\(UUID())")
        XCTAssertEqual(opened, 0)
        launcher.openEntry("task-\(target)")
        XCTAssertEqual(model.selectedTaskID, target)
        XCTAssertEqual(model.preferredInstanceID, a.id)
        XCTAssertEqual(opened, 1)
        XCTAssertTrue(try XCTUnwrap(model.state.tasks.first { $0.id == target }).unread, "Navigation alone is not a visible receipt")
        model.markRead(target) // Actual visible detail acknowledges this task.
        launcher.openEntry("task-\(target)")
        XCTAssertEqual(opened, 1, "A consumed card must not act again")
    }

    @MainActor
    func testOnlyCompletedOrCancelledLiveSessionsAcceptReplies() async throws {
        let (model, runtime, root, a, _) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        await model.start(instanceID: a.id, text: "task")
        let id = try XCTUnwrap(model.selectedTaskID)
        for status in [WorkbenchTaskStatus.connecting, .running, .awaitingPermission, .cancelling, .unknown, .failed, .completed, .cancelled] {
            runtime.state(id, status)
            let allowed = status == .completed || status == .cancelled
            XCTAssertEqual(model.canReply(id), allowed, "Reply policy for \(status)")
            if !allowed {
                let count = runtime.calls.count
                await model.followUp(taskID: id, text: "must not send")
                XCTAssertEqual(runtime.calls.count, count, "Unsafe status must not reach runtime")
            }
        }
        runtime.onExit?()
        XCTAssertFalse(model.canReply(id))
    }
}

extension AgentWorkbenchNavigationTests {
    @MainActor func testHandoffUsesLatestBodyAnswerAndPreservesDraftAndNavigationWithoutSending() async throws {
        let (model, runtime, root, a, b) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        await model.start(instanceID: a.id, text: "first question")
        let id = try XCTUnwrap(model.selectedTaskID)
        let answer = WorkbenchMessage(role: "assistant", text: "普通答案 A\r\n\t🙂  ", sourceKind: "acp.agent_message_chunk")
        model.mutate(id) { task in
            task.messages += [answer, .init(role: "user", text: "next question"), .init(role: "assistant", text: "private thought B", sourceKind: "acp.agent_thought_chunk")]
        }
        model.updateDraft(.new(b.id)) { $0.text = "已有草稿"; $0.files = [["name": "keep.txt"]] }
        let source = try XCTUnwrap(model.state.tasks.first { $0.id == id })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let original = try encoder.encode(source)
        let calls = runtime.calls
        XCTAssertEqual(WorkbenchConversationPresentation.latestAssistantBody(source)?.id, answer.id)
        XCTAssertTrue(model.prepareHandoff(from: id, to: b.id))
        let draft = model.draft(for: .new(b.id))
        XCTAssertEqual(draft.text, "已有草稿\n\n承接对话：\(source.title)\n\n上轮回复：\n" + answer.text)
        XCTAssertEqual(draft.files, [["name": "keep.txt"]])
        XCTAssertEqual(draft.parentTaskID, id)
        XCTAssertEqual(model.preferredInstanceID, b.id); XCTAssertNil(model.selectedTaskID)
        XCTAssertEqual(runtime.calls, calls, "handoff prepares a draft without sending or invoking a runtime")
        XCTAssertEqual(try encoder.encode(try XCTUnwrap(model.state.tasks.first { $0.id == id })), original)
        XCTAssertTrue(WorkbenchConversationPresentation.matches(source, query: "private thought B"), "search retains accepted thoughts")
    }

    @MainActor func testOnlyThoughtHandoffCannotChangeDraftSelectionOrInvokeRuntime() async throws {
        let (model, runtime, root, a, b) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        await model.start(instanceID: a.id, text: "first question")
        let id = try XCTUnwrap(model.selectedTaskID)
        model.mutate(id) { $0.messages.append(.init(role: "assistant", text: "only thought", sourceKind: "acp.agent_thought_chunk")) }
        model.updateDraft(.new(b.id)) { $0.text = "不要覆盖"; $0.parentTaskID = UUID() }
        let task = try XCTUnwrap(model.state.tasks.first { $0.id == id })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(model.state)
        let calls = runtime.calls
        XCTAssertNil(WorkbenchConversationPresentation.latestAssistantBody(task), "the menu has no body answer to offer")
        XCTAssertFalse(model.prepareHandoff(from: id, to: b.id), "stale UI cannot create a thought-only handoff")
        XCTAssertEqual(try encoder.encode(model.state), before)
        XCTAssertEqual(model.preferredInstanceID, a.id); XCTAssertEqual(model.selectedTaskID, id)
        XCTAssertEqual(runtime.calls, calls)
    }

    @MainActor func testHandoffKeepsLegacyUnknownAndNativeBodyAnswersEligible() async throws {
        let (model, runtime, root, a, b) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        await model.start(instanceID: a.id, text: "question")
        let id = try XCTUnwrap(model.selectedTaskID)
        let calls = runtime.calls
        let candidates = [
            WorkbenchMessage(role: "assistant", text: "legacy <think>body</think>"),
            WorkbenchMessage(role: "assistant", text: "unknown reasoning body", sourceKind: "future.runtime.thought"),
            WorkbenchMessage(role: "assistant", text: "Native body", runtimeItemID: "native-agent-message"),
            WorkbenchMessage(role: "assistant", text: "ACP body", sourceKind: "acp.agent_message_chunk")]
        for body in candidates {
            model.mutate(id) { $0.messages = [body, .init(role: "assistant", text: "later typed thought", sourceKind: "acp.agent_thought_chunk")] }
            model.updateDraft(.new(b.id)) { $0.text = ""; $0.parentTaskID = nil }
            let task = try XCTUnwrap(model.state.tasks.first { $0.id == id })
            XCTAssertEqual(WorkbenchConversationPresentation.latestAssistantBody(task)?.id, body.id)
            XCTAssertTrue(model.prepareHandoff(from: id, to: b.id))
            XCTAssertEqual(model.draft(for: .new(b.id)).text, "承接对话：\(task.title)\n\n上轮回复：\n" + body.text)
            XCTAssertEqual(model.draft(for: .new(b.id)).parentTaskID, id)
        }
        XCTAssertEqual(runtime.calls, calls)
    }
}
