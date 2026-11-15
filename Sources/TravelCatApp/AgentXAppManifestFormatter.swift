import Foundation

/// Human-readable declarations, never an indication of granted host permissions.
/// Translate only known key/scope pairs; keep unknown capabilities visible verbatim.
enum AgentXAppManifestFormatter {
    static func display(_ value: AgentXManifestValue?) -> String {
        guard let value else { return "未声明" }
        if let string = value.string { return string.isEmpty ? "（空字符串）" : string }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "无法显示"
    }
    static func permissions(_ value: AgentXManifestValue?) -> [String] {
        lines(value, labels: [("network", "网络"), ("files", "文件"), ("shell", "Shell"),
                              ("schedule", "定时任务"), ("secrets", "密钥 profile")], empty: "未列出权限") { key, value in
            if ["shell", "schedule"].contains(key), case .bool(let requested) = value {
                return requested ? "请求使用（需另行授权）" : "未要求"
            }
            if ["network", "files", "secrets"].contains(key), case .array(let scopes) = value {
                guard !scopes.isEmpty else { return "未要求" }
                return scopes.map { scope in
                    if key == "files", scope == .string("self") { return "仅本应用目录" }
                    if key == "network", scope == .string("configured-provider") { return "已配置的模型服务" }
                    return display(scope)
                }.joined(separator: "、")
            }
            return display(value)
        }
    }
    static func requirements(_ value: AgentXManifestValue?) -> [String] {
        lines(value, labels: [("runtime", "运行框架"), ("providers", "模型服务"), ("tools", "工具")], empty: "未列出依赖") { key, value in
            if ["providers", "tools"].contains(key), case .array(let items) = value {
                return items.isEmpty ? "未要求" : items.map { display($0) }.joined(separator: "、")
            }
            return display(value)
        }
    }
    private static func lines(_ value: AgentXManifestValue?, labels: [(String, String)], empty: String,
                              format: (String, AgentXManifestValue) -> String) -> [String] {
        guard let value else { return ["未声明"] }
        guard case .object(let fields) = value else { return [display(value)] }
        guard !fields.isEmpty else { return [empty] }
        let known = labels.map(\.0)
        let ordered = labels + fields.keys.filter { !known.contains($0) }.sorted().map { ($0, $0) }
        return ordered.compactMap { key, label in fields[key].map { label + "：" + format(key, $0) } }
    }
}
