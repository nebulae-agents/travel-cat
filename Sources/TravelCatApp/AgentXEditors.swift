import SwiftUI
import AppKit

@MainActor
struct AgentXEditorView: View {
    @ObservedObject var controller: AgentXController
    let kind: AgentXEditor
    var existingProvider: AgentXProvider? = nil
    var existingDefinition: AgentXDefinition? = nil
    var existingInstance: AgentXInstance? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var models = ""
    @State private var secret = ""
    @State private var serviceProtocol: AgentXServiceProtocol = .openAICompatible
    @State private var credentialProfile = ""
    @State private var newProfileName = ""
    @State private var newProfileKeys = ""
    @State private var selection = AgentXModelSelection(models: [])
    @State private var discovering = false
    @State private var discoveryMessage: String?
    @State private var prompt = ""
    @State private var definitionFiles: [String: String] = [:]
    @State private var definitionDirectories: [String] = []
    @State private var fileMode = false
    @State private var selectedFile = "agent.md"
    @State private var savedDefinitionID: String?
    @State private var historyRevision = 0
    @State private var pinnedRevision = 0
    @State private var variableText = ""
    @State private var appID = ""
    @State private var definitionID = ""
    @State private var providerID = ""
    @State private var model = ""
    @State private var error: String?

    private var title: String {
        switch kind { case .app: "新建应用"; case .provider: "添加模型服务"; case .definition: "创建 Agent 定义"; case .instance: "创建 Agent 实例" }
    }
    private var selectedProvider: AgentXProvider? { controller.state.providers.first { $0.id == providerID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(existingProvider != nil ? "编辑模型服务" : existingDefinition != nil ? "编辑 Agent 定义" : existingInstance != nil ? "编辑 Agent 实例" : title).font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    field("名称", value: $name)
                    switch kind {
                    case .app:
                        Label("原生对话应用", systemImage: "bubble.left.and.bubble.right").foregroundStyle(AgentXTheme.accent)
                        Text("创建后添加成员实例。运行框架适配尚未接入，当前使用宿主文本模型连接。").foregroundStyle(AgentXTheme.muted)
                    case .provider:
                        providerFields
                    case .definition:
                        definitionFields
                    case .instance:
                        Picker("所属应用", selection: $appID) { ForEach(controller.state.apps) { Text($0.name).tag($0.id) } }.disabled(existingInstance != nil)
                        Picker("来源定义", selection: $definitionID) {
                            Text("请选择").tag("")
                            ForEach(controller.state.definitions.filter(\.isPublished)) { Text($0.name).tag($0.id) }
                        }
                        Picker("定义版本", selection: $pinnedRevision) {
                            Text("跟随最新发布").tag(0)
                            ForEach(controller.state.definitions.first { $0.id == definitionID }?.revisions ?? [], id: \.number) { Text("版本 \($0.number)").tag($0.number) }
                        }
                        .onChange(of: definitionID) { old, new in
                            if old.isEmpty, existingInstance?.definitionID == new { return }
                            pinnedRevision = 0
                        }
                        Picker("模型服务", selection: $providerID) {
                            Text("请选择").tag("")
                            ForEach(controller.state.providers.filter(\.enabled)) { Text($0.name).tag($0.id) }
                        }.onChange(of: providerID) { old, new in
                            if old.isEmpty, existingInstance?.providerID == new { return }
                            model = selectedProvider?.modelSelection?.defaultModel(for: .chat) ?? selectedProvider?.enabledModels.first ?? ""
                        }
                        Picker("模型", selection: $model) {
                            Text("请选择").tag("")
                            ForEach(selectedProvider?.enabledModels ?? [], id: \.self) { Text($0).tag($0) }
                        }
                        if controller.state.definitions.isEmpty || controller.state.providers.filter(\.enabled).isEmpty {
                            Text("需要先创建 Agent 定义和启用的模型服务。").foregroundStyle(.orange)
                        }
                        Picker("实例凭据覆盖", selection: $credentialProfile) {
                            Text("使用模型服务凭据").tag("")
                            ForEach(controller.state.credentialProfiles ?? []) { Text($0.name).tag($0.name) }
                        }
                        Text("变量（每行 名称=值）").font(.headline)
                        TextEditor(text: $variableText).frame(height: 100).border(AgentXTheme.border).accessibilityLabel("实例变量")
                        Text("变量替换发布提示词中的 {{名称}}。实例保留在原应用，运行中不可修改绑定。").font(.caption).foregroundStyle(AgentXTheme.muted)
                    }
                    if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                }.padding(2)
            }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if kind == .definition {
                    Button("发布新版本") { save(publish: true) }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !controller.isLoaded)
                }
                Button(kind == .definition ? "保存草稿" : "保存") { save() }.buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !controller.isLoaded || discovering)
            }
        }.padding(28).frame(width: 560, height: kind == .app ? 500 : 720)
            .background(AgentXTheme.background).preferredColorScheme(.dark).tint(AgentXTheme.accent)
            .onAppear {
                appID = controller.selectedAppID
                if let existingDefinition {
                    name = existingDefinition.name
                    savedDefinitionID = existingDefinition.id
                    loadDocument(existingDefinition.draft ?? (try? existingDefinition.publishedDocument()) ?? .init(source: existingDefinition.prompt))
                }
                if let existingInstance {
                    name = existingInstance.name; appID = existingInstance.appID
                    definitionID = existingInstance.definitionID; providerID = existingInstance.providerID
                    model = existingInstance.model; pinnedRevision = existingInstance.definitionRevision ?? 0
                    credentialProfile = existingInstance.credentialProfile ?? ""
                    variableText = (existingInstance.variables ?? [:]).sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }.joined(separator: "\n")
                }
                if let existingProvider {
                    name = existingProvider.name
                    address = existingProvider.baseURL
                    serviceProtocol = existingProvider.serviceProtocol
                    credentialProfile = existingProvider.credentialProfile ?? ""
                    selection = existingProvider.modelSelection ?? .init(models: existingProvider.models.map { .init(id: $0, enabled: true) })
                    models = existingProvider.models.joined(separator: ", ")
                }
            }
    }
    private var currentDocument: AgentXDefinitionDocument { .init(source: prompt, files: definitionFiles, directories: definitionDirectories) }
    private func loadDocument(_ document: AgentXDefinitionDocument) {
        prompt = document.source; definitionFiles = document.files; definitionDirectories = document.directories
        selectedFile = "agent.md"
    }
    private var definitionFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("文件模式", isOn: $fileMode)
            if fileMode {
                HStack {
                    Picker("文件", selection: $selectedFile) {
                        Text("agent.md").tag("agent.md")
                        ForEach(definitionFiles.keys.sorted(), id: \.self) { Text($0).tag($0) }
                    }
                    Button("导入定义目录") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            do { loadDocument(try AgentXDefinitionDocument.importDirectory(url)); error = nil }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                }
                TextEditor(text: Binding(get: { selectedFile == "agent.md" ? prompt : definitionFiles[selectedFile] ?? "" }, set: { text in
                    if selectedFile == "agent.md" { prompt = text } else { definitionFiles[selectedFile] = text }
                })).font(.system(.body, design: .monospaced)).frame(height: 260).border(AgentXTheme.border).accessibilityLabel("定义文件正文")
                Text("保留 YAML frontmatter 和所有文本附件原文；引用必须相对于定义目录，链接和目录逃逸会被拒绝。").font(.caption).foregroundStyle(AgentXTheme.muted)
            } else {
                Text("系统提示词").font(.headline)
                TextEditor(text: Binding(get: { (try? currentDocument.bodyText()) ?? prompt }, set: { text in
                    do { prompt = try currentDocument.replacingBody(text).source } catch { self.error = error.localizedDescription }
                })).frame(height: 240).border(AgentXTheme.border).accessibilityLabel("系统提示词")
                Text("表单仅编辑正文，文件模式中的 frontmatter 与附件保持原样。").font(.caption).foregroundStyle(AgentXTheme.muted)
            }
            Text("保存草稿不会改变前台。发布后新请求使用新版本，进行中的请求保持原版本。当前仅执行 host-text 文本模型，无工具执行。").font(.caption).foregroundStyle(AgentXTheme.muted)
            if let id = savedDefinitionID, let definition = controller.state.definitions.first(where: { $0.id == id }), !(definition.revisions ?? []).isEmpty {
                Picker("发布历史", selection: $historyRevision) {
                    Text("选择版本").tag(0)
                    ForEach(definition.revisions ?? [], id: \.number) { Text("版本 \($0.number)").tag($0.number) }
                }
                Button("将所选版本恢复为草稿") {
                    do {
                        try controller.restoreDefinitionDraft(id: id, revision: historyRevision)
                        if let draft = controller.state.definitions.first(where: { $0.id == id })?.draft { loadDocument(draft) }
                    } catch { self.error = error.localizedDescription }
                }.disabled(historyRevision == 0)
            }
        }
    }
    private var providerFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("服务协议", selection: $serviceProtocol) {
                ForEach(AgentXServiceProtocol.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            field("API 地址", value: $address, hint: "https://api.example.com/v1")
            Text("根地址自动补 /v1 和所选协议端点；完整生成端点以 # 结尾。仅允许 HTTPS 或本机 HTTP。").font(.caption).foregroundStyle(AgentXTheme.muted)
            Picker("凭据配置", selection: $credentialProfile) {
                Text("此服务独立密钥 / 无认证").tag("")
                ForEach(controller.state.credentialProfiles ?? []) { Text($0.name).tag($0.name) }
            }
            if credentialProfile.isEmpty {
                SecureField(existingProvider == nil ? "API Key（本机无认证服务可留空）" : "API Key（留空保留原有密钥）", text: $secret)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("API Key")
            }
            DisclosureGroup("创建多密钥凭据配置") {
                VStack(alignment: .leading, spacing: 8) {
                    field("配置名称", value: $newProfileName, hint: "英文、数字、横线或下划线")
                    SecureField("多个 API Key 用逗号分隔", text: $newProfileKeys).textFieldStyle(.roundedBorder)
                    Button("保存凭据配置") {
                        do {
                            let keys = newProfileKeys.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                            try controller.addCredentialProfile(name: newProfileName, secrets: keys)
                            credentialProfile = newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
                            newProfileKeys = ""; newProfileName = ""; error = nil
                        } catch { self.error = error.localizedDescription }
                    }.disabled(newProfileName.isEmpty || newProfileKeys.isEmpty)
                }.padding(.top, 8)
            }
            Text("密钥仅保存在系统钥匙串，配置只记录引用。多密钥依次轮询；失败不自动重试。").font(.caption).foregroundStyle(AgentXTheme.muted)
            field("模型 ID（多个用逗号分隔）", value: $models, hint: "手动填写或从服务获取")
                .onChange(of: models) { _, _ in synchronizeModels() }
            Button(discovering ? "正在获取模型…" : "从服务获取模型") { discover() }
                .disabled(discovering || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let discoveryMessage { Text(discoveryMessage).font(.caption).foregroundStyle(AgentXTheme.muted) }
            ForEach(selection.models) { item in
                HStack {
                    Toggle(item.id, isOn: Binding(get: { selection.models.first { $0.id == item.id }?.enabled ?? false }, set: { enabled in
                        do { try selection.setEnabled(item.id, enabled: enabled) } catch { self.error = error.localizedDescription }
                    }))
                    Spacer()
                    Button {
                        do { try selection.setFavorite(item.id, favorite: !item.favorite) } catch { self.error = error.localizedDescription }
                    } label: { Image(systemName: item.favorite ? "star.fill" : "star") }
                    .accessibilityLabel("收藏模型 \(item.id)").buttonStyle(.borderless)
                }
            }
            if !selection.models.isEmpty {
                DisclosureGroup("分类默认模型") {
                    ForEach(AgentXModelCategory.allCases, id: \.self) { category in
                        Picker(categoryLabel(category), selection: Binding(get: { selection.defaultModel(for: category) ?? "" }, set: { id in
                            if id.isEmpty { selection.defaults[category.rawValue] = nil }
                            else { do { try selection.setDefault(id, category: category) } catch { self.error = error.localizedDescription } }
                        })) {
                            Text("未指定").tag("")
                            ForEach(selection.models.filter(\.enabled)) { Text($0.id).tag($0.id) }
                        }
                    }
                    Text("分类默认保存您的选择；当前前台仅执行文本对话。").font(.caption).foregroundStyle(AgentXTheme.muted)
                }
            }
        }
    }
    private func categoryLabel(_ category: AgentXModelCategory) -> String {
        switch category { case .chat: "对话"; case .image: "图像"; case .embedding: "向量"; case .audio: "音频"; case .rerank: "重排" }
    }
    private func synchronizeModels() {
        let ids = models.components(separatedBy: CharacterSet(charactersIn: ",，\n")).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var seen: Set<String> = []
        let unique = ids.filter { seen.insert($0).inserted }
        selection = .init(models: unique.map { id in selection.models.first { $0.id == id } ?? .init(id: id, enabled: true) }, defaults: selection.defaults.filter { unique.contains($0.value) })
    }
    private func discover() {
        discovering = true
        error = nil
        let requestedAddress = address
        let requestedProtocol = serviceProtocol
        let requestedProfile = credentialProfile
        let requestedSecret = secret
        Task { @MainActor in
            defer { discovering = false }
            do {
                let discovered = try await controller.discoverModels(address: requestedAddress, serviceProtocol: requestedProtocol, secret: requestedSecret,
                    providerID: existingProvider?.id, credentialProfile: requestedProfile)
                guard address == requestedAddress, serviceProtocol == requestedProtocol, credentialProfile == requestedProfile, secret == requestedSecret else {
                    discoveryMessage = "服务配置已变化，请重新获取模型。"
                    return
                }
                synchronizeModels()
                var seen = Set(selection.models.map(\.id))
                for item in discovered where seen.insert(item.id).inserted { selection.models.append(item) }
                models = selection.models.map(\.id).joined(separator: ", ")
                discoveryMessage = "服务返回 \(discovered.count) 个模型；新发现的模型需手动启用，保存后生效。"
            } catch { self.error = error.localizedDescription }
        }
    }
    private func field(_ label: String, value: Binding<String>, hint: String = "") -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.headline)
            TextField(hint.isEmpty ? label : hint, text: value).textFieldStyle(.roundedBorder).accessibilityLabel(label)
        }
    }
    private func save(publish: Bool = false) {
        do {
            if kind == .provider { synchronizeModels() }
            switch kind {
            case .app: try controller.addApp(name: name)
            case .provider:
                if let existingProvider {
                    try controller.updateProvider(id: existingProvider.id, name: name, address: address, models: models, secret: credentialProfile.isEmpty ? secret : "", serviceProtocol: serviceProtocol, credentialProfile: credentialProfile, modelSelection: selection)
                } else {
                    try controller.addProvider(name: name, address: address, models: models, secret: credentialProfile.isEmpty ? secret : "", serviceProtocol: serviceProtocol, credentialProfile: credentialProfile, modelSelection: selection)
                }
            case .definition:
                let id: String
                if let existing = savedDefinitionID { try controller.saveDefinitionDraft(id: existing, name: name, document: currentDocument); id = existing }
                else { id = try controller.addDefinitionDraft(name: name, document: currentDocument); savedDefinitionID = id }
                if publish { try controller.publishDefinition(id: id) }
            case .instance:
                var variables: [String: String] = [:]
                for line in variableText.split(separator: "\n") {
                    let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    guard parts.count == 2 else { throw AgentXError.invalid("变量格式应为 名称=值。") }
                    let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !key.isEmpty, variables[key] == nil else { throw AgentXError.invalid("变量名称不可为空或重复。") }
                    variables[key] = String(parts[1])
                }
                if let existingInstance {
                    try controller.updateInstance(id: existingInstance.id, name: name, appID: appID, definitionID: definitionID, providerID: providerID, model: model,
                        definitionRevision: pinnedRevision == 0 ? nil : pinnedRevision, variables: variables, credentialProfile: credentialProfile)
                } else {
                    try controller.addInstance(name: name, appID: appID, definitionID: definitionID, providerID: providerID, model: model,
                        definitionRevision: pinnedRevision == 0 ? nil : pinnedRevision, variables: variables, credentialProfile: credentialProfile)
                }
            }
            secret = ""
            newProfileKeys = ""
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
