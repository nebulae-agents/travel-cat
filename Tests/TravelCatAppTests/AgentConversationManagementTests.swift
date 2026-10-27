import AppKit
import XCTest
@testable import TravelCatApp

@MainActor private final class ConversationCredentials: TravelServiceCredentialStoring {
    var values: [String: String] = [:]
    func read(id: String) throws -> String? { values[id] }
    func save(_ secret: String?, id: String) throws { values[id] = secret }
}
private final class ConversationAudit: AgentAuditStoring {
    var saved: [[String: Any]] = []
    func append(record: [String: Any]) throws { saved.append(record) }
    func records(taskID: UUID) throws -> [[String: Any]] { saved }
}
@MainActor private final class ConversationRuntime: AgentRuntimeClient {
    var onEvent: (([String: Any]) -> Void)?
    var onExit: (() -> Void)?
    var calls: [String] = []
    var results: [String: [String: Any]] = [:]
    var stopped = true
    var duringRequest: (() -> Void)?
    var requestHandler: (@MainActor (String) async -> Void)?
    func launch(python: String) throws {}
    func shutdown() {}
    func request(_ method: String, _ params: [String: Any], timeout: UInt64) async throws -> [String: Any] {
        calls.append(method); duringRequest?()
        await requestHandler?(method)
        return results[method] ?? (method == "stop" ? ["stopped": stopped] : [:])
    }
    func emitNative(_ task: WorkbenchTask, method: String, params: [String: Any]) {
        onEvent?(["event": "native", "taskId": task.id.uuidString, "instanceId": task.instanceID.uuidString,
                  "data": ["method": method, "params": params]])
    }
    func state(_ id: UUID, _ status: WorkbenchTaskStatus) {
        onEvent?(["event": "state", "taskId": id.uuidString, "data": ["status": status.rawValue]])
    }
}

