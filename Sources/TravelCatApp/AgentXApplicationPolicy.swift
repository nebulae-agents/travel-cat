import Foundation

/// Declarative manifest data; preserved as data, never evaluated as host instructions.
indirect enum AgentXManifestValue: Codable, Equatable {
    case string(String), bool(Bool), integer(Int64), unsignedInteger(UInt64), number(Double), array([Self]), object([String: Self]), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(Int64.self) { self = .integer(value) }
        else if let value = try? c.decode(UInt64.self) { self = .unsignedInteger(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode([Self].self) { self = .array(value) }
        else { self = .object(try c.decode([String: Self].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .unsignedInteger(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}

enum AgentXApplicationPolicy {
    static func isEnabled(_ id: String, in state: AgentXState) -> Bool {
        state.apps.contains { $0.id == id && $0.enabled }
    }
    static func requireEnabled(_ id: String, in state: AgentXState) throws {
        guard isEnabled(id, in: state) else { throw AgentXError.invalid("应用已停用或不存在，未启动新任务。") }
    }
    static func selection(preferred: String?, in state: AgentXState) -> String? {
        if let single = state.singleAppID { return isEnabled(single, in: state) ? single : nil }
        if let preferred, isEnabled(preferred, in: state) { return preferred }
        return state.apps.first(where: \.enabled)?.id
    }
}

enum AgentXApplicationStopState: Equatable {
    case stopping, stopped, unverified(String)
}

extension AgentXManifestValue {
    var string: String? { if case .string(let value) = self { return value }; return nil }
    var object: [String: Self]? { if case .object(let value) = self { return value }; return nil }
    var strings: [String]? {
        guard case .array(let values) = self else { return nil }
        let strings = values.compactMap(\.string)
        return strings.count == values.count ? strings : nil
    }
}

extension AgentXApplication {
    func validateManifest() throws {
        func invalid() -> AgentXError { .invalid("应用清单字段类型或长度无效。") }
        func text(_ value: AgentXManifestValue?) throws {
            guard let value else { return }
            guard let s = value.string, !s.isEmpty, s.utf8.count <= 4096 else { throw invalid() }
        }
        func list(_ value: AgentXManifestValue?) throws {
            guard let value else { return }
            guard let values = value.strings, values.count <= 100 else { throw invalid() }
            for v in values { try text(.string(v)) }
        }
        func section(_ name: String) throws -> [String: AgentXManifestValue] {
            guard let value = manifest?[name] else { return [:] }
            guard let object = value.object else { throw invalid() }
            return object
        }
        try text(runtime.map(AgentXManifestValue.string))
        try list(modules.map { .array($0.map(AgentXManifestValue.string)) })
        if let version {
            switch version {
            case .string: try text(version)
            case .integer(let n): guard n >= 0 else { throw invalid() }
            case .unsignedInteger: break
            case .number(let n): guard n.isFinite, n >= 0, n.rounded() == n else { throw invalid() }
            default: throw invalid()
            }
        }
        try text(manifest?["author"]); try text(manifest?["source"])
        let requires = try section("requires")
        try text(requires["runtime"]); try list(requires["providers"])
        let permissions = try section("permissions")
        for key in ["files", "network", "secrets"] { try list(permissions[key]) }
        for path in permissions["files"]?.strings ?? [] {
            guard !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("\\"), !path.contains(":"),
                  !path.split(separator: "/").contains("..") else { throw invalid() }
        }
        for key in ["shell", "schedule"] {
            if let value = permissions[key], case .bool = value {} else if permissions[key] != nil { throw invalid() }
        }
        let ui = try section("ui")
        try list(ui["modules"]); try text(ui["icon"])
    }
}
