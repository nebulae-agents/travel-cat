import SwiftUI

@MainActor
struct AgentXAppConfigurationView: View {
    @ObservedObject var controller: AgentXController
    @State private var notice: String?
    @State private var publishing: AgentXDefinition?
    private var instance: AgentXInstance? { controller.currentInstance }
    private var definition: AgentXDefinition? { controller.state.definitions.first { $0.id == instance?.definitionID } }
    private var proposal: AgentXRun? {
        let runs = controller.state.runs.filter { $0.appID == controller.selectedAppID && $0.instanceID == instance?.id && $0.purpose == .configuration }
        return runs.first { $0.id == controller.selectedConfigurationRunID } ?? runs.last
    }
    private var pending: [AgentXDefinition] {
        let ids = Set(controller.currentInstances.map(\.definitionID))
        return controller.state.definitions.filter { ids.contains($0.id) && $0.draft != nil && $0.draft != (try? $0.publishedDocument()) }
    }
    private var busy: Bool {
        controller.state.runs.contains { $0.instanceID == instance?.id && !$0.status.terminal }
    }
    private var instruction: Binding<String> {
        Binding(get: { controller.configurationInstructions[instance?.id ?? ""] ?? "" },
                set: { controller.configurationInstructions[instance?.id ?? ""] = $0 })
    }

