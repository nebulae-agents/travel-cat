import SwiftUI

@MainActor
struct AgentXSettingsAssistantEntry: View {
    @ObservedObject var controller: AgentXController
    private var member: AgentXInstance? { controller.currentInstance }
    private var input: Binding<String> {
        Binding(get: { controller.configurationInstructions[member?.id ?? ""] ?? "" },
                set: { controller.configurationInstructions[member?.id ?? ""] = $0 })
    }
    var body: some View {
        HStack(spacing: 8) {
            TextField("用一句话说你想改什么", text: input).textFieldStyle(.plain)
                .accessibilityLabel("用一句话修改设置").frame(minHeight: 44)
            Button("生成修改") {
                guard let member else { return }
                controller.sendConfigurationRequest(input.wrappedValue, instanceID: member.id)
                controller.navigate(to: .configuration)
            }.frame(minHeight: 44)
                .disabled(!controller.isLoaded || member == nil || controller.currentApp?.canRunHostText != true || controller.isInstanceBusy(member?.id ?? "") || input.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }.padding(.horizontal, 14).padding(.vertical, 6)
            .background(AgentXTheme.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(AgentXTheme.border))
    }
}

/// Reuses the existing per-definition and experience publication boundaries.
@MainActor
struct AgentXSettingsDraftActions: View {
    @ObservedObject var controller: AgentXController
    @State private var reviewing = false
    private var appID: String { controller.selectedAppID }
    private var experience: AgentXAppExperience? {
        if let bytes = controller.experienceEditorDrafts[appID], let edit = try? JSONDecoder().decode(AgentXExperienceEditSession.self, from: bytes) { return edit.configuration }
        return controller.currentApp?.experience?.draft
    }
    private var changedExperience: Bool { experience != nil && experience != controller.currentApp?.experience?.published?.configuration }
    private var definitions: [AgentXDefinition] {
        let ids = Set(controller.currentInstances.map(\.definitionID))
        return controller.state.definitions.filter { ids.contains($0.id) && $0.draft != nil && $0.draft != (try? $0.publishedDocument()) }
    }
    private var count: Int { definitions.count + (changedExperience ? 1 : 0) }
    var body: some View {
        if count > 0 {
            Text("\(count) 处修改尚未发布").font(.caption).foregroundStyle(AgentXTheme.accent)
            Button("查看差异") { reviewing = true }.frame(minHeight: 44)
            Button("发布") { reviewing = true }.buttonStyle(.borderedProminent).frame(minHeight: 44)
                .help("审阅差异并确认发布；只影响后续运行")
                .sheet(isPresented: $reviewing) {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack { Text("审阅并发布").font(.title2); Spacer(); Button { reviewing = false } label: { Text("关闭").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()) }.keyboardShortcut(.cancelAction) }
                        Text("只影响后续运行；正在进行的对话和固定版本的成员保持原配置。")
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                if changedExperience, let experience {
                                    Text("应用设置").font(.headline)
                                    Text("已发布").font(.caption)
                                    Text(encoded(controller.currentApp?.experience?.published?.configuration)).textSelection(.enabled)
                                    Text("草稿").font(.caption)
                                    Text(encoded(experience)).textSelection(.enabled)
                                    Button("确认发布应用设置") { publishExperience() }.frame(minHeight: 44)
                                        .disabled(controller.experienceEditorDrafts[appID] != nil)
                                }
                                ForEach(definitions) { definition in
                                    Text(definition.name).font(.headline)
                                    Text("已发布").font(.caption)
                                    Text((try? definition.publishedDocument().source) ?? "尚未发布").textSelection(.enabled)
                                    Text("草稿").font(.caption)
                                    Text(definition.draft?.source ?? "").textSelection(.enabled)
                                    Text((try? controller.definitionPublicationImpact(id: definition.id).map(\.label).joined(separator: "\n")) ?? "无法解析发布影响；发布会被阻止。")
                                    Button("确认发布 \(definition.name)") {
                                        do { try controller.publishDefinition(id: definition.id) }
                                        catch { controller.errorMessage = error.localizedDescription }
                                    }.frame(minHeight: 44)
                                }
                            }
                        }
                        if let error = controller.errorMessage { Text(error).foregroundStyle(.orange) }
                    }.padding(24).frame(width: 680, height: 600)
                }
        }
    }
    private func encoded(_ value: AgentXAppExperience?) -> String {
        guard let value else { return "尚未发布" }
        let members = value.memberOverrides.map { override in
            (controller.state.instances.first { $0.id == override.instanceID }?.name ?? "成员") + "：" + override.model
        }.joined(separator: "、")
        return ["标题：" + value.title, "场景：" + value.intro, "规则：" + value.rules,
                "共享记忆：" + value.sharedMemory, "布局：" + value.layout.title,
                "主题：" + value.sceneTheme.title, "行动：" + value.choices.joined(separator: "；"),
                "成员模型：" + (members.isEmpty ? "使用成员默认模型" : members)].joined(separator: "\n\n")
    }
    private func publishExperience() {
        do {
            try controller.publishExperience(appID: appID)
        } catch { controller.errorMessage = error.localizedDescription }
    }
}
