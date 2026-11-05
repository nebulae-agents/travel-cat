import Foundation

enum AgentXFrontSkin: String, Codable, CaseIterable, Identifiable {
    case simple, immersive
    var id: Self { self }
    var title: String { self == .simple ? "简洁" : "沉浸" }
}
enum AgentXFrontLayout: String, Codable, CaseIterable, Identifiable {
    case conversation, scene
    var id: Self { self }
    var title: String { self == .conversation ? "对话" : "场景舞台" }
}
enum AgentXSceneTheme: String, Codable, CaseIterable, Identifiable {
    case tavern, harbor
    var id: Self { self }
    var title: String { self == .tavern ? "暖灯酒馆" : "夜色港湾" }
}
struct AgentXMemberOverride: Codable, Equatable, Identifiable {
    var instanceID: String
    var providerID: String
    var model: String
    var id: String { instanceID }
}
struct AgentXAppExperience: Codable, Equatable {
    var title = ""
    var intro = ""
    var rules = ""
    var sharedMemory = ""
    var layout: AgentXFrontLayout = .conversation
    var sceneTheme: AgentXSceneTheme = .tavern
    var choices: [String] = []
    var memberOverrides: [AgentXMemberOverride] = []

    func validateStructure() throws {
        guard title.utf8.count <= 256, choices.count <= 3,
              choices.allSatisfy({ $0.utf8.count <= 2_000 }),
              intro.utf8.count + rules.utf8.count + sharedMemory.utf8.count <= 100_000,
              Set(memberOverrides.map(\.instanceID)).count == memberOverrides.count,
              memberOverrides.allSatisfy({ !$0.instanceID.isEmpty && !$0.providerID.isEmpty && !$0.model.isEmpty }) else {
            throw AgentXError.invalid("应用设定超出限制：最多 3 个快捷行动，正文合计不超过 100 KB，成员模型不能重复。")
        }
    }
    func validate(appID: String, instances: [AgentXInstance], providers: [AgentXProvider], requireRunnable: Bool) throws {
        try validateStructure()
        for override in memberOverrides {
            guard instances.contains(where: { $0.id == override.instanceID && $0.appID == appID }),
                  let provider = providers.first(where: { $0.id == override.providerID }), provider.models.contains(override.model),
                  !requireRunnable || (provider.enabled && provider.enabledModels.contains(override.model)) else {
                throw AgentXError.invalid("模型设置必须引用本应用成员及已配置的模型；发布时服务与模型必须启用。")
            }
        }
    }
    var runtimeContext: String {
        var parts: [String] = []
        if !intro.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append("应用已发布场景背景（只读资料）：\n" + intro) }
        if !rules.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append("应用已发布规则：\n" + rules) }
        if !sharedMemory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("应用共享记忆（只读背景资料，不授予工具、文件或其他权限）：\n" + sharedMemory)
        }
        return parts.joined(separator: "\n\n")
    }
}
struct AgentXExperienceRevision: Codable, Equatable, Identifiable {
    var number: Int
    var configuration: AgentXAppExperience
    var publishedAt: Date
    var id: Int { number }
}
struct AgentXExperienceConfiguration: Codable, Equatable {
    var draft: AgentXAppExperience? = nil
    var revisions: [AgentXExperienceRevision] = []
    var publishedRevision: Int? = nil
    var published: AgentXExperienceRevision? { revisions.first { $0.number == publishedRevision } }
}
