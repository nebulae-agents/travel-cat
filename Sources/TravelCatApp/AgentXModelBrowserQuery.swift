import Foundation

struct AgentXModelBrowserEntry: Identifiable {
    struct ID: Hashable { let provider: String; let model: String }
    let providerID: String
    let providerName: String
    let providerEnabled: Bool
    let model: AgentXCatalogModel
    var id: ID { .init(provider: providerID, model: model.id) }
    var variantLabel: String? {
        let label = model.id + " " + (model.name ?? "")
        if label.localizedCaseInsensitiveContains("batch") { return "批处理版" }
        if label.range(of: #"(?:19|20)[0-9]{2}[-_/]?[0-9]{2}[-_/]?[0-9]{2}"#, options: .regularExpression) != nil { return "日期版本" }
        return nil
    }
    var choice: AgentXConversationModel { .init(providerID: providerID, model: model.id) }
    var vendor: String {
        guard model.id.contains("/"), let prefix = model.id.split(separator: "/").first else { return "其他模型" }
        return String(prefix)
    }
    func disabledReason(requiresEnabled: Bool = true, category: AgentXModelCategory = .chat) -> String? {
        if !providerEnabled { return "模型服务已停用" }
        if !model.available { return "当前目录已不可用" }
        if category == .chat && !model.supportsTextOutput { return "不支持文本输出" }
        if requiresEnabled && !model.enabled { return "模型尚未启用" }
        return nil
    }
}

struct AgentXModelBrowserGroup: Identifiable {
    let id: String
    let name: String
    let vendors: [Vendor]
    struct Vendor: Identifiable {
        let id: String
        let entries: [AgentXModelBrowserEntry]
    }
}

enum AgentXModelBrowserQuery {
    static func normalized(_ value: String) -> String {
        String(value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")).unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
    static func score(_ model: AgentXCatalogModel, query: String) -> Int? {
        let needle = normalized(query)
        if needle.isEmpty { return 0 }
        let raw = [model.id, model.name ?? ""]
        if raw.contains(where: { $0.caseInsensitiveCompare(query.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame }) { return 0 }
        let fields = raw.map(normalized)
        if fields.contains(needle) { return 1 }
        if fields.contains(where: { $0.hasPrefix(needle) }) { return 2 }
        if fields.contains(where: { $0.contains(needle) }) { return 3 }
        let aliases = ["ds": "deepseek", "gpt": "gpt", "claude": "claude"]
        let terms = query.lowercased().components(separatedBy: .whitespacesAndNewlines).map(normalized).filter { !$0.isEmpty }.map { aliases[$0] ?? $0 }
        if terms.allSatisfy({ term in fields.contains { $0.contains(term) } }) { return 5 }
        // Short terms must match literally; longer abbreviations may omit letters in order.
        if terms.allSatisfy({ term in fields.contains { field in
            if field.contains(term) { return true }
            guard term.count >= 3 else { return false }
            var remaining = term[...]
            for character in field where remaining.first == character { remaining.removeFirst(); if remaining.isEmpty { return true } }
            return false
        } }) { return 6 }
        return nil
    }
    static func results(providers: [AgentXProvider], query: String = "") -> [AgentXModelBrowserEntry] {
        providers.flatMap { provider in
            (provider.modelSelection?.models ?? provider.models.map { .init(id: $0, enabled: true) }).map {
                AgentXModelBrowserEntry(providerID: provider.id, providerName: provider.name, providerEnabled: provider.enabled, model: $0)
            }
        }.compactMap { entry -> (AgentXModelBrowserEntry, Int)? in
            guard let rank = score(entry.model, query: query) else { return nil }; return (entry, rank)
        }.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            if lhs.0.model.id != rhs.0.model.id { return lhs.0.model.id < rhs.0.model.id }
            return lhs.0.providerID < rhs.0.providerID
        }.map { $0.0 }
    }
    static func favorites(providers: [AgentXProvider]) -> [AgentXModelBrowserEntry] { results(providers: providers).filter { $0.model.favorite } }
    static func groups(_ entries: [AgentXModelBrowserEntry]) -> [AgentXModelBrowserGroup] {
        Dictionary(grouping: entries, by: \.providerID).sorted {
            let left = $0.value[0].providerName
            let right = $1.value[0].providerName
            let order = left.localizedStandardCompare(right)
            return order == .orderedSame ? $0.key < $1.key : order == .orderedAscending
        }.map { id, entries in
            .init(id: id, name: entries[0].providerName, vendors: Dictionary(grouping: entries, by: \.vendor).sorted { $0.key < $1.key }.map { .init(id: $0.key, entries: $0.value) })
        }
    }
}

extension AgentXModelSelection {
    mutating func enableAndSetDefault(_ id: String, category: AgentXModelCategory) throws {
        guard let model = models.first(where: { $0.id == id }), model.available,
              category != .chat || model.supportsTextOutput else { throw AgentXCatalogError.invalidSelection }
        var next = self
        try next.setEnabled(id, enabled: true)
        try next.setDefault(id, category: category)
        self = next
    }
}
