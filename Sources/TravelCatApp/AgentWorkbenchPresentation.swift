import Foundation
import Combine

@MainActor
final class AgentWorkbenchPresentation: ObservableObject {
    @Published var filterInstanceID: UUID?
    @Published var scope: WorkbenchConversationScope = .active
    @Published private(set) var query = ""
    @Published private(set) var queryError: String?
    func updateQuery(_ value: String) {
        guard value.utf8.count <= 2048, value.count <= WorkbenchConversationInput.queryLimit, !value.contains("\0") else {
            queryError = "搜索内容过长或含有空字符。请缩短后重试（最多 256 个字符）。"; return
        }
        query = value; queryError = nil
    }
    func reveal(_ task: WorkbenchTask, pendingTaskIDs: Set<UUID>) {
        if let filterInstanceID, filterInstanceID != task.instanceID { self.filterInstanceID = nil }
        scope = WorkbenchConversationPresentation.isArchived(task, pendingTaskIDs: pendingTaskIDs) ? .archived : .active
        if !WorkbenchConversationPresentation.matches(task, query: query) { updateQuery("") }
    }
    @Published var modelConsent: [UUID: Bool] = [:]
}

enum WorkbenchConversationPresentation {
    static func shortTitle(_ source: String) -> String {
        let line = source.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? ""
        let text = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if text.isEmpty { return "新对话" }
        return text.count > 32 ? String(text.prefix(31)) + "…" : text
    }
    static func isArchived(_ task: WorkbenchTask, pendingTaskIDs: Set<UUID> = []) -> Bool {
        task.archivedAt != nil && !task.requiresConversationAttention && !pendingTaskIDs.contains(task.id)
    }
    static func matches(_ task: WorkbenchTask, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return ([task.title, task.customTitle ?? ""] + task.messages.map(\.text)).contains {
            $0.range(of: query, options: [.caseInsensitive, .literal], locale: Locale(identifier: "en_US_POSIX")) != nil
        }
    }
    static func tasks(_ source: [WorkbenchTask], instanceID: UUID?, query: String = "", scope: WorkbenchConversationScope = .active, pendingTaskIDs: Set<UUID> = []) -> [WorkbenchTask] {
        source.filter {
            (instanceID == nil || $0.instanceID == instanceID) && matches($0, query: query) &&
            isArchived($0, pendingTaskIDs: pendingTaskIDs) == (scope == .archived)
        }.sorted {
            if ($0.pinnedAt != nil) != ($1.pinnedAt != nil) { return $0.pinnedAt != nil }
            if let a = $0.pinnedAt, let b = $1.pinnedAt, a != b { return a > b }
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
    private static func isProcessMessage(_ message: WorkbenchMessage) -> Bool {
        guard message.role == "system", message.text.contains(" · "), let status = message.text.components(separatedBy: " · ").last else { return false }
        return ["pending", "in_progress", "inProgress", "completed", "failed", "cancelled", "canceled", "running", "success", "error"].contains(status)
    }
    static func visibleMessages(_ task: WorkbenchTask) -> [WorkbenchMessage] {
        task.messages.filter { !isProcessMessage($0) && ($0.role != "assistant" || !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
    }
    static func processMessages(_ task: WorkbenchTask) -> [WorkbenchMessage] { task.messages.filter(isProcessMessage) }
    static func latestAssistantBody(_ task: WorkbenchTask) -> WorkbenchMessage? {
        task.messages.last { $0.role == "assistant" && $0.sourceKind != "acp.agent_thought_chunk" }
    }
    static func thinkingItems(_ task: WorkbenchTask) -> [AgentThinkingContent] {
        task.nativeState?.items.compactMap(AgentThinkingContent.native) ?? []
    }
    static func processItems(_ task: WorkbenchTask) -> [NativeTimelineItem] {
        task.nativeState?.items.filter { !["agentMessage", "userMessage", "reasoning"].contains($0.kind) } ?? []
    }
    static func hasProcessFailure(_ task: WorkbenchTask) -> Bool {
        processItems(task).contains { $0.hasTerminalEvidence && $0.evidenceStatus == "failed" } || processMessages(task).contains { $0.text.hasSuffix(" · failed") || $0.text.hasSuffix(" · error") }
    }
    static func images(in inventory: LocalRuntimeInventory, context: String) -> [LocalRuntimeInventory.Image] {
        guard inventory.contexts.contains(where: { $0.name == context && $0.local && $0.available }) else { return [] }
        return inventory.images.filter { $0.context == context }
    }

}