final class AgentConversationManagementTests: XCTestCase {
    private func object(_ task: WorkbenchTask) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) as? [String: Any])
    }
    func testSchemaOneRetainsOptionalEncryptedConversationMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkbenchStore(root: root, keyData: Data(repeating: 7, count: 32))
        var task = WorkbenchTask(instanceID: UUID(), title: "原始标题🙂\r\n[.*]")
        task.status = .completed; task.messages = [.init(role: "user", text: "原始\t问题🙂\r\n")]
        var raw = try object(task)
        raw["customTitle"] = "自定义标题"; raw["pinnedAt"] = 42.0; raw["archivedAt"] = 43.0
        let decoded = try JSONDecoder().decode(WorkbenchTask.self, from: JSONSerialization.data(withJSONObject: raw))
        var snapshot = WorkbenchSnapshot(); snapshot.tasks = [decoded]
        try store.save(snapshot)
        let loaded = try store.load()
        let result = try object(XCTUnwrap(loaded.tasks.first))
        XCTAssertEqual(loaded.schemaVersion, 1)
        XCTAssertEqual(result["customTitle"] as? String, "自定义标题")
        XCTAssertEqual(result["pinnedAt"] as? Double, 42)
        XCTAssertEqual(result["archivedAt"] as? Double, 43)
        XCTAssertEqual(loaded.tasks[0].title, task.title)
        XCTAssertEqual(loaded.tasks[0].messages, task.messages)
        XCTAssertFalse(String(decoding: try Data(contentsOf: store.url), as: UTF8.self).contains("自定义标题"))
    }
    func testLegacySchemaOneWithoutMetadataLoadsUnchanged() throws {
        var task = WorkbenchTask(instanceID: UUID(), title: "旧会话")
        task.status = .completed
        let raw = try object(task)
        XCTAssertNil(raw["customTitle"]); XCTAssertNil(raw["pinnedAt"]); XCTAssertNil(raw["archivedAt"])
        XCTAssertEqual(try JSONDecoder().decode(WorkbenchTask.self, from: JSONEncoder().encode(task)).title, "旧会话")
    }

    @MainActor private func fixture() throws -> (AgentWorkbenchModel, ConversationRuntime, ConversationAudit, ConversationCredentials, URL, UUID) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let runtime = ConversationRuntime(), audit = ConversationAudit(), credentials = ConversationCredentials()
        let model = AgentWorkbenchModel(root: root, credentials: credentials, client: runtime, auditStore: audit)
        var task = WorkbenchTask(instanceID: UUID(), title: "原始问题🙂\r\n不要改写")
        task.status = .completed; task.sessionID = "session-a"
        task.messages = [.init(role: "user", text: "中文 [a-z].*\t问题🙂\r\n"), .init(role: "assistant", text: "Answer HELLO")]
        model.state.tasks = [task]
        return (model, runtime, audit, credentials, root, task.id)
    }
    @MainActor private func confirmCleanup(_ model: AgentWorkbenchModel, _ id: UUID) async {
        model.liveTasks.insert(id)
        await model.stop(id)
        model.markRead(id)
    }
    private func rawPayload(_ task: WorkbenchTask) throws -> Data {
        var raw = try object(task)
        for key in ["customTitle", "pinnedAt", "archivedAt", "cleanupEvidence"] { raw.removeValue(forKey: key) }
        return try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])
    }
    @MainActor func testMetadataActionsPreserveOriginalPayloadDraftAuditAndNeverCallRuntime() async throws {
        let (model, runtime, audit, _, root, id) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        await confirmCleanup(model, id)
        model.updateDraft(.task(id)) { $0.text = "仍可编辑的草稿" }
        let original = try rawPayload(model.state.tasks[0]), initialCalls = runtime.calls
        let initialAudit = try JSONSerialization.data(withJSONObject: audit.saved, options: [.sortedKeys])
        try model.renameConversation(id, title: " 新标题🙂 ")
        XCTAssertEqual(model.state.tasks[0].displayTitle, "新标题🙂")
        try model.setConversationPinned(id, pinned: true, now: Date(timeIntervalSince1970: 10))
        try model.setConversationArchived(id, archived: true)
        XCTAssertNotNil(model.state.tasks[0].archivedAt)
        try model.setConversationArchived(id, archived: false)
        try model.setConversationPinned(id, pinned: false)
        try model.renameConversation(id, title: nil)
        XCTAssertEqual(model.state.tasks[0].displayTitle, model.state.tasks[0].title)
        XCTAssertEqual(try rawPayload(model.state.tasks[0]), original)
        XCTAssertEqual(model.draft(for: .task(id)).text, "仍可编辑的草稿")
        XCTAssertEqual(runtime.calls, initialCalls)
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: audit.saved, options: [.sortedKeys]), initialAudit)
    }
    @MainActor func testMetadataSaveFailuresRetainPublishedStateAndEncryptedBytes() async throws {
        let (model, runtime, _, _, root, id) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        await confirmCleanup(model, id)
        model.persist()
        let originalStore = model.store, originalFile = try Data(contentsOf: model.store.url)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let initialCalls = runtime.calls
        for operation in 0..<4 {
            if operation == 3 { model.state.tasks[0].archivedAt = Date() }
            let original = try encoder.encode(model.state)
            model.store = WorkbenchStore(root: URL(fileURLWithPath: "/dev/null"))
            XCTAssertThrowsError(try { switch operation {
            case 0: try model.renameConversation(id, title: "失败标题")
            case 1: try model.setConversationPinned(id, pinned: true)
            case 2: try model.setConversationArchived(id, archived: true)
            default: try model.setConversationArchived(id, archived: false)
            } }())
            XCTAssertEqual(try encoder.encode(model.state), original)
            XCTAssertEqual(try Data(contentsOf: originalStore.url), originalFile)
        }
        XCTAssertEqual(runtime.calls, initialCalls)
        model.store = originalStore
    }
    @MainActor func testACPArchiveRequiresExplicitCleanupAndAllSafetyGates() async throws {
        let (model, runtime, _, _, root, id) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        XCTAssertNotNil(model.archiveBlockReason(id)) // Legacy terminal status alone is not a cleanup receipt.
        model.liveTasks.insert(id); runtime.stopped = false; await model.stop(id)
        XCTAssertNotNil(model.archiveBlockReason(id))
        runtime.state(id, .completed) // Cleanup alone cannot turn an unknown execution into a terminal result.
        runtime.stopped = true; await model.stop(id); model.markRead(id)
        XCTAssertNil(model.archiveBlockReason(id))
        let safe = model.state.tasks[0]
        for status in [WorkbenchTaskStatus.connecting, .running, .awaitingPermission, .cancelling, .unknown] {
            model.state.tasks[0] = safe; model.state.tasks[0].status = status
            XCTAssertThrowsError(try model.setConversationArchived(id, archived: true), "Reject \(status)")
        }
        model.state.tasks[0] = safe; model.state.tasks[0].unread = true
        XCTAssertNotNil(model.archiveBlockReason(id))
        model.state.tasks[0] = safe
        model.permissions = [.init(id: "pending", taskID: id, title: "pending", detail: "", options: [])]
        XCTAssertNotNil(model.archiveBlockReason(id)); model.permissions = []
        model.conversationControls.insert(id)
        XCTAssertNotNil(model.archiveBlockReason(id)); model.conversationControls.remove(id)
        model.liveTasks.insert(id)
        XCTAssertNotNil(model.archiveBlockReason(id)); model.liveTasks.remove(id)
        model.storageStatus = .loading
        XCTAssertThrowsError(try model.setConversationArchived(id, archived: true))
        XCTAssertThrowsError(try model.renameConversation(id, title: "blocked"))
        XCTAssertThrowsError(try model.setConversationPinned(id, pinned: true))
        model.storageStatus = .ready
        XCTAssertNil(model.archiveBlockReason(id))
    }
    @MainActor func testCleanupReceiptSurvivesEncryptedReopenButInvalidatesOnSessionOrActivity() async throws {
        let (model, _, _, credentials, root, id) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        await confirmCleanup(model, id); model.persist()
        let restored = AgentWorkbenchModel(root: root, credentials: credentials, client: ConversationRuntime(), auditStore: ConversationAudit())
        defer { restored.shutdown() }
        XCTAssertFalse(restored.isLive(id)); XCTAssertNil(restored.archiveBlockReason(id))
        try restored.setConversationArchived(id, archived: true)
        let receipt = restored.state.tasks[0].cleanupEvidence
        restored.mutate(id) { $0.sessionID = "session-b" }
        XCTAssertNil(restored.state.tasks[0].cleanupEvidence)
        XCTAssertNotNil(restored.archiveBlockReason(id))
        restored.state.tasks[0].sessionID = "session-a"; restored.state.tasks[0].cleanupEvidence = receipt
        restored.mutate(id) { $0.status = .running }
        XCTAssertNil(restored.state.tasks[0].cleanupEvidence)
        XCTAssertNil(restored.state.tasks[0].archivedAt)
        restored.state.tasks[0].cleanupEvidence = receipt
        restored.mutate(id) { $0.status = .unknown }
        XCTAssertNil(restored.state.tasks[0].cleanupEvidence)
    }
    @MainActor func testCleanupFailureReceiptIsBoundToExactTaskAndSession() throws {
        let (model, _, _, _, root, id) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        model.liveTasks.insert(id)
        model.fail(id, WorkbenchFailure("已确认清理的启动失败", taskRetained: false)); model.markRead(id)
        XCTAssertNil(model.archiveBlockReason(id))
        let receipt = try XCTUnwrap(model.state.tasks[0].cleanupEvidence)
        model.state.tasks[0].id = UUID()
        XCTAssertNotNil(model.archiveBlockReason(model.state.tasks[0].id))
        model.state.tasks[0].id = id; model.state.tasks[0].sessionID = nil
        XCTAssertNotNil(model.archiveBlockReason(id))
        XCTAssertEqual(receipt.taskID, id)
    }
    @MainActor private func nativeSafe(_ model: AgentWorkbenchModel, _ id: UUID, now: Date) throws {
        model.liveTasks.insert(id)
        var native = NativeTaskState(threadID: "thread", turnID: "turn", connection: .connected)
        native.recordTurnStatus("turn", status: "completed")
        model.state.tasks[0].nativeState = native
        model.state.tasks[0].status = .completed; model.state.tasks[0].unread = false
        let binding = try XCTUnwrap(model.nativeBackgroundBinding(id))
        model.nativeBackgroundObservations[id] = .init(count: 0, itemIDs: [], checkedAt: now, requestToken: UUID(), binding: binding)
    }
    @MainActor func testNativeArchiveNeedsFreshScopedZeroAndMatchingTerminalEvidence() throws {
        let (model, runtime, _, _, root, id) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let now = Date()
        try nativeSafe(model, id, now: now)
        let safe = model.state.tasks[0], observation = try XCTUnwrap(model.nativeBackgroundObservations[id])
        XCTAssertNil(model.archiveBlockReason(id, now: now), "A native observed session remains live without blocking metadata archive")
        XCTAssertNotNil(model.archiveBlockReason(id, now: now.addingTimeInterval(11)))
        model.nativeBackgroundObservations[id] = .init(count: 1, itemIDs: ["cmd"], checkedAt: now, requestToken: UUID(), binding: observation.binding)
        XCTAssertNotNil(model.archiveBlockReason(id, now: now))
        model.nativeBackgroundObservations[id] = observation
        model.nativeConnectionGenerations[safe.instanceID] = UUID()
        XCTAssertNotNil(model.archiveBlockReason(id, now: now)); model.nativeConnectionGenerations.removeAll()
        model.state.tasks[0].nativeState?.turnStatuses = nil
        XCTAssertNotNil(model.archiveBlockReason(id, now: now)); model.state.tasks[0] = safe
        model.state.tasks[0].status = .cancelled
        XCTAssertNotNil(model.archiveBlockReason(id, now: now)); model.state.tasks[0] = safe
        model.state.tasks[0].nativeState?.items = [.init(id: "unknown-command", turnID: "turn", kind: "commandExecution", title: "cmd", detail: "", status: "completed")]
        XCTAssertNotNil(model.archiveBlockReason(id, now: now)); model.state.tasks[0] = safe
        model.nativeInterruptUnverified.insert(id)
        XCTAssertNotNil(model.archiveBlockReason(id, now: now)); model.nativeInterruptUnverified.remove(id)
        model.state.tasks[0].nativeState?.connection = .disconnected
        XCTAssertNotNil(model.archiveBlockReason(id, now: now)); model.state.tasks[0] = safe
        model.liveTasks.remove(id)
        XCTAssertNotNil(model.archiveBlockReason(id, now: now)); model.liveTasks.insert(id)
        let calls = runtime.calls
        try model.setConversationArchived(id, archived: true, now: now)
        XCTAssertEqual(runtime.calls, calls)
    }
    @MainActor func testIncomingAttentionReappearsEvenWhenMetadataCannotSave() throws {
        let (model, runtime, audit, _, root, id) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        model.liveTasks.insert(id)
        model.store = WorkbenchStore(root: URL(fileURLWithPath: "/dev/null"))
        for status in [WorkbenchTaskStatus.running, .unknown, .completed] {
            model.state.tasks[0].archivedAt = Date()
            runtime.state(id, status)
            XCTAssertNil(model.state.tasks[0].archivedAt)
            XCTAssertEqual(model.state.tasks[0].status, status)
        }
        model.state.tasks[0].archivedAt = Date(); model.state.tasks[0].unread = false
        let callID = UUID()
        audit.saved = [["kind": "model.request", "callId": callID.uuidString, "requestHash": "hash", "destination": "https://example.test", "model": "fixture"]]
        runtime.onEvent?(["event": "modelApproval", "taskId": id.uuidString, "data": ["callId": callID.uuidString, "requestHash": "hash"]])
        XCTAssertEqual(model.modelApprovals.count, 1)
        XCTAssertNil(model.state.tasks[0].archivedAt, "The separate model approval append path must also reveal")
        model.persist()
        XCTAssertEqual(model.state.tasks[0].messages.first?.text, "中文 [a-z].*\t问题🙂\r\n")
        XCTAssertEqual(MailboxInbox.project(tasks: model.state.tasks, pendingTaskIDs: [id], postcards: []).singleEntry?.destination, .task(id))
    }
    func testLiteralLocalSearchMatchesOriginalCustomAndMessagesWithoutProcessItems() {
        var task = WorkbenchTask(instanceID: UUID(), title: "原始标题")
        task.status = .completed; task.customTitle = "Custom HELLO"
        task.messages = [.init(role: "assistant", text: "中文 [a-z].*\t内容")]
        task.nativeState = NativeTaskState(items: [.init(id: "x", kind: "commandExecution", title: "只在过程", detail: "隐藏过程秘密", status: "completed")])
        for query in ["原始", "hello", "中文", "[a-z].*", ".*", "\t"] {
            XCTAssertEqual(WorkbenchConversationPresentation.tasks([task], instanceID: nil, query: query).map(\.id), [task.id], query)
        }
        for query in ["^.*$", "中文.*内容", "隐藏过程秘密", "只在过程"] {
            XCTAssertTrue(WorkbenchConversationPresentation.tasks([task], instanceID: nil, query: query).isEmpty, query)
        }
    }
    func testPinnedOrderUsesPinThenCreationThenUUIDAndRepliesDoNotReorder() {
        var a = WorkbenchTask(instanceID: UUID(), title: "a"), b = a, c = a, d = a
        a.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        b.id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        c.id = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        d.id = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        a.status = .completed; b.status = .completed; c.status = .completed; d.status = .completed
        a.createdAt = Date(timeIntervalSince1970: 2); b.createdAt = a.createdAt; c.createdAt = Date(timeIntervalSince1970: 3); d.createdAt = Date(timeIntervalSince1970: 99)
        a.pinnedAt = Date(timeIntervalSince1970: 20); b.pinnedAt = a.pinnedAt; c.pinnedAt = Date(timeIntervalSince1970: 10)
        let expected = [a.id, b.id, c.id, d.id]
        XCTAssertEqual(WorkbenchConversationPresentation.tasks([d,c,b,a], instanceID: nil).map(\.id), expected)
        b.messages.append(.init(role: "assistant", text: "新回复")); b.customTitle = "改名"
        XCTAssertEqual(WorkbenchConversationPresentation.tasks([b,a,c,d], instanceID: nil).map(\.id), expected)
    }
    @MainActor func testInputLimitsRejectVisiblyWithoutTruncatingRecordsOrValidQuery() async throws {
        let (model, _, _, _, root, id) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let title = model.state.tasks[0].title
        XCTAssertThrowsError(try model.renameConversation(id, title: String(repeating: "中", count: 161)))
        XCTAssertThrowsError(try model.renameConversation(id, title: "a\nb"))
        XCTAssertEqual(model.state.tasks[0].title, title); XCTAssertNil(model.state.tasks[0].customTitle)
        let presentation = AgentWorkbenchPresentation()
        presentation.updateQuery("中文")
        presentation.updateQuery(String(repeating: "x", count: 257))
        XCTAssertEqual(presentation.query, "中文"); XCTAssertNotNil(presentation.queryError)
        presentation.updateQuery("hello")
        XCTAssertNil(presentation.queryError)
    }
    @MainActor func testArchivedScopeAttentionAndMailboxOpenExactTaskRevealsScope() throws {
        let (model, _, _, _, root, id) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        model.state.tasks[0].archivedAt = Date()
        XCTAssertTrue(WorkbenchConversationPresentation.tasks(model.state.tasks, instanceID: nil).isEmpty)
        XCTAssertEqual(WorkbenchConversationPresentation.tasks(model.state.tasks, instanceID: nil, scope: .archived).map(\.id), [id])
        let presentation = AgentWorkbenchPresentation()
        presentation.scope = .archived; presentation.filterInstanceID = UUID(); presentation.updateQuery("没有此词")
        let revision = model.conversationNavigationRevision
        model.state.tasks[0].unread = true
        let launcher = AgentLauncherController(model: model) {}
        defer { launcher.hide() }
        launcher.openEntry("task-\(id)")
        XCTAssertEqual(model.selectedTaskID, id)
        XCTAssertGreaterThan(model.conversationNavigationRevision, revision)
        presentation.reveal(model.state.tasks[0], pendingTaskIDs: model.pendingConversationTaskIDs)
        XCTAssertEqual(presentation.scope, .active); XCTAssertNil(presentation.filterInstanceID); XCTAssertEqual(presentation.query, "")
        model.state.tasks[0].unread = false
        model.openConversation(id)
        presentation.reveal(model.state.tasks[0], pendingTaskIDs: [])
        XCTAssertEqual(presentation.scope, .archived)
        model.state.tasks[0].unread = true
        XCTAssertEqual(WorkbenchConversationPresentation.tasks(model.state.tasks, instanceID: nil).map(\.id), [id])
        model.state.tasks[0].unread = false
        XCTAssertEqual(WorkbenchConversationPresentation.tasks(model.state.tasks, instanceID: nil, pendingTaskIDs: [id]).map(\.id), [id])
        model.state.tasks[0].status = .unknown
        XCTAssertEqual(WorkbenchConversationPresentation.tasks(model.state.tasks, instanceID: nil).map(\.id), [id])
    }

    @MainActor func testMailboxUnreadMutationRemainsActiveAfterRevealAndMarkRead() throws {
        let (model, _, _, _, root, id) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        model.state.tasks[0].archivedAt = Date()
        model.mutate(id) { $0.unread = true } // Same normalized production input used by the repaired fixture.
        let presentation = AgentWorkbenchPresentation()
        presentation.scope = .archived; presentation.filterInstanceID = UUID(); presentation.updateQuery("不存在的筛选")
        let launcher = AgentLauncherController(model: model) {}
        defer { launcher.hide() }
        launcher.openEntry("task-\(id)")
        presentation.reveal(model.state.tasks[0], pendingTaskIDs: model.pendingConversationTaskIDs)
        XCTAssertEqual(model.selectedTaskID, id); XCTAssertEqual(presentation.scope, .active)
        model.markRead(id)
        XCTAssertFalse(model.state.tasks[0].unread)
        XCTAssertEqual(WorkbenchConversationPresentation.tasks(model.state.tasks, instanceID: presentation.filterInstanceID,
            query: presentation.query, scope: presentation.scope, pendingTaskIDs: model.pendingConversationTaskIDs).map(\.id), [id])
    }
    @MainActor func testQuietArchivedUpstreamOpenRetainsArchivedVisibilityAfterMarkRead() throws {
        let (model, _, _, _, root, id) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let archivedAt = Date(timeIntervalSince1970: 42)
        model.state.tasks[0].archivedAt = archivedAt
        let presentation = AgentWorkbenchPresentation()
        presentation.filterInstanceID = UUID(); presentation.updateQuery("不存在的筛选")
        model.openConversation(id) // Same production entry used by upstream navigation; no new activity.
        presentation.reveal(model.state.tasks[0], pendingTaskIDs: model.pendingConversationTaskIDs)
        model.markRead(id)
        XCTAssertEqual(model.selectedTaskID, id); XCTAssertEqual(presentation.scope, .archived)
        XCTAssertEqual(model.state.tasks[0].archivedAt, archivedAt)
        XCTAssertEqual(WorkbenchConversationPresentation.tasks(model.state.tasks, instanceID: presentation.filterInstanceID,
            query: presentation.query, scope: presentation.scope, pendingTaskIDs: model.pendingConversationTaskIDs).map(\.id), [id])
    }

    @MainActor func testLargeSingleGraphemeCannotBypassTitleOrQueryBounds() throws {
        let (model, _, _, _, root, id) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let grapheme = "a" + String(repeating: "\u{301}", count: 4096)
        XCTAssertEqual(grapheme.count, 1)
        XCTAssertThrowsError(try model.renameConversation(id, title: grapheme))
        let presentation = AgentWorkbenchPresentation()
        presentation.updateQuery(grapheme)
        XCTAssertNotNil(presentation.queryError)
        XCTAssertTrue(presentation.query.isEmpty)
    }
    @MainActor func testStopInFlightCannotReplyArchiveOrBindReceiptToChangedSession() async throws {
        let (model, runtime, _, _, root, id) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        model.liveTasks.insert(id)
        runtime.duringRequest = {
            XCTAssertFalse(model.canReply(id))
            XCTAssertNotNil(model.archiveBlockReason(id))
            model.mutate(id) { $0.sessionID = "new-session-during-stop" }
        }
        await model.stop(id)
        XCTAssertNil(model.state.tasks[0].cleanupEvidence)
        XCTAssertNotNil(model.archiveBlockReason(id))
        XCTAssertTrue(model.isLive(id), "An old cleanup receipt must not drop the current event binding")
        XCTAssertNotNil(model.error)
    }

    @MainActor func testEveryNativeControlAndPendingModelApprovalBlocksArchive() throws {
        let (model, runtime, audit, _, root, id) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let now = Date()
        try nativeSafe(model, id, now: now)
        for control in 0..<6 {
            switch control {
            case 0: model.nativeRecovering.insert(id)
            case 1: model.nativeDetaching.insert(id)
            case 2: model.nativeInterruptPending.insert(id)
            case 3: model.nativeBackgroundStopping.insert(id)
            case 4: model.nativeBusy.insert(model.state.tasks[0].instanceID)
            default: model.nativeDeciding.insert("pending-decision")
            }
            XCTAssertNotNil(model.archiveBlockReason(id, now: now))
            model.nativeRecovering.removeAll(); model.nativeDetaching.removeAll(); model.nativeInterruptPending.removeAll()
            model.nativeBackgroundStopping.removeAll(); model.nativeBusy.removeAll(); model.nativeDeciding.removeAll()
        }
        let callID = UUID()
        audit.saved = [["kind": "model.request", "callId": callID.uuidString, "requestHash": "hash", "destination": "https://example.test", "model": "fixture"]]
        runtime.onEvent?(["event": "modelApproval", "taskId": id.uuidString, "data": ["callId": callID.uuidString, "requestHash": "hash"]])
        XCTAssertNotNil(model.archiveBlockReason(id, now: now))
        XCTAssertEqual(model.modelApprovals.count, 1)
    }
    func testReloadInvalidatesCleanupProofForActiveUnknownOrDifferentSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkbenchStore(root: root, keyData: Data(repeating: 9, count: 32))
        var task = WorkbenchTask(instanceID: UUID(), title: "历史证据")
        task.status = .completed; task.sessionID = "original"
        task.cleanupEvidence = .init(taskID: task.id, sessionID: "original", confirmedAt: Date())
        for status in [WorkbenchTaskStatus.running, .unknown, .completed] {
            var changed = task; changed.status = status; changed.archivedAt = Date()
            if status == .completed { changed.sessionID = "different" }
            var snapshot = WorkbenchSnapshot(); snapshot.tasks = [changed]
            try store.save(snapshot)
            let restored = try store.load().tasks[0]
            XCTAssertNil(restored.cleanupEvidence)
            if status != .completed { XCTAssertNil(restored.archivedAt) }
        }
    }
    @MainActor func testNativeMetadataPreservesTimelineBodiesAndRepeatedPinTimestamp() throws {
        let (model, runtime, _, _, root, id) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let now = Date()
        try nativeSafe(model, id, now: now)
        model.state.tasks[0].nativeState?.items = [.init(id: "command", turnID: "turn", kind: "commandExecution", title: "原始操作", detail: "原始\t记录🙂\r\n", status: "completed", completionObserved: true)]
        let original = try rawPayload(model.state.tasks[0]), calls = runtime.calls
        try model.renameConversation(id, title: "新显示名称")
        try model.setConversationPinned(id, pinned: true, now: now)
        try model.setConversationPinned(id, pinned: true, now: now.addingTimeInterval(1))
        XCTAssertEqual(model.state.tasks[0].pinnedAt, now)
        try model.setConversationArchived(id, archived: true, now: now)
        XCTAssertEqual(try rawPayload(model.state.tasks[0]), original)
        XCTAssertEqual(runtime.calls, calls)
    }

    @MainActor func testPendingACPPermissionReplyBlocksArchiveAfterConcurrentConfirmedStop() async throws {
        let (model, runtime, _, _, root, id) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        model.liveTasks.insert(id); model.state.tasks[0].status = .awaitingPermission
        let request = WorkbenchPermission(id: "pending-reply", taskID: id, title: "permission", detail: "", options: [])
        let option = WorkbenchPermission.Option(id: "deny", title: "拒绝", kind: "reject_once")
        model.permissions = [request]
        let started = expectation(description: "permission RPC remains pending")
        var resumePermission: CheckedContinuation<Void, Never>?
        runtime.requestHandler = { method in
            guard method == "permission" else { return }
            await withCheckedContinuation { continuation in resumePermission = continuation; started.fulfill() }
        }
        let response = Task { @MainActor in await model.respond(request, option: option) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(model.permissions.isEmpty)
        await model.stop(id)
        model.markRead(id)
        XCTAssertEqual(model.state.tasks[0].status, .cancelled)
        XCTAssertNotNil(model.state.tasks[0].cleanupEvidence)
        XCTAssertFalse(model.isLive(id))
        XCTAssertNotNil(model.archiveBlockReason(id))
        XCTAssertThrowsError(try model.setConversationArchived(id, archived: true))
        resumePermission?.resume(); await response.value
        XCTAssertNil(model.archiveBlockReason(id))
        try model.setConversationArchived(id, archived: true)
        XCTAssertNotNil(model.state.tasks[0].archivedAt)
    }

    @MainActor func testAcceptedLateNativeOutputAndProcessActivityReappearWithMailboxAttention() throws {
        let (model, runtime, _, _, root, id) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let now = Date()
        try nativeSafe(model, id, now: now)
        let original = model.state.tasks[0]
        let events: [(String, [String: Any])] = [
            ("item/agentMessage/delta", ["itemId": "late-reply", "delta": "迟到回复🙂"]),
            ("item/commandExecution/outputDelta", ["itemId": "late-output", "delta": "迟到输出"]),
            ("item/started", ["item": ["id": "late-tool", "type": "commandExecution", "status": "inProgress", "command": "fixture"]]),
            ("item/completed", ["item": ["id": "late-final", "type": "commandExecution", "status": "completed", "aggregatedOutput": "迟到最终输出"]])
        ]
        for (method, fields) in events {
            model.state.tasks[0] = original
            try model.setConversationArchived(id, archived: true, now: now)
            var params = fields; params["threadId"] = "thread"; params["turnId"] = "turn"
            runtime.emitNative(original, method: method, params: params)
            XCTAssertNil(model.state.tasks[0].archivedAt, method)
            XCTAssertTrue(model.state.tasks[0].unread, method)
            XCTAssertEqual(model.state.tasks[0].status, .completed)
            XCTAssertEqual(model.state.tasks[0].title, original.title)
            XCTAssertEqual(Array(model.state.tasks[0].messages.prefix(original.messages.count)), original.messages)
            XCTAssertEqual(WorkbenchConversationPresentation.tasks(model.state.tasks, instanceID: nil).map(\.id), [id])
            XCTAssertEqual(MailboxInbox.project(tasks: model.state.tasks, pendingTaskIDs: [], postcards: []).singleEntry?.destination, .task(id))
        }
    }
    @MainActor func testAcceptedLateNativeFinalSurvivesSaveFailureAndReappearsInMemory() throws {
        let (model, runtime, _, _, root, id) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let now = Date()
        try nativeSafe(model, id, now: now)
        model.state.tasks[0].nativeState?.items = [.init(id: "tool", turnID: "turn", kind: "commandExecution", title: "printf full", detail: "printf full\npartial", status: "inProgress", completionObserved: true, reconciledStatus: "completed")]
        try model.setConversationArchived(id, archived: true, now: now)
        let original = model.state.tasks[0]
        model.store = WorkbenchStore(root: URL(fileURLWithPath: "/dev/null"))
        runtime.emitNative(original, method: "item/completed", params: ["threadId": "thread", "turnId": "turn", "item": ["id": "tool", "type": "commandExecution", "status": "completed", "command": "printf full", "aggregatedOutput": "full🙂"]])
        XCTAssertEqual(model.state.tasks[0].nativeState?.items.first?.detail, "printf full\nfull🙂")
        XCTAssertNil(model.state.tasks[0].archivedAt)
        XCTAssertTrue(model.state.tasks[0].unread)
        XCTAssertEqual(model.state.tasks[0].messages.first, original.messages.first)
        XCTAssertEqual(WorkbenchConversationPresentation.tasks(model.state.tasks, instanceID: nil).map(\.id), [id])
        model.state.tasks[0] = original
        runtime.emitNative(original, method: "item/agentMessage/delta", params: ["threadId": "thread", "turnId": "turn", "itemId": "late-reply", "delta": "保存失败时仍保留的回复🙂"])
        model.persist()
        XCTAssertEqual(model.state.tasks[0].messages.last?.text, "保存失败时仍保留的回复🙂")
        XCTAssertEqual(model.state.tasks[0].status, .completed)
        XCTAssertNil(model.state.tasks[0].archivedAt); XCTAssertTrue(model.state.tasks[0].unread)
    }
    @MainActor func testIdenticalNativeFinalReplayRejectedDeltaAndEvidenceOnlyUpdateKeepArchive() throws {
        let (model, runtime, _, _, root, id) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let now = Date()
        try nativeSafe(model, id, now: now)
        model.state.tasks[0].nativeState?.items = [.init(id: "tool", turnID: "turn", kind: "commandExecution", title: "printf same", detail: "printf same\nsame", status: "inProgress", completionObserved: true, reconciledStatus: "completed")]
        try model.setConversationArchived(id, archived: true, now: now)
        let original = model.state.tasks[0]
        let final: [String: Any] = ["threadId": "thread", "turnId": "turn", "item": ["id": "tool", "type": "commandExecution", "status": "completed", "command": "printf same", "aggregatedOutput": "same"]]
        for _ in 0..<2 {
            runtime.emitNative(original, method: "item/completed", params: final)
            XCTAssertNotNil(model.state.tasks[0].archivedAt, "Same visible content and terminal evidence are not new activity")
            XCTAssertFalse(model.state.tasks[0].unread)
        }
        runtime.emitNative(original, method: "item/commandExecution/outputDelta", params: ["threadId": "thread", "turnId": "turn", "itemId": "tool", "delta": "rejected-after-final"])
        XCTAssertNotNil(model.state.tasks[0].archivedAt); XCTAssertFalse(model.state.tasks[0].unread)
        runtime.emitNative(original, method: "turn/completed", params: ["threadId": "thread", "turn": ["id": "turn", "status": "completed"]])
        XCTAssertNotNil(model.state.tasks[0].archivedAt, "A repeated final turn must not manufacture new unread attention")
        XCTAssertFalse(model.state.tasks[0].unread)
        runtime.emitNative(original, method: "item/agentMessage/delta", params: ["threadId": "wrong-thread", "turnId": "turn", "itemId": "wrong", "delta": "must reject"])
        XCTAssertNotNil(model.state.tasks[0].archivedAt)
    }
    @MainActor func testBackgroundReconciliationAndObservationDoNotRevealArchivedConversation() async throws {
        let (model, runtime, _, _, root, id) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let now = Date()
        try nativeSafe(model, id, now: now)
        model.state.tasks[0].nativeState?.items = [.init(id: "tool", turnID: "turn", kind: "commandExecution", title: "fixture", detail: "original", status: "completed", completionObserved: true)]
        try model.setConversationArchived(id, archived: true, now: now)
        let originalMessages = model.state.tasks[0].messages
        runtime.results["native_reconcile"] = ["threadId": "thread", "turns": [["id": "turn", "status": "completed"]], "items": [["turnId": "turn", "item": ["id": "tool", "type": "commandExecution", "status": "completed", "aggregatedOutput": "query must not replace raw body"]]]]
        runtime.results["native_background_status"] = ["threadId": "thread", "count": 0, "itemIds": []]
        await model.reconcileNativeHistory(id); await model.refreshNativeBackgroundStatus(id)
        XCTAssertNotNil(model.state.tasks[0].archivedAt); XCTAssertFalse(model.state.tasks[0].unread)
        XCTAssertEqual(model.state.tasks[0].nativeState?.items.first?.detail, "original")
        XCTAssertEqual(model.state.tasks[0].messages, originalMessages)
    }

    @MainActor func testAcceptedKnownOldTurnFinalRevealsOnlyWhenBodyActuallyChanges() throws {
        let (model, runtime, _, _, root, id) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let now = Date()
        try nativeSafe(model, id, now: now)
        model.state.tasks[0].nativeState?.items = [.init(id: "old-tool", turnID: "old-turn", kind: "commandExecution", title: "fixture", detail: "partial", status: "inProgress", completionObserved: true, reconciledStatus: "completed")]
        try model.setConversationArchived(id, archived: true, now: now)
        let task = model.state.tasks[0]
        runtime.emitNative(task, method: "item/completed", params: ["threadId": "thread", "turnId": "old-turn", "item": ["id": "old-tool", "type": "commandExecution", "status": "completed", "aggregatedOutput": "full old output"]])
        XCTAssertEqual(model.state.tasks[0].nativeState?.items.first?.detail, "full old output")
        XCTAssertEqual(model.state.tasks[0].nativeState?.turnID, "turn")
        XCTAssertEqual(model.state.tasks[0].status, .completed)
        XCTAssertNil(model.state.tasks[0].archivedAt); XCTAssertTrue(model.state.tasks[0].unread)
    }

}
