import Foundation

enum AgentXPage: String, CaseIterable, Identifiable {
    case overview, platformOverview, module, apps, chat, configuration, characters, workflows, members, sceneRules, appModels, appFiles, appSettings, backups, governance, instances, definitions, providers, runs, inbox, settings
    var id: Self { self }
    var isBackstage: Bool {
        [.configuration, .members, .workflows, .characters, .sceneRules, .appModels, .runs, .appFiles, .appSettings].contains(self)
    }
    var title: String {
        switch self {
        case .overview: "应用总览"
        case .platformOverview: "全平台总览"
        case .module: "前台模块"
        case .apps: "所有应用"
        case .chat: "前台 · 参与"
        case .configuration: "后台 · 生成与优化"
        case .characters: "人物定制"
        case .workflows: "工作流"
        case .members: "成员与工作流"
        case .sceneRules: "场景与规则"
        case .appModels: "模型与限额"
        case .appFiles: "目录与制品"
        case .appSettings: "应用设置"
        case .backups: "备份与迁移"
        case .governance: "预算与审计"
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
        case .overview, .platformOverview: "square.grid.2x2"
        case .module: "rectangle.3.group"
        case .apps: "square.stack.3d.up"
        case .chat: "bubble.left.and.bubble.right"
        case .configuration: "slider.horizontal.3"
        case .characters: "person.crop.rectangle"
        case .workflows: "point.3.connected.trianglepath.dotted"
        case .members: "person.2"
        case .sceneRules: "theatermasks"
        case .appModels: "slider.horizontal.3"
        case .appFiles: "folder"
        case .appSettings: "gearshape.2"
        case .backups: "externaldrive"
        case .governance: "checkmark.shield"
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
    var workflow: AgentXWorkflowConfiguration? = nil
    var experience: AgentXExperienceConfiguration? = nil
    var enabled: Bool = true
    var runtime: String? = nil
    var modules: [String]? = nil
    var version: AgentXManifestValue? = nil
    var manifest: [String: AgentXManifestValue]? = nil
    var manifestAuthor: String? { manifest?["author"]?.string }
    var manifestSource: String? { manifest?["source"]?.string }
    var requiredRuntime: String? { manifest?["requires"]?.object?["runtime"]?.string ?? runtime }
    var requiredProviders: [String] { manifest?["requires"]?.object?["providers"]?.strings ?? [] }
    var declaredPermissions: [String: AgentXManifestValue] { manifest?["permissions"]?.object ?? [:] }
    var declaredModules: [String] { modules ?? manifest?["ui"]?.object?["modules"]?.strings ?? [] }
    var declaredIcon: String? { manifest?["ui"]?.object?["icon"]?.string }
    var canRunHostText: Bool { kind == .chat || kind == .blackcat }
    private enum CodingKeys: String, CodingKey {
        case id, name, kind, workflow, experience, enabled, runtime, modules, version, manifest
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(AgentXAppKind.self, forKey: .kind)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        workflow = try c.decodeIfPresent(AgentXWorkflowConfiguration.self, forKey: .workflow)
        experience = try c.decodeIfPresent(AgentXExperienceConfiguration.self, forKey: .experience)
        runtime = try c.decodeIfPresent(String.self, forKey: .runtime)
        modules = try c.decodeIfPresent([String].self, forKey: .modules)
        version = try c.decodeIfPresent(AgentXManifestValue.self, forKey: .version)
        manifest = try c.decodeIfPresent([String: AgentXManifestValue].self, forKey: .manifest)
        try validateManifest()

    }
    init(id: String, name: String, kind: AgentXAppKind, workflow: AgentXWorkflowConfiguration? = nil,
         experience: AgentXExperienceConfiguration? = nil, enabled: Bool = true) {
        self.id = id; self.name = name; self.kind = kind; self.workflow = workflow
        self.experience = experience; self.enabled = enabled
    }
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
    var catalogRefreshedAt: Date?
    var isOpenRouter: Bool { serviceProtocol == .openAICompatible && AgentXProviderCatalog.isOpenRouter(baseURL: baseURL) }
    var credentialID: String { "agentx.provider.\(id)" }
    var enabledModels: [String] {
        guard let modelSelection else { return models }
        return models.filter { id in modelSelection.models.contains { $0.id == id && $0.enabled && $0.available && $0.supportsTextOutput } }
    }
    init(id: String, name: String, baseURL: String, models: [String], enabled: Bool = true,
         serviceProtocol: AgentXServiceProtocol = .openAICompatible, credentialProfile: String? = nil, modelSelection: AgentXModelSelection? = nil, catalogRefreshedAt: Date? = nil) {
        self.id = id; self.name = name; self.baseURL = baseURL; self.models = models; self.enabled = enabled
        self.serviceProtocol = serviceProtocol; self.credentialProfile = credentialProfile; self.modelSelection = modelSelection
        self.catalogRefreshedAt = catalogRefreshedAt
    }
    private enum CodingKeys: String, CodingKey { case id, name, baseURL, models, enabled, serviceProtocol, credentialProfile, modelSelection, catalogRefreshedAt }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
        baseURL = try c.decode(String.self, forKey: .baseURL); models = try c.decode([String].self, forKey: .models)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        serviceProtocol = try c.decodeIfPresent(AgentXServiceProtocol.self, forKey: .serviceProtocol) ?? .openAICompatible
        credentialProfile = try c.decodeIfPresent(String.self, forKey: .credentialProfile)
        modelSelection = try c.decodeIfPresent(AgentXModelSelection.self, forKey: .modelSelection)
        catalogRefreshedAt = try c.decodeIfPresent(Date.self, forKey: .catalogRefreshedAt)
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
struct AgentXConversationModel: Codable, Equatable, Hashable {
    var providerID: String
    var model: String
}
struct AgentXInstance: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var appID: String
    var definitionID: String
    var providerID: String
    var model: String
    var conversationModel: AgentXConversationModel? = nil
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
enum AgentXProposalStage { case review, saved, published }

enum AgentXRunPurpose: String, Codable { case configuration, characterPreview, workflow, usageAssistant }

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
    var actualProviderID: String? = nil
    var actualModel: String? = nil
    var runtimeCore: String? = nil
    var effectiveConfiguration: AgentXEffectiveConfiguration? = nil
    var purpose: AgentXRunPurpose? = nil
    var configurationDefinitionID: String? = nil
    var configurationBaseDigest: String? = nil
    var configurationAppliedDigest: String? = nil
    var configurationAppliedChangeIDs: [String]? = nil
    var workflowRevision: Int? = nil
    var workflowInstanceIDs: [String]? = nil
    var workflowSteps: [AgentXWorkflowStepResult]? = nil
    var revision: Int? = nil
    var stopEvidence: String? = nil
    var requiresProcessReview: Bool? = nil
    var pilotCreateKey: String? = nil

    var displayedStatus: String {
        switch stopEvidence {
        case "pending": "已请求停止 · 等待 Pi 退出"
        case "confirmedExited": status.label + " · Pi 已确认退出"
        case "unverified": status.label + " · Pi 退出未确认"
        default: status.label
        }
    }
}
struct AgentXState: Codable, Equatable {
    var version = 1
    var blackCatEnabled = true
    var frontSkin: AgentXFrontSkin? = nil
    var currentAppID: String?
    var singleAppID: String?
    var apps: [AgentXApplication] = [.init(id: "blackcat", name: "BlackCat", kind: .blackcat)]
    var providers: [AgentXProvider] = []
    var credentialProfiles: [AgentXCredentialProfile]?
    var definitions: [AgentXDefinition] = []
    var instances: [AgentXInstance] = []
    var runs: [AgentXRun] = []
    var unreadCount: Int { runs.filter { $0.status.terminal && !$0.isRead && AgentXApplicationPolicy.isEnabled($0.appID, in: self) }.count }
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
