import SwiftUI

@MainActor struct AgentXConfigurationSummaryView: View {
    @ObservedObject var controller: AgentXController
    let instance: AgentXInstance
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let pilot = controller.pilot, pilot.appID == instance.appID {
                if let binding = pilot.pi, binding.instanceID == instance.id {
                    Text("Pi 服务绑定 · " + binding.providerID + " / " + binding.model).font(.caption)
                } else {
                    Text("当前成员尚未绑定到本机 Pi 服务。").font(.caption).foregroundStyle(.orange)
                }
            } else if let configuration = try? controller.effectiveConfiguration(instanceID: instance.id) {
                AgentXConfigurationDetails(configuration: configuration, title: "下次请求")
            } else { Text("下次请求配置不可用，请检查成员、模型和发布版本。").font(.caption).foregroundStyle(.orange) }
            if let definition = controller.state.definitions.first(where: { $0.id == instance.definitionID }), let draft = definition.draft, draft != (try? definition.publishedDocument()) {
                Text("有未发布草稿；下次请求仍使用发布版本。").font(.caption).foregroundStyle(.secondary)
            }
            if instance.conversationModel != nil {
                Button("恢复发布绑定") {
                    do { try controller.clearConversationModel(instanceID: instance.id) }
                    catch { controller.errorMessage = error.localizedDescription }
                }.font(.caption).disabled(controller.isInstanceBusy(instance.id))
            }
        }.accessibilityElement(children: .contain)
    }
}

struct AgentXPilotRunIdentity: View {
    let run: AgentXRun
    var body: some View {
        if let revision = run.revision {
            Text("运行 ID \(run.id) · 修订 \(revision)").textSelection(.enabled).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct AgentXRunConfigurationLabel: View {
    let run: AgentXRun
    var body: some View {
        AgentXPilotRunIdentity(run: run)
        if run.effectiveConfiguration != nil || run.revision == nil {
            AgentXConfigurationDetails(configuration: run.effectiveConfiguration, title: "本次运行配置")
        }
    }
}

struct AgentXConfigurationDetails: View {
    let configuration: AgentXEffectiveConfiguration?
    let title: String
    var body: some View {
        if let configuration {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 4) {
                    Text("应用：\(configuration.appID)")
                    Text("成员：\(configuration.instanceID)")
                    Text("服务：\(configuration.providerID)")
                    Text("模型：\(configuration.model)")
                    Text("来源：" + (configuration.modelSource == .session ? "会话选择" : "发布绑定"))
                    Text("定义：\(configuration.definitionID) · " + (configuration.definitionRevision.map { "v\($0)" } ?? "未发布") + (configuration.definitionPinned ? "（固定版本）" : "（跟随发布）"))
                    Text(configuration.appRevision.map { "应用配置：v\($0)" } ?? "应用配置：未发布")
                }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            } label: { Text(title + "：" + configuration.summary) }
                .font(.caption)
        } else {
            Text("历史记录未保存配置快照").font(.caption).foregroundStyle(.secondary)
        }
    }
}
