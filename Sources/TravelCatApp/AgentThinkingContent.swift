import Foundation
import Combine

/// A read-only projection. Native raw actions always retain the saved detail, never this display text.
struct AgentThinkingContent: Identifiable {
    let id: String
    let text: String
    let rawSource: String?

    static func acp(_ message: WorkbenchMessage) -> Self? {
        guard message.role == "assistant", message.sourceKind == "acp.agent_thought_chunk" else { return nil }
        return .init(id: "acp.thought:" + message.id.uuidString, text: message.text, rawSource: nil)
    }

    static func native(_ item: NativeTimelineItem) -> Self? {
        guard item.kind == "reasoning", hasText(item.detail) else { return nil }
        let id = "native.reasoning:" + item.id
        guard let object = try? JSONSerialization.jsonObject(with: Data(item.detail.utf8)) as? [String: Any] else {
            return .init(id: id, text: item.detail, rawSource: item.detail)
        }
        var texts: [String] = []
        var knownField = false
        let knownKeys: Set<String> = ["id", "type", "text", "summary", "content"]
        var unknownShape = !Set(object.keys).isSubset(of: knownKeys)
        // Fixed field order, then the received array order. Separators exist only in the projection.
        for field in ["text", "summary", "content"] {
            guard let value = object[field] else { continue }
            knownField = true
            let parts = textParts(value)
            texts += parts.texts
            unknownShape = unknownShape || parts.unknown
        }
        if !texts.isEmpty { return .init(id: id, text: texts.joined(separator: "\n\n"), rawSource: item.detail) }
        if knownField && !unknownShape { return nil }
        // Unknown/legacy payloads remain reachable without guessing at their meaning.
        return .init(id: id, text: item.detail, rawSource: item.detail)
    }

    private static func hasText(_ text: String) -> Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private static func textParts(_ value: Any) -> (texts: [String], unknown: Bool) {
        if let text = value as? String { return (hasText(text) ? [text] : [], false) }
        guard let values = value as? [Any] else { return ([], true) }
        var result: [String] = []
        var unknown = false
        for value in values {
            let text: String
            if let string = value as? String { text = string }
            else if let part = value as? [String: Any], let string = part["text"] as? String {
                text = string
                if !Set(part.keys).isSubset(of: ["type", "text"]) { unknown = true }
            }
            else { unknown = true; continue }
            if hasText(text) { result.append(text) }
        }
        return (result, unknown)
    }
}

struct AgentThinkingIdentity: Hashable {
    let taskID: UUID
    let entryID: String
}

/// Ephemeral per conversation-view session; content updates never key or reset manual expansion.
@MainActor final class AgentThinkingExpansion: ObservableObject {
    @Published private var expanded: Set<AgentThinkingIdentity> = []
    func isExpanded(_ identity: AgentThinkingIdentity) -> Bool { expanded.contains(identity) }
    func setExpanded(_ value: Bool, for identity: AgentThinkingIdentity) {
        if value { expanded.insert(identity) } else { expanded.remove(identity) }
    }
}

/// Presentation-only memoization: private cache updates never publish or mutate the stored task.
/// Keeping nil projections also avoids reparsing known-empty reasoning on every status refresh.
@MainActor final class AgentNativeThinkingCache: ObservableObject {
    private struct Entry {
        let source: AgentMarkdownSourceIdentity
        let content: AgentThinkingContent?
    }
    private var entries: [AgentThinkingIdentity: Entry] = [:]
    private let project: (NativeTimelineItem) -> AgentThinkingContent?
    init(project: @escaping (NativeTimelineItem) -> AgentThinkingContent? = AgentThinkingContent.native) { self.project = project }

    func contents(for task: WorkbenchTask) -> [AgentThinkingContent] {
        var retained: [AgentThinkingIdentity: Entry] = [:]
        var result: [AgentThinkingContent] = []
        for item in task.nativeState?.items ?? [] where item.kind == "reasoning" {
            let identity = AgentThinkingIdentity(taskID: task.id, entryID: "native.reasoning:" + item.id)
            let source = AgentMarkdownSourceIdentity(item.detail)
            let entry: Entry
            if let previous = entries[identity], previous.source == source { entry = previous }
            else { entry = Entry(source: source, content: project(item)) }
            retained[identity] = entry
            if let content = entry.content { result.append(content) }
        }
        entries = retained
        return result
    }
}