    var body: some View {
        if let app = controller.currentApp {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("让 \(app.name) 更适合你").font(.title2.bold())
                        Text("生成建议 → 逐项审阅 → 保存草稿 → 发布。进行中的对话保持原配置。")
                            .font(.callout).foregroundStyle(AgentXTheme.muted)
                    }
                    Spacer()
                    Button("回到应用", systemImage: "play.fill") { controller.openApp(app.id) }
                        .buttonStyle(.borderedProminent)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 20) {
                        assistant.frame(minWidth: 440)
                        status.frame(width: 290)
                    }
                    VStack(spacing: 20) { assistant; status }
                }
            }
            .confirmationDialog("发布定义到应用？", isPresented: Binding(get: { publishing != nil }, set: { if !$0 { publishing = nil } }), titleVisibility: .visible) {
                if let definition = publishing {
                    Button("发布新版本") { perform { try controller.publishDefinition(id: definition.id); notice = "新版本已发布；正在运行和固定版本的实例保持原配置。" }; publishing = nil }
                    Button("取消", role: .cancel) { publishing = nil }
                }
            } message: {
                if let definition = publishing {
                    Text((try? controller.definitionPublicationImpact(id: definition.id).map(\.label).joined(separator: "\n")) ?? "无法解析发布影响；发布会被阻止。")
                }
            }
            .onChange(of: controller.selectedAppID) { _, _ in notice = nil }
            .onChange(of: controller.selectedInstanceID) { _, _ in notice = nil }
        } else {
            AgentXCard {
                Text("先选择一个应用").font(.headline)
                Button("所有应用") { controller.navigate(to: .apps) }
            }
        }
    }

    private var assistant: some View {
        AgentXCard {
            Label("配置助手", systemImage: "sparkles").font(.title3.bold())
            Text("说说你想调整的角色职责、语气或回答方式。助手生成正文及人物设定建议，由你逐项选择；模型连接与权限保持原配置。")
                .foregroundStyle(AgentXTheme.muted)
            if controller.currentApp?.canRunHostText != true {
                Text("此应用的配置由专用工作台管理。配置助手目前支持原生文本应用。")
                Button("打开成员工作台") { controller.navigate(to: .members) }
            } else if let instance {
                Picker("目标成员", selection: Binding(get: { instance.id }, set: { controller.selectedInstanceID = $0 })) {
                    ForEach(controller.currentInstances) { Text($0.name).tag($0.id) }
                }
                Text("使用 \(instance.model) · 发送当前正文、人物设定和你的修改要求")
                    .font(.caption).foregroundStyle(AgentXTheme.muted)
                TextEditor(text: instruction).font(.body).frame(height: 90)
                    .scrollContentBackground(.hidden).padding(10)
                    .background(AgentXTheme.background, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("配置修改要求")
                HStack {
                    Text("例如：回答更简短，先给结论。")
                        .font(.caption).foregroundStyle(AgentXTheme.muted)
                    Spacer()
                    Button("生成建议", systemImage: "sparkles") {
                        notice = nil
                        controller.sendConfigurationRequest(instruction.wrappedValue, instanceID: instance.id)
                    }.buttonStyle(.borderedProminent)
                        .disabled(!controller.isLoaded || busy || instruction.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let proposal {
                    Divider()
                    HStack {
                        Label("最近一次建议", systemImage: "text.bubble").font(.headline)
                        Spacer()
                        Text(proposal.status.label).font(.caption)
                    }
                    Text(proposal.prompt).font(.callout).foregroundStyle(AgentXTheme.muted).textSelection(.enabled)
                    if !proposal.status.terminal {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("正在生成，应用输入已保留…").font(.caption)
                            Spacer()
                            Button("取消生成") { controller.cancel(proposal.id) }.disabled(proposal.status == .cancelling)
                        }
                    }
                    if let failure = proposal.failure { Text(failure).foregroundStyle(.orange) }
                    if let failure = proposal.auditFailure { Text(failure).foregroundStyle(.orange) }
                    if proposal.status == .completed {
                        proposalReview(proposal)
                    }
                }
            } else {
                Text("先为应用添加一个已配置模型与定义的成员。")
                Button("配置成员") { controller.navigate(to: .members) }.buttonStyle(.borderedProminent)
            }
            if let notice { Text(notice).font(.callout).textSelection(.enabled) }
        }
    }

    @ViewBuilder
    private func proposalReview(_ run: AgentXRun) -> some View {
        if let parsed = try? controller.configurationProposal(run) {
            let chosen = run.configurationAppliedChangeIDs.map(Set.init) ?? controller.configurationSelections[run.id] ?? Set(parsed.changes.map(\.id))
            let stage = controller.configurationProposalStage(run)
            Text(stage == .published ? "建议已发布" : stage == .saved ? "建议已保存为草稿" : "逐项审阅建议")
                .font(.caption.bold()).foregroundStyle(AgentXTheme.accent)
            Text(parsed.summary).font(.callout).textSelection(.enabled)
            ForEach(parsed.changes) { change in
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(change.title, isOn: Binding(get: { (run.configurationAppliedChangeIDs.map(Set.init) ?? controller.configurationSelections[run.id] ?? Set(parsed.changes.map(\.id))).contains(change.id) }, set: { checked in
                        var selection = run.configurationAppliedChangeIDs.map(Set.init) ?? controller.configurationSelections[run.id] ?? Set(parsed.changes.map(\.id))
                        if checked { selection.insert(change.id) } else { selection.remove(change.id) }
                        controller.configurationSelections[run.id] = selection
                    })).disabled(stage != .review)
                    DisclosureGroup("当前值") {
                        Text(currentValue(change.dimension)).font(.callout).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("建议值").font(.caption.bold()).foregroundStyle(AgentXTheme.accent)
                    Text(change.value.isEmpty ? "（清空此设定）" : change.value).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("理由：\(change.reason)").font(.caption).foregroundStyle(AgentXTheme.muted).textSelection(.enabled)
                }.padding(12).background(AgentXTheme.background, in: RoundedRectangle(cornerRadius: 8))
            }
            Button("将选中的 \(chosen.count) 项保存为草稿", systemImage: "doc.badge.plus") {
                perform {
                    try controller.applyConfigurationProposal(runID: run.id, selectedChangeIDs: chosen)
                    notice = "已将选中建议保存为草稿。发布后才影响后续请求。"
                }
            }.disabled(stage != .review || chosen.isEmpty)
            Text("仅采用勾选项，保留文件头与其他内容。人物中的模型与预算仅为设定文本，不修改模型连接、权限或实际预算。若定义已更新，将拒绝覆盖。")
                .font(.caption).foregroundStyle(AgentXTheme.muted)
        } else {
            Text("建议格式无法识别，未保存任何改动。请重新生成建议。").foregroundStyle(.orange)
            DisclosureGroup("查看原始建议") { Text(run.response).textSelection(.enabled) }
        }
    }

    private func currentValue(_ dimension: String) -> String {
        guard let definition, let document = try? (definition.draft ?? definition.publishedDocument()) else { return "暂无配置" }
        if dimension == "body" { return (try? document.bodyText()) ?? "无法读取正文" }
        guard let field = AgentXCharacterDimension(rawValue: dimension), let profile = try? AgentXCharacterProfile.load(from: document) else { return "无法读取人物设定" }
        let value = profile.text(for: field)
        return value.isEmpty ? "（未设置）" : value
    }

    private var status: some View {
        VStack(spacing: 16) {
            AgentXCard {
                Label("应用现状", systemImage: "rectangle.on.rectangle").font(.headline)
                Text("\(controller.currentInstances.count) 个成员")
                let runs = controller.state.runs.filter { $0.appID == controller.selectedAppID }
                Text("\(runs.filter { !$0.status.terminal }.count) 个运行中 · \(runs.filter { $0.status.terminal && !$0.isRead }.count) 个待查看")
                    .font(.caption).foregroundStyle(AgentXTheme.muted)
                Button("运行记录") { controller.navigate(to: .runs) }
            }
            AgentXCard {
                Label("待发布草稿 · \(pending.count)", systemImage: "doc.text").font(.headline)
                if pending.isEmpty {
                    Text("没有待发布的定义改动。").foregroundStyle(AgentXTheme.muted)
                }
                ForEach(pending) { definition in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(definition.name).font(.headline)
                        Text("当前 v\(definition.publishedRevision ?? (definition.isPublished ? 1 : 0)) → 新版本")
                            .font(.caption).foregroundStyle(AgentXTheme.muted)
                        Text("引用应用：\(referencingApps(definition.id))").font(.caption)
                        DisclosureGroup("查看完整草稿") {
                            Text(definition.draft?.source ?? "").font(.caption.monospaced()).textSelection(.enabled)
                        }
                        Button("发布此定义") { publishing = definition }.buttonStyle(.borderedProminent)
                    }
                }
                Button("编辑定义与历史版本") { controller.navigate(to: .definitions) }
            }
            AgentXCard {
                Label("应用配置", systemImage: "slider.horizontal.3").font(.headline)
                Button("成员与实例") { controller.navigate(to: .members) }
                Button("模型服务") { controller.navigate(to: .providers) }
                Button("应用版本与备份") { controller.navigate(to: .backups) }
                Text("固定版本的成员不会自动跟随发布；可在实例设置中调整。").font(.caption).foregroundStyle(AgentXTheme.muted)
            }
        }
    }
    private func referencingApps(_ definitionID: String) -> String {
        let ids = Set(controller.state.instances.filter { $0.definitionID == definitionID }.map(\.appID))
        return controller.state.apps.filter { ids.contains($0.id) }.map(\.name).joined(separator: "、")
    }
    private func perform(_ operation: () throws -> Void) {
        do { try operation() } catch { notice = error.localizedDescription }
    }
}
