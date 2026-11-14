import SwiftUI

@MainActor
struct AgentXAppCreationView: View {
    @ObservedObject var controller: AgentXController
    @ObservedObject var model: AgentXAppManagementModel
    @State private var modelMember: String?
    @State private var editingProvider: AgentXProvider?
    @State private var addingProvider = false
    private var title: String {
        switch model.creationStep {
        case .source: "来源"
        case .identity: "应用名称与 ID"
        case .members: "成员与模型"
        case .requirements: "依赖与权限"
        case .preview: "安装前确认"
        case .installed: "安装完成"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("创建应用 · " + title).font(.title2.bold()); Spacer(); Button("关闭") { model.close() }.disabled(model.busy) }
            if let failure = model.failure { Text(failure).foregroundStyle(.orange).textSelection(.enabled) }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) { content }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                if model.creationStep != .source { Button("上一步") { model.retreatCreation() }.disabled(installed) }
                Spacer()
                if installed {
                    Button(installedEnabled ? "关闭" : "保持停用") { model.close() }
                    Button(installedEnabled ? "进入应用" : "启用并进入") { Task { await model.enableInstalledApplication() } }.buttonStyle(.borderedProminent)
                } else if model.creationStep == .preview {
                    Button("重新预览") { model.preparePreview() }
                    Button("确认安装（保持停用）") { model.install() }.buttonStyle(.borderedProminent).disabled(model.preview?.canInstall != true)
                } else {
                    Button("下一步") { model.advanceCreation() }.buttonStyle(.borderedProminent)
                }
            }.disabled(model.busy)
        }.padding(20)
        .sheet(isPresented: $model.repairingServices, onDismiss: { model.endServiceRepair() }) { serviceRepair }
        .sheet(isPresented: Binding(get: { modelMember != nil }, set: { if !$0 { modelMember = nil } })) {
            VStack {
                AgentXModelBrowser(providers: controller.state.providers, selected: selectedModel,
                    choose: { item in
                        if let id = modelMember, id != "template" { model.memberModels[id] = item.choice }
                        else { model.selection = item.choice }
                        modelMember = nil
                    }, favorite: { try controller.setModelFavorite(providerID: $0.providerID, modelID: $0.model.id, favorite: !$0.model.favorite) })
                Button("返回") { modelMember = nil }
            }.padding().frame(width: 600, height: 430)
        }
    }
    private var installedEnabled: Bool {
        guard case .installed(let id) = model.creationStep else { return false }
        return controller.state.apps.first(where: { $0.id == id })?.enabled == true
    }
    private var installed: Bool { if case .installed = model.creationStep { return true }; return false }
    private var selectedModel: AgentXConversationModel? {
        guard let id = modelMember, id != "template" else { return model.selection }
        return model.memberModels[id] ?? model.inspectedMembers.first(where: { $0.id == id }).map { .init(providerID: $0.providerID, model: $0.model) }
    }
    @ViewBuilder private var content: some View {
        switch model.creationStep {
        case .source:
            switch model.source {
            case .template(let template): Text("本地模板：" + template.title); Text(template.detail)
            case .directory(let url), .zip(let url): Text("来源：" + url.path).textSelection(.enabled)
            case nil: Text("请从应用管理选择模板或导入包。")
            }
            Text("仅安装配置，不执行包内代码。安装后默认停用。")
        case .identity:
            TextField("应用名称（导入留空保留原名称）", text: $model.applicationName).textFieldStyle(.roundedBorder)
            TextField("应用 ID（导入留空保留原 ID）", text: $model.appID).textFieldStyle(.roundedBorder)
            Text("同 ID 应用不会被覆盖。修改 ID 后需重新配置成员并预览。").font(.caption)
        case .members:
            if case .template = model.source {
                Text(model.selection.map { "模型：\($0.providerID) / \($0.model)" } ?? "请选择已启用的文本模型")
                Button("选择模型") { modelMember = "template" }
                if !model.inspectedMembers.isEmpty { memberEditors }
                Button("载入模板成员") { model.preparePreview() }
                Text("成员单独选择的模型优先于模板默认模型；更换模板默认模型会清除成员编辑，请重新预览。").font(.caption).foregroundStyle(.secondary)
            } else {
                Button("读取成员配置") { model.inspectImportedMembers() }
                memberEditors
            }
            Button("配置模型服务…") { model.beginServiceRepair() }
            Text("检查目录与本地配置不会发起推理，也不代表远端凭据已验证。").font(.caption).foregroundStyle(.secondary)
        case .requirements, .preview:
            if let preview = model.preview {
                Text(preview.application.name).font(.headline)
                Text(preview.includedContent).font(.caption)
                AgentXAppPackageMetadata(app: preview.application, instances: preview.instances)
                ForEach(preview.missingRequirements, id: \.self) { Text($0).foregroundStyle(.orange) }
                DisclosureGroup("提示词与应用设定") {
                    ForEach(preview.definitions) { definition in Text(definition.name).bold(); Text(definition.prompt).textSelection(.enabled) }
                    if let experience = preview.application.experience?.published?.configuration ?? preview.application.experience?.draft {
                        Text(experience.intro); Text(experience.rules)
                    }
                }
            } else { Text("配置已变化，请重新预览。"); Button("重新预览") { model.preparePreview() } }
            Button("修复模型服务…") { model.beginServiceRepair() }
            Text("声明权限不代表操作系统已授权。安装保持停用，不自动发送请求。").font(.caption)
        case .installed(let id):
            Label("已安装：" + id, systemImage: "checkmark.circle")
            Text(installedEnabled ? "应用已启用，未自动发起任务。可重试进入，或关闭后从应用切换器打开。" : "应用当前停用。启用后由你发起首次工作；启用不会自动执行历史任务。")
        }
    }
    private var memberEditors: some View {
        ForEach(model.inspectedMembers) { member in
            VStack(alignment: .leading) {
                TextField("成员名称", text: Binding(get: { model.memberNames[member.id] ?? member.name }, set: { model.memberNames[member.id] = $0 })).textFieldStyle(.roundedBorder)
                Text((model.memberModels[member.id].map { $0.providerID + " / " + $0.model }) ?? (member.providerID + " / " + member.model)).font(.caption)
                Button("更换成员模型") { modelMember = member.id }
            }
        }
    }
    private var serviceRepair: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("配置模型服务").font(.title2.bold())
            Text("返回后保留创建内容，并重新检查依赖。")
            ForEach(controller.state.providers) { provider in
                HStack { Text(provider.name); Spacer(); Button("编辑") { editingProvider = provider } }
            }
            Button("添加模型服务") { addingProvider = true }
            Button("返回创建应用") { model.endServiceRepair() }
        }.padding().frame(width: 620, height: 380)
        .sheet(isPresented: $addingProvider) { AgentXEditorView(controller: controller, kind: .provider) }
        .sheet(item: $editingProvider) { provider in AgentXEditorView(controller: controller, kind: .provider, existingProvider: provider) }
    }
}
