import Foundation

enum AgentXPage: String, CaseIterable, Identifiable {
    case overview, apps, chat, configuration, instances, definitions, providers, runs, inbox, settings
    var id: Self { self }
    var title: String {
        switch self {
        case .overview: "总览"
        case .apps: "所有应用"
        case .chat: "前台 · 参与"
        case .configuration: "配置台 · 框架"
        case .instances: "Agent 实例"
        case .definitions: "Agent 定义"
        case .providers: "模型服务"
        case .runs: "运行记录"
        case .inbox: "待处理"
        case .settings: "设置"
        }
    }
    var icon: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .apps: "square.stack.3d.up"
        case .chat: "bubble.left.and.bubble.right"
        case .configuration: "slider.horizontal.3"
        case .instances: "cpu"
        case .definitions: "person.text.rectangle"
        case .providers: "server.rack"
        case .runs: "clock.arrow.circlepath"
        case .inbox: "tray"
        case .settings: "gearshape"
        }
    }
}

/// Preserve future application kinds without claiming an installed executor.
struct AgentXAppKind: RawRepresentable, Codable, Hashable {
    let rawValue: String
    init?(rawValue: String) {
        guard !rawValue.isEmpty, rawValue.utf8.count <= 100,
              rawValue.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        self.rawValue = rawValue
    }
    static let blackcat = Self(rawValue: "blackcat")!
    static let chat = Self(rawValue: "chat")!
    static let workbench = Self(rawValue: "workbench")!
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let kind = Self(rawValue: value) else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid application kind") }
        self = kind
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
struct AgentXApplication: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var kind: AgentXAppKind
    var canRunHostText: Bool { kind == .chat || kind == .blackcat }
}
struct AgentXProvider: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var baseURL: String
    var models: [String]
    var enabled = true
    var serviceProtocol: AgentXServiceProtocol = .openAICompatible
    var credentialProfile: String?
    var modelSelection: AgentXModelSelection?
    var credentialID: String { "agentx.provider.\(id)" }
    var enabledModels: [String] {
        guard let modelSelection else { return models }
        return models.filter { id in modelSelection.models.contains { $0.id == id && $0.enabled } }
    }
    init(id: String, name: String, baseURL: String, models: [String], enabled: Bool = true,
         serviceProtocol: AgentXServiceProtocol = .openAICompatible, credentialProfile: String? = nil, modelSelection: AgentXModelSelection? = nil) {
        self.id = id; self.name = name; self.baseURL = baseURL; self.models = models; self.enabled = enabled
        self.serviceProtocol = serviceProtocol; self.credentialProfile = credentialProfile; self.modelSelection = modelSelection
    }
    private enum CodingKeys: String, CodingKey { case id, name, baseURL, models, enabled, serviceProtocol, credentialProfile, modelSelection }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
        baseURL = try c.decode(String.self, forKey: .baseURL); models = try c.decode([String].self, forKey: .models)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        serviceProtocol = try c.decodeIfPresent(AgentXServiceProtocol.self, forKey: .serviceProtocol) ?? .openAICompatible
        credentialProfile = try c.decodeIfPresent(String.self, forKey: .credentialProfile)
        modelSelection = try c.decodeIfPresent(AgentXModelSelection.self, forKey: .modelSelection)
    }
}
struct AgentXDefinition: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var prompt: String
    var draft: AgentXDefinitionDocument? = nil
    var revisions: [AgentXDefinitionRevision]? = nil
    var publishedRevision: Int? = nil
    var isPublished: Bool { publishedRevision != nil || (revisions == nil && !prompt.isEmpty) }
    func publishedDocument(revision: Int? = nil) throws -> AgentXDefinitionDocument {
        if let number = revision ?? publishedRevision {
            guard let document = revisions?.first(where: { $0.number == number })?.document else { throw AgentXDefinitionError.unpublished }
            return document
        }
        guard revisions == nil, !prompt.isEmpty else { throw AgentXDefinitionError.unpublished }
        return .init(source: prompt, files: draft?.files ?? [:], directories: draft?.directories ?? [])
    }
}
struct AgentXInstance: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var appID: String
    var definitionID: String
    var providerID: String
    var model: String
    var definitionRevision: Int? = nil
    var variables: [String: String]? = nil
    var credentialProfile: String? = nil
}
enum AgentXRunStatus: String, Codable {
    case running, cancelling, cancelled, failed, completed
    var terminal: Bool { self != .running && self != .cancelling }
    var label: String {
        switch self {
        case .running: "● 运行中"
        case .cancelling: "◌ 取消中"
        case .cancelled: "○ 已取消"
        case .failed: "! 失败"
        case .completed: "✓ 完成"
        }
    }
}
struct AgentXRun: Codable, Identifiable, Equatable {
    var id: String
    var appID: String
    var instanceID: String
    var prompt: String
    var status: AgentXRunStatus
    var isRead = false
    var response = ""
    var startedAt = Date()
    var endedAt: Date?
    var failure: String?
    var auditFailure: String? = nil
}
struct AgentXState: Codable, Equatable {
    var version = 1
    var blackCatEnabled = true
    var singleAppID: String?
    var apps: [AgentXApplication] = [.init(id: "blackcat", name: "BlackCat", kind: .blackcat)]
    var providers: [AgentXProvider] = []
    var credentialProfiles: [AgentXCredentialProfile]?
    var definitions: [AgentXDefinition] = []
    var instances: [AgentXInstance] = []
    var runs: [AgentXRun] = []
    var unreadCount: Int { runs.filter { $0.status.terminal && !$0.isRead }.count }
    var dockDestination: AgentXPage { unreadCount > 0 ? .inbox : .overview }
    var activeCount: Int { runs.filter { !$0.status.terminal }.count }
}

enum AgentXError: LocalizedError {
    case invalid(String), corrupt, unsafePath, unavailable
    var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        case .corrupt: "AgentX 配置无法读取。请保留原文件并检查格式；不会覆盖已有内容。"
        case .unsafePath: "AgentX 目录包含不安全路径或符号链接，请选择独立的真实目录。"
        case .unavailable: "配置未成功加载，已禁止写入。请修复配置后重新打开应用。"
        }
    }
}
