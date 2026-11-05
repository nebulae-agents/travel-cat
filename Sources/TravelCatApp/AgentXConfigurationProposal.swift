import Foundation

struct AgentXConfigurationProposal: Codable, Equatable {
    struct Change: Codable, Equatable, Identifiable {
        var id: String
        var dimension: String
        var value: String
        var reason: String
        var title: String { dimension == "body" ? "定义正文" : AgentXCharacterDimension(rawValue: dimension)?.title ?? dimension }
    }
    var summary: String
    var changes: [Change]

    static func parse(_ text: String) throws -> Self {
        var source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, source.utf8.count <= 2_000_000 else { throw AgentXError.invalid("配置建议为空或过大。") }
        var markedJSON = false
        if source.hasPrefix("```json") {
            markedJSON = true
            guard source.hasPrefix("```json\n"), source.hasSuffix("\n```") else { throw AgentXError.invalid("配置建议 JSON 围栏不完整。") }
            source = String(source.dropFirst(8).dropLast(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if source.hasPrefix("```\n"), source.hasSuffix("\n```") {
            let inner = String(source.dropFirst(4).dropLast(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            if inner.hasPrefix("{") || inner.hasPrefix("[") { source = inner; markedJSON = true }
        }
        guard markedJSON || source.hasPrefix("{") || source.hasPrefix("[") else {
            return .init(summary: "正文修改建议", changes: [.init(id: "body", dimension: "body", value: source, reason: "兼容旧版正文建议；请审阅后采用。")])
        }
        let invalid = AgentXError.invalid("配置建议格式无效：仅支持正文及 12 个人物维度，每个维度只能出现一次。")
        guard let data = source.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(root.keys) == Set(["summary", "changes"]), root["summary"] is String,
              let entries = root["changes"] as? [[String: Any]], !entries.isEmpty, entries.count <= 13 else { throw invalid }
        let allowed = Set(AgentXCharacterDimension.allCases.map(\.rawValue) + ["body"])
        var ids = Set<String>(); var dimensions = Set<String>(); var changes: [Change] = []
        for entry in entries {
            guard Set(entry.keys) == Set(["id", "dimension", "value", "reason"]),
                  let id = entry["id"] as? String, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let dimension = entry["dimension"] as? String, allowed.contains(dimension),
                  let value = entry["value"] as? String, let reason = entry["reason"] as? String,
                  ids.insert(id).inserted, dimensions.insert(dimension).inserted else { throw invalid }
            changes.append(.init(id: id, dimension: dimension, value: value, reason: reason))
        }
        return .init(summary: root["summary"] as? String ?? "", changes: changes)
    }
}
