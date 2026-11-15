import Foundation

struct AgentXEffectiveConfiguration: Codable, Equatable {
    enum ModelSource: String, Codable { case session, publishedBinding }
    var appID: String
    var instanceID: String
    var providerID: String
    var model: String
    var modelSource: ModelSource
    var definitionID: String
    var definitionRevision: Int?
    var definitionPinned: Bool
    var appRevision: Int?
    var summary: String {
        let version = definitionRevision.map { "定义 v\($0)" } ?? "定义未发布"
        return "\(model) · \(modelSource == .session ? "来自会话选择" : "来自发布绑定") · \(version)\(definitionPinned ? "（固定）" : "")"
    }
}
struct AgentXDefinitionImpact: Equatable, Identifiable {
    var id: String
    var appName: String
    var memberName: String
    var fixedRevision: Int?
    var label: String { "\(appName) / \(memberName)：" + (fixedRevision.map { "固定 v\($0)，保持不变" } ?? "下次请求使用新版本") }
}

@MainActor extension AgentXController {
    func effectiveConfiguration(instanceID: String, workflow: Bool = false) throws -> AgentXEffectiveConfiguration {
        guard let original = state.instances.first(where: { $0.id == instanceID }),
              let app = state.apps.first(where: { $0.id == original.appID }),
              let definition = state.definitions.first(where: { $0.id == original.definitionID }) else { throw AgentXError.corrupt }
        let member = workflow ? publishedInstance(original) : effectiveInstance(original)
        _ = try definition.publishedDocument(revision: member.definitionRevision)
        guard let provider = state.providers.first(where: { $0.id == member.providerID && $0.enabled }), provider.enabledModels.contains(member.model) else { throw AgentXCatalogError.invalidSelection }
        return .init(appID: app.id, instanceID: member.id, providerID: provider.id, model: member.model,
            modelSource: !workflow && original.conversationModel != nil ? .session : .publishedBinding,
            definitionID: definition.id, definitionRevision: member.definitionRevision ?? definition.publishedRevision ?? (definition.isPublished ? 1 : nil),
            definitionPinned: member.definitionRevision != nil, appRevision: app.experience?.published?.number)
    }
    func definitionPublicationImpact(id: String) throws -> [AgentXDefinitionImpact] {
        guard let definition = state.definitions.first(where: { $0.id == id }) else { throw AgentXError.corrupt }
        return try state.instances.filter { $0.definitionID == id }.map { member in
            guard let app = state.apps.first(where: { $0.id == member.appID }) else { throw AgentXError.invalid("存在无法解析的应用引用，无法确认发布影响。") }
            if let fixed = member.definitionRevision { _ = try definition.publishedDocument(revision: fixed) }
            return .init(id: member.id, appName: app.name, memberName: member.name, fixedRevision: member.definitionRevision)
        }.sorted { $0.id < $1.id }
    }
}
