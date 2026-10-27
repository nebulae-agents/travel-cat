import Foundation

enum WorkbenchConversationScope: String, CaseIterable, Identifiable {
    case active, archived
    var id: String { rawValue }
    var title: String { self == .active ? "对话" : "已归档" }
}

enum WorkbenchConversationInput {
    static let titleLimit = 160
    static let queryLimit = 256
    static func title(_ source: String?) throws -> String? {
        guard let source else { return nil }
        guard source.utf8.count <= 2048, source.count <= titleLimit, !source.contains("\0"), !source.contains(where: \.isNewline) else {
            throw WorkbenchFailure("名称最多 160 个字符，请使用单行文字；组合文字过长时请缩短。原始问题会完整保留。")
        }
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

extension WorkbenchTask {
    var requiresConversationAttention: Bool { unread || status.active || status == .unknown }
    mutating func normalizeConversationMetadata(previousSessionID: String?, isLive: Bool, pending: Bool) {
        if sessionID != previousSessionID || isLive || status.active || status == .unknown || nativeState != nil ||
            cleanupEvidence.map({ $0.taskID != id || $0.sessionID != sessionID }) == true {
            cleanupEvidence = nil
        }
        if requiresConversationAttention || pending { archivedAt = nil }
    }
}

@MainActor
extension AgentWorkbenchModel {
    var pendingConversationTaskIDs: Set<UUID> { Set(permissions.map(\.taskID) + modelApprovals.map(\.taskID)) }

    /// Used by mailbox/upstream navigation, even when the selected ID has not changed.
    func openConversation(_ id: UUID) {
        guard let task = state.tasks.first(where: { $0.id == id }) else { return }
        preferredInstanceID = task.instanceID; selectedTaskID = id
        conversationNavigationRevision += 1
    }

    /// Only accepted runtime changes can reveal a quiet archived conversation.
    /// Query/recovery metadata and identical final replays are not new visible activity.
    func mutateNativeConversationEvent(_ id: UUID, isRuntimeEvent: Bool = true, _ change: (inout WorkbenchTask) -> Void) {
        mutate(id) { task in
            guard isRuntimeEvent, task.archivedAt != nil else { change(&task); return }
            let messages = task.messages
            let items = nativeConversationActivityItems(task)
            change(&task)
            if task.messages != messages || nativeConversationActivityItems(task) != items {
                task.archivedAt = nil; task.unread = true
            }
        }
    }

    private func nativeConversationActivityItems(_ task: WorkbenchTask) -> [NativeTimelineItem] {
        (task.nativeState?.items ?? []).map { item in
            var value = item
            value.status = item.evidenceStatus
            value.completionObserved = item.hasTerminalEvidence
            value.reconciledStatus = nil; value.liveCompletionObserved = nil
            return value
        }
    }

    func renameConversation(_ id: UUID, title: String?) throws {
        let value = try WorkbenchConversationInput.title(title)
        try saveConversationMetadata(id) { $0.customTitle = value }
    }

    func setConversationPinned(_ id: UUID, pinned: Bool, now: Date = Date()) throws {
        try saveConversationMetadata(id) { task in
            if pinned { if task.pinnedAt == nil { task.pinnedAt = now } }
            else { task.pinnedAt = nil }
        }
    }

    func setConversationArchived(_ id: UUID, archived: Bool, now: Date = Date()) throws {
        if archived, let reason = archiveBlockReason(id, now: now) { throw WorkbenchFailure(reason) }
        try saveConversationMetadata(id) { $0.archivedAt = archived ? ($0.archivedAt ?? now) : nil }
    }

    /// No runtime request, detach, stop or audit mutation belongs to metadata editing.
    private func saveConversationMetadata(_ id: UUID, change: (inout WorkbenchTask) -> Void) throws {
        try requireStorageReady()
        guard let index = state.tasks.firstIndex(where: { $0.id == id }) else { throw WorkbenchFailure("找不到该对话。") }
        var next = state
        change(&next.tasks[index])
        try store.save(next)
        state = next
    }

    func archiveBlockReason(_ id: UUID, now: Date = Date()) -> String? {
        guard isStorageReady else { return "安全存储尚未就绪，请稍后重试归档。" }
        guard let task = state.tasks.first(where: { $0.id == id }) else { return "找不到该对话。" }
        guard [.completed, .cancelled, .failed].contains(task.status) else { return "执行中或状态待核实的对话不能归档。" }
        guard !task.unread else { return "请先阅读新消息，再归档。" }
        guard !pendingConversationTaskIDs.contains(id), !hasConversationDecisionInFlight else { return "请先处理待确认请求，再归档。" }
        guard acpPermissionReplies[id]?.isEmpty != false, !conversationControls.contains(id), !nativeRecovering.contains(id), !nativeDetaching.contains(id),
              !nativeInterruptPending.contains(id), !nativeInterruptUnverified.contains(id), !nativeBackgroundStopping.contains(id),
              !nativeBusy.contains(task.instanceID), nativeReconciliationRequests[id] == nil,
              !isDraftSubmitting(.task(id)) else { return "会话操作尚未确认，请稍后再归档。" }
        if let native = task.nativeState {
            guard native.connection == .connected, let turn = native.turnID,
                  native.turnStatuses?[turn] == [.completed: "completed", .cancelled: "interrupted", .failed: "failed"][task.status],
                  native.pendingOperation == nil || [.confirmed, .rejected].contains(native.pendingOperation!.status),
                  WorkbenchConversationPresentation.processItems(task).allSatisfy(\.hasTerminalEvidence) else {
                return "请先连接并核对本轮和过程记录的最终状态，再归档。"
            }
            guard let observation = freshNativeBackgroundObservation(id, now: now), observation.count == 0 else {
                return "请先核对后台命令为 0，再归档；归档不会停止或断开会话。"
            }
        } else {
            guard !liveTasks.contains(id), let receipt = task.cleanupEvidence,
                  receipt.taskID == id, receipt.sessionID == task.sessionID,
                  receipt.confirmedAt.timeIntervalSinceReferenceDate.isFinite else {
                return "此会话缺少已确认的清理记录。仍连接时可先使用“结束会话”；旧记录或普通断线不能证明清理完成。"
            }
        }
        return nil
    }
}
