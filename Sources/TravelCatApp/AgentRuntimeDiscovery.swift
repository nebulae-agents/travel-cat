import Foundation

/// Read-only observations. A CLI process or an existing container is not a managed session.
struct LocalRuntimeInventory: Decodable, Equatable, Sendable {
    struct Tool: Decodable, Equatable, Sendable {
        let kind: String
        let path: String
        let running: Int
    }
    struct Context: Decodable, Equatable, Sendable, Identifiable {
        let name: String
        let local: Bool
        let available: Bool
        var id: String { name }
    }
    struct Image: Decodable, Equatable, Sendable, Identifiable {
        let context: String
        let ref: String
        var id: String { context + "|" + ref }
        var suggestedPreset: ACPAdapterPreset? {
            let name = ref.lowercased().components(separatedBy: "@sha256:").first ?? ""
            if name.contains("codex") { return .codex }
            if name.contains("claude") { return .claude }
            if name.contains("dsh") || name.contains("deepseek") { return .dsh }
            return nil
        }
    }
    struct Container: Decodable, Equatable, Sendable, Identifiable {
        let context: String
        let id: String
        let name: String
        let image: String
        let state: String
    }
    let tools: [Tool]
    let contexts: [Context]
    let images: [Image]
    let containers: [Container]
    var suggestedImages: [Image] { images.filter { $0.suggestedPreset != nil } }

    static func decode(_ json: [String: Any]) throws -> Self {
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(Self.self, from: data)
    }
}

enum ACPAdapterPreset: String, CaseIterable, Identifiable, Sendable {
    case codex, claude, dsh
    var id: String { rawValue }
    var title: String {
        switch self { case .codex: "Codex ACP"; case .claude: "Claude ACP"; case .dsh: "DSH ACP" }
    }
    var command: [String] {
        switch self {
        case .codex: ["/opt/travelcat-acp/node_modules/.bin/codex-acp"]
        case .claude: ["claude-agent-acp"]
        case .dsh: ["dsh-acp"]
        }
    }
}

struct RuntimeProbeVerification: Equatable, Sendable {
    let probeID: UUID
    let image: LocalRuntimeInventory.Image
    let command: [String]
    func matches(image: LocalRuntimeInventory.Image, command: [String]) -> Bool {
        self.image == image && self.command == command
    }
}

struct QuickCreateDraft {
    var image: LocalRuntimeInventory.Image
    var command: [String]
    var verification: RuntimeProbeVerification
    var name = ""
    var provider = WorkbenchProvider()
    var newKey = ""

    init(verification: RuntimeProbeVerification) {
        self.verification = verification
        image = verification.image
        command = verification.command
        if verification.command == ACPAdapterPreset.claude.command {
            provider.api = .messages
            provider.baseURL = "https://api.anthropic.com"
        } else if verification.command == ACPAdapterPreset.dsh.command {
            provider.api = .chatCompletions
        }
    }

    func validatedInstance() throws -> WorkbenchInstance {
        guard verification.matches(image: image, command: command) else {
            throw WorkbenchFailure("镜像、Docker 环境或启动命令已变化，请重新检查兼容性。")
        }
        guard !newKey.isEmpty else { throw WorkbenchFailure("请提供模型服务 API Key。") }
        var instance = WorkbenchInstance(name: name, image: image.ref, command: command)
        instance.dockerContext = image.context
        instance.provider = provider
        try instance.validate()
        try instance.provider.validate()
        return instance
    }
}
