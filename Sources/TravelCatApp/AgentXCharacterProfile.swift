import Foundation
import Yams

enum AgentXCharacterDimension: String, CaseIterable, Codable, Identifiable {
    case identity, personality, traits, background, motivation, relations, boundaries, abilities, voice, arc, memory, model
    var id: String { rawValue }
    var title: String {
        switch self {
        case .identity: "身份"; case .personality: "性格"; case .traits: "特征与习惯"
        case .background: "背景"; case .motivation: "动机"; case .relations: "关系"
        case .boundaries: "底线"; case .abilities: "能力"; case .voice: "说话方式"
        case .arc: "成长弧线"; case .memory: "记忆设定"; case .model: "模型与预算设定"
        }
    }
    var mappedFile: String {
        switch self {
        case .identity, .motivation, .abilities: "agent.md"
        case .personality, .traits, .boundaries, .voice: "soul.md"
        case .background: "memory/background.md"
        case .relations: "memory/relations.agentx.md"
        case .arc: "arc.md"
        case .memory, .model: "memory/character-settings.md"
        }
    }
}

/// Keeps imported YAML as the source of truth; a separate notes overlay supports
/// freeform editing without discarding structured values or future schema fields.
struct AgentXCharacterProfile: Codable, Equatable {
    private var originalYAML = ""
    private var notes: [String: String] = [:]
    init() {}
    static func load(from document: AgentXDefinitionDocument) throws -> Self {
        var profile = Self()
        profile.originalYAML = document.files["character.yaml"] ?? ""
        let root = try profile.root()
        if let overlay = root["agentx_notes"] {
            guard let values = overlay as? [String: String] else { throw AgentXDefinitionError.invalidDocument }
            profile.notes = values
        }
        return profile
    }
    func text(for dimension: AgentXCharacterDimension) -> String {
        if let value = notes[dimension.rawValue] { return value }
        guard let value = try? root()[dimension.rawValue] else { return "" }
        return Self.describe(Self.publicValue(value))
    }
    mutating func setText(_ text: String, for dimension: AgentXCharacterDimension) throws {
        guard !text.contains("<!-- agentx-character:"), text.utf8.count <= 128 * 1_024 else { throw AgentXDefinitionError.invalidDocument }
        notes[dimension.rawValue] = text
    }
    func applying(to document: AgentXDefinitionDocument) throws -> AgentXDefinitionDocument {
        var root = try root()
        if !notes.isEmpty { root["agentx_notes"] = notes }
        var copy = document
        copy.files["character.yaml"] = notes.isEmpty && !originalYAML.isEmpty ? originalYAML : try Yams.dump(object: root, sortKeys: true)
        let secretValues = Self.directorStrings(root)
        func section(_ dimension: AgentXCharacterDimension) -> String {
            var value = text(for: dimension)
            for secret in secretValues where !secret.isEmpty { value = value.replacingOccurrences(of: secret, with: "[导演信息已隐藏]") }
            return value.isEmpty ? "" : "### \(dimension.title)\n\(value)"
        }
        // The runtime reads agent.md. Do not rely on an unimplemented memory engine.
        let publicDimensions = AgentXCharacterDimension.allCases.filter { $0 != .model && $0 != .memory }
        let summary = publicDimensions.map(section).filter { !$0.isEmpty }.joined(separator: "\n\n")
        copy = try copy.replacingBody(Self.managed(try copy.bodyText(), content: "## 人物公开设定\n\n" + summary))
        let mappings: [(String, [AgentXCharacterDimension])] = [
            ("soul.md", [.personality, .traits, .boundaries, .voice]),
            ("memory/background.md", [.background]),
            ("memory/relations.agentx.md", [.relations]),
            ("arc.md", [.arc]),
            ("memory/character-settings.md", [.memory, .model])
        ]
        for (path, dimensions) in mappings {
            let content = dimensions.map(section).filter { !$0.isEmpty }.joined(separator: "\n\n")
            copy.files[path] = try Self.managed(copy.files[path] ?? "", content: content)
        }
        try copy.validate()
        return copy
    }
    private func root() throws -> [String: Any] {
        guard !originalYAML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        guard let root = try Yams.load(yaml: originalYAML) as? [String: Any] else { throw AgentXDefinitionError.invalidDocument }
        return root
    }
    private static func isDirectorKey(_ key: String) -> Bool {
        let key = key.lowercased()
        return key.contains("director") || key.contains("导演")
    }
    private static func publicValue(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            return dictionary.filter { !isDirectorKey($0.key) }.mapValues(publicValue)
        }
        if let array = value as? [Any] { return array.map(publicValue) }
        return value
    }
    private static func directorStrings(_ value: Any, secret: Bool = false) -> [String] {
        if let dictionary = value as? [String: Any] {
            return dictionary.flatMap { directorStrings($0.value, secret: secret || isDirectorKey($0.key)) }
        }
        if let array = value as? [Any] { return array.flatMap { directorStrings($0, secret: secret) } }
        return secret ? [String(describing: value)] : []
    }
    private static func describe(_ value: Any) -> String {
        if let dictionary = value as? [String: Any] {
            return dictionary.keys.sorted().map { "\($0)：\(describe(dictionary[$0]!))" }.joined(separator: "\n")
        }
        if let array = value as? [Any] { return array.map { "• " + describe($0) }.joined(separator: "\n") }
        if value is NSNull { return "" }
        return String(describing: value)
    }
    private static func managed(_ existing: String, content: String) throws -> String {
        let start = "<!-- agentx-character:start -->"
        let end = "<!-- agentx-character:end -->"
        guard !content.contains("<!-- agentx-character:") else { throw AgentXDefinitionError.invalidDocument }
        let block = start + "\n" + content + "\n" + end
        let starts = existing.components(separatedBy: start).count - 1
        let ends = existing.components(separatedBy: end).count - 1
        if starts == 0 && ends == 0 { return existing + (existing.isEmpty ? "" : "\n\n") + block + "\n" }
        guard starts == 1, ends == 1, let first = existing.range(of: start), let last = existing.range(of: end), first.upperBound <= last.lowerBound else { throw AgentXDefinitionError.invalidDocument }
        return existing.replacingCharacters(in: first.lowerBound..<last.upperBound, with: block)
    }
}
