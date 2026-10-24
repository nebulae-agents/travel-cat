import Foundation
import Combine

@MainActor
final class AgentWorkbenchPresentation: ObservableObject {
    @Published var filterInstanceID: UUID?
    @Published var modelConsent: [UUID: Bool] = [:]
}

enum WorkbenchConversationPresentation {
    static func shortTitle(_ source: String) -> String {
        let line = source.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? ""
        let text = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if text.isEmpty { return "新对话" }
        return text.count > 32 ? String(text.prefix(31)) + "…" : text
    }
    static func tasks(_ source: [WorkbenchTask], instanceID: UUID?) -> [WorkbenchTask] {
        source.filter { instanceID == nil || $0.instanceID == instanceID }.sorted { $0.createdAt > $1.createdAt }
    }
    private static func isProcessMessage(_ message: WorkbenchMessage) -> Bool {
        guard message.role == "system", message.text.contains(" · "), let status = message.text.components(separatedBy: " · ").last else { return false }
        return ["pending", "in_progress", "inProgress", "completed", "failed", "cancelled", "canceled", "running", "success", "error"].contains(status)
    }
    static func visibleMessages(_ task: WorkbenchTask) -> [WorkbenchMessage] {
        task.messages.filter { !isProcessMessage($0) && ($0.role != "assistant" || !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
    }
    static func processMessages(_ task: WorkbenchTask) -> [WorkbenchMessage] { task.messages.filter(isProcessMessage) }
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
