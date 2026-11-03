import SwiftUI
import AppKit

@MainActor
struct AgentInstanceEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var instance: WorkbenchInstance
    var providerResolver: AgentXProviderResolver? = nil
    let save: (WorkbenchInstance, String) async throws -> Void
    @State private var commandText = ""
    @State private var key = ""
    @State private var error: String?
    @State private var advanced = false
    @State private var saving = false

    var body: some View {
        let providers = (try? providerResolver?.providers(category: .chat)) ?? []
        VStack(alignment: .leading, spacing: 14) {
            Text(instance.name.isEmpty ? "添加 ACP Agent" : instance.name).font(.title3.weight(.semibold))
            Text("受管容器与宿主模型服务").font(.caption).foregroundStyle(WorkbenchTheme.muted)
            Form {
                Section("常用配置") {
                    TextField("名称", text: $instance.name)
                    TextField("角色说明", text: $instance.role, axis: .vertical).lineLimit(2...4)
                    Picker("配置来源", selection: Binding(get: { instance.provider.agentXProviderID ?? "" }, set: { id in
                        instance.provider.agentXProviderID = id.isEmpty ? nil : id
                        if !id.isEmpty { instance.provider.model = "" }
                        key = ""
                    })) {
                        Text("独立配置（原有设置）").tag("")
                        ForEach(providers) { Text("统一服务 · " + $0.name).tag($0.id) }
                        if let id = instance.provider.agentXProviderID, !providers.contains(where: { $0.id == id }) {
                            Text("统一服务不可用 · " + id).tag(id)
                        }
                    }
                    if let id = instance.provider.agentXProviderID {
                        if let provider = providers.first(where: { $0.id == id }) {
                            Picker("模型", selection: $instance.provider.model) {
                                Text("跟随服务默认模型").tag("")
                                ForEach(provider.enabledModels, id: \.self) { Text($0).tag($0) }
                            }
                            Text(provider.serviceProtocol.title + " · " + provider.baseURL).font(.caption)
                            Text("引用 AgentX 的地址、模型与凭据。网关仍要求 HTTPS 域名或 /v1 地址。").font(.caption).foregroundStyle(WorkbenchTheme.muted)
                        } else { Text("统一服务已停用或被删除，请重新选择。").foregroundStyle(.red) }
                    } else {
                    Picker("模型接口", selection: $instance.provider.api) { ForEach(WorkbenchAPI.allCases) { Text($0.title).tag($0) } }
                    TextField("服务地址", text: $instance.provider.baseURL)
                    TextField("模型", text: $instance.provider.model)
                    SecureField("API Key（留空保留已保存值）", text: $key)
                    }
                }
                Section {
                    DisclosureGroup("容器与高级配置", isExpanded: $advanced) {
                        Picker("图标", selection: $instance.symbol) {
                            Text("开发").tag("terminal"); Text("研究").tag("chart.line.uptrend.xyaxis"); Text("通用").tag("sparkles")
                        }
                        TextField("SSH 主机（本机留空）", text: $instance.host)
                        TextField("Docker context（默认留空）", text: $instance.dockerContext)
                        TextField("镜像（name@sha256:…）", text: $instance.image)
                        HStack {
                            Text("命令预设").font(.caption)
                            Button("Codex") { commandText = "codex-acp"; instance.provider.api = .responses }
                            Button("Claude") { commandText = "claude-agent-acp"; instance.provider.api = .messages; instance.provider.baseURL = "https://api.anthropic.com" }
                            Button("DSH") { commandText = "dsh-acp"; instance.provider.api = .chatCompletions }
                        }
                        Text("命令与参数每行一项，不使用 shell 拼接。").font(.caption).foregroundStyle(WorkbenchTheme.muted)
                        TextEditor(text: $commandText).font(.system(.caption, design: .monospaced)).frame(height: 70).cottageInput()
                        Text("镜像需包含 Python 3.11+ 和 ACP 适配器；不会自动拉取。API Key 仅保存在宿主钥匙串，容器使用任务模型代理。").font(.caption).foregroundStyle(WorkbenchTheme.muted)
                    }
                }
            }.formStyle(.grouped).scrollContentBackground(.hidden).disabled(saving)
            if let error { Text(error).foregroundStyle(CottageTheme.terracotta).font(.caption).textSelection(.enabled) }
            HStack {
                Spacer(); Button("取消") { key = ""; dismiss() }.disabled(saving).keyboardShortcut(.cancelAction)
                Button(saving ? "正在保存…" : "保存更改") {
                    guard !saving else { return }
                    instance.command = commandText.components(separatedBy: .newlines).filter { !$0.isEmpty }
                    let candidate = instance, secret = key
                    saving = true
                    Task {
                        defer { saving = false }
                        do { try await save(candidate, secret); key = ""; dismiss() }
                        catch { self.error = error.localizedDescription; advanced = true }
                    }
                }.buttonStyle(.borderedProminent).disabled(saving)
            }
        }.padding(22).frame(width: min(660, (NSScreen.main?.visibleFrame.width ?? 900) - 100), height: min(620, (NSScreen.main?.visibleFrame.height ?? 800) - 100))
        .workbenchSurface()
        .interactiveDismissDisabled(saving)
        .onAppear { commandText = instance.command.joined(separator: "\n"); advanced = instance.image.isEmpty }
    }
}
