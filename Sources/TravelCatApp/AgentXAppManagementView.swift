import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct AgentXAppManagementView: View {
    @ObservedObject var controller: AgentXController
    @StateObject private var model: AgentXAppManagementModel
    @State private var section = "已安装"
    @State private var query = ""
    @State private var filter = "全部"
    init(controller: AgentXController, service: AgentXManagedApplicationService?) {
        self.controller = controller
        _model = StateObject(wrappedValue: AgentXAppManagementModel(controller: controller, service: service))
    }
    private var apps: [AgentXApplication] {
        controller.state.apps.filter {
            (query.isEmpty || ($0.name + " " + $0.id).localizedCaseInsensitiveContains(query)) &&
            (filter == "全部" || (filter == "已启用" ? $0.enabled : !$0.enabled))
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading) {
                    Text("应用管理").font(.title2.bold())
                    Text("安装配置，不启动任务。每个应用保留独立实例、记忆与运行记录。").font(.caption).foregroundStyle(AgentXTheme.muted)
                }
                Spacer()
                Menu("导入本地配置包") {
                    Button("ZIP 配置包…") { importPackage(directory: false) }
                    Button("已导出的配置目录…") { importPackage(directory: true) }
                }.disabled(model.service == nil || model.busy)
            }
            if model.service == nil {
                Label("应用管理服务未接入，安装、导出、卸载和恢复不可用。请重新打开完整应用。", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if let notice = model.notice { Text(notice).foregroundStyle(AgentXTheme.accent).textSelection(.enabled) }
            if model.loadingBackups { HStack { ProgressView().controlSize(.small); Text("正在校验卸载备份…").font(.caption) } }
            if model.dialog == nil, let failure = model.failure { Text(failure).foregroundStyle(.orange).textSelection(.enabled) }
            Picker("管理内容", selection: $section) {
                ForEach(["已安装", "本地模板库", "卸载备份"], id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.segmented)
            switch section {
            case "本地模板库": library
            case "卸载备份": backups
            default: installed
            }
        }
        .disabled(model.busy)
        .onAppear { model.loadBackupsIfNeeded() }
        .onDisappear { model.cancelBackupRefresh() }
        .sheet(item: Binding(get: { model.dialog }, set: { if $0 == nil { model.close() } })) { _ in
            Group {
                if case .install = model.dialog?.action {
                    AgentXAppCreationView(controller: controller, model: model)
                } else { AgentXAppManagementDialog(controller: controller, model: model) }
            }.frame(width: 680, height: 550).interactiveDismissDisabled(model.busy)
        }
    }
    private var installed: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                TextField("筛选应用名称或 ID", text: $query).textFieldStyle(.roundedBorder)
                Picker("状态", selection: $filter) {
                    ForEach(["全部", "已启用", "已停用"], id: \.self) { Text($0).tag($0) }
                }.frame(width: 170)
            }
            if apps.isEmpty { Text("没有匹配的应用。可从本地模板库创建，或导入 ZIP / 配置目录。").foregroundStyle(AgentXTheme.muted) }
            ForEach(apps) { app in
                AgentXCard {
                    HStack {
                        Label(app.name, systemImage: app.declaredIcon ?? "square.stack.3d.up").font(.headline)
                        Text(app.enabled ? "已启用" : "已停用").font(.caption).foregroundStyle(app.enabled ? AgentXTheme.accent : AgentXTheme.muted)
                        Spacer()
                        AgentXApplicationToggle(controller: controller, app: app)
                    }
                    AgentXStopStatusButton(controller: controller, appID: app.id)
                    AgentXAppPackageMetadata(app: app, instances: controller.state.instances.filter { $0.appID == app.id })
                    Text("目录：apps/\(app.id)/").font(.caption.monospaced()).textSelection(.enabled)
                    HStack {
                        Button("打开应用") { controller.openApp(app.id) }.buttonStyle(.borderedProminent).disabled(!canEnter(app))
                        Button("应用设置") {
                            if controller.selectApplication(app.id) { controller.navigate(to: .configuration) }
                        }.disabled(!canEnter(app))
                        Spacer()
                        Button("导出配置…") { export(app) }.disabled(model.service == nil || app.kind != .chat)
                        if ["blackcat", "workbench"].contains(app.id) {
                            Text("内建应用不可卸载").font(.caption).foregroundStyle(AgentXTheme.muted)
                        } else {
                            Button("卸载…", role: .destructive) { model.requestUninstall(app.id) }.disabled(model.service == nil)
                        }
                    }
                }
            }
            if !model.catalog.receipts.isEmpty {
                Button("查看 \(model.catalog.receipts.count) 份卸载备份并恢复") { section = "卸载备份" }
            }
            Text("停用会停止该应用并保留目录。权限清单只是应用声明，不代表系统授权。导出仅含可移植配置，不含凭据、会话或用户记忆。").font(.caption).foregroundStyle(AgentXTheme.muted)
        }
    }
    private func canEnter(_ app: AgentXApplication) -> Bool {
        app.enabled && (controller.state.singleAppID == nil || controller.state.singleAppID == app.id)
    }
    private var library: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("内建文本界面 · 本地模板").font(.headline)
            ForEach(AgentXLocalAppPackage.Template.allCases) { template in
                AgentXCard {
                    Label(template.title, systemImage: template == .scene ? "theatermasks" : "bubble.left.and.bubble.right").font(.headline)
                    Text(template.detail).foregroundStyle(AgentXTheme.muted)
                    Text("选择已配置模型 → 检查依赖和权限 → 确认安装；新应用默认停用。").font(.caption)
                    Button("使用模板…") { model.beginTemplate(template) }.disabled(model.service == nil)
                }
            }
            Text("当前支持本地模板、ZIP 和导出目录；仅内建文本或声明式界面，不执行包内代码。").font(.caption).foregroundStyle(AgentXTheme.muted)
        }
    }
    private var backups: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("已验证的本机卸载备份").font(.headline); Spacer(); Button("刷新") { model.refreshBackups() }.disabled(model.loadingBackups) }
            Text("包含卸载时的本机应用数据；恢复前再次校验，不覆盖同 ID 应用，恢复后保持停用。").font(.caption).foregroundStyle(AgentXTheme.muted)
            ForEach(model.catalog.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
            if model.catalog.receipts.isEmpty && !model.loadingBackups { Text("暂无可恢复的备份。").foregroundStyle(AgentXTheme.muted) }
            ForEach(model.catalog.receipts) { receipt in
                AgentXCard {
                    Text(receipt.appID).font(.headline)
                    Text(receipt.id).font(.caption.monospaced()).textSelection(.enabled)
                    Button("恢复…") { model.requestRestore(receipt) }
                        .disabled(model.service == nil || controller.state.apps.contains { $0.id == receipt.appID })
                    if controller.state.apps.contains(where: { $0.id == receipt.appID }) { Text("同 ID 应用已存在，不能覆盖恢复。").font(.caption).foregroundStyle(.orange) }
                }
            }
        }
    }
    private func importPackage(directory: Bool) {
        let panel = NSOpenPanel()
        panel.title = directory ? "选择已导出的应用配置目录" : "选择本地 ZIP 配置包"
        panel.canChooseDirectories = directory; panel.canChooseFiles = !directory; panel.allowsMultipleSelection = false
        if !directory { panel.allowedContentTypes = [.zip] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.beginImport(url, directory: directory)
    }
    private func export(_ app: AgentXApplication) {
        let panel = NSSavePanel()
        panel.title = "导出可移植配置目录"
        panel.message = "生成一个新目录，不含凭据、会话、运行记录或用户记忆。请选择尚不存在的目录名。"
        panel.nameFieldStringValue = app.id + "-config"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.export(app.id, to: url)
    }
}

@MainActor
struct AgentXAppManagementDialog: View {
    @ObservedObject var controller: AgentXController
    @ObservedObject var model: AgentXAppManagementModel
    @State private var showModels = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.title2.bold()); Spacer()
                Button("关闭") { model.close() }.keyboardShortcut(.cancelAction).disabled(model.busy)
            }
            if let failure = model.failure { Text(failure).foregroundStyle(.orange).font(.caption).textSelection(.enabled) }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch model.dialog?.action {
                    case .install: installation
                    case .uninstall(let id):
                        Text("卸载应用：\(id)").font(.headline)
                        Text("确认后先停用并等待全部运行停止，再创建并验证备份，最后移除应用目录。审计记录保留。停止未确认或备份失败时不会删除应用。")
                        Text("若操作失败，应用可能已停用；可关闭窗口后使用“重试停止”。").font(.caption).foregroundStyle(AgentXTheme.muted)
                    case .restore(let receipt):
                        Text("恢复应用：\(receipt.appID)").font(.headline)
                        Text("重新校验本机备份后恢复；同 ID 应用存在时拒绝覆盖，恢复不会启用或启动应用。")
                    case nil: EmptyView()
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                if model.busy { ProgressView().controlSize(.small); Text("正在停用并验证停止，请等待…").font(.caption) }
                Spacer()
                switch model.dialog?.action {
                case .install:
                    Button("重新预览") { model.preparePreview() }.disabled(model.busy)
                    Button("确认安装（保持停用）") { model.install() }.buttonStyle(.borderedProminent)
                        .disabled(model.busy || model.preview?.canInstall != true)
                case .uninstall:
                    Button("确认停用并卸载", role: .destructive) { Task { await model.confirmUninstall() } }.disabled(model.busy)
                case .restore:
                    Button("确认恢复") { model.confirmRestore() }.buttonStyle(.borderedProminent).disabled(model.busy)
                case nil: EmptyView()
                }
            }
        }.padding(20).background(Color(nsColor: .windowBackgroundColor))
    }
    private var title: String {
        switch model.dialog?.action { case .install: "安装前确认"; case .uninstall: "卸载与备份"; case .restore: "恢复备份"; case nil: "应用管理" }
    }
    private var installation: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.source {
            case .template(let template): Text("本地模板：\(template.title) · \(template.detail)").font(.headline)
            case .directory(let url), .zip(let url): Text("来源：\(url.path)").font(.caption).textSelection(.enabled)
            case nil: EmptyView()
            }
            TextField("应用 ID（字母、数字、连字符；导入留空保留原 ID）", text: $model.appID).textFieldStyle(.roundedBorder)
            Text("更改 ID 或模型后必须重新预览；重复 ID 不会覆盖现有应用。").font(.caption).foregroundStyle(AgentXTheme.muted)
            if case .template = model.source {
                if controller.state.providers.isEmpty {
                    Text("尚未配置模型服务。请关闭此窗口，进入“平台基石 → 模型服务”添加服务并启用文本模型。").foregroundStyle(.orange)
                } else {
                    DisclosureGroup(model.selection.map { "模型：\($0.providerID) / \($0.model)（展开更换）" } ?? "选择模型（收藏与目录搜索）",
                                    isExpanded: Binding(get: { showModels || model.selection == nil }, set: { showModels = $0 })) {
                        AgentXModelBrowser(providers: controller.state.providers, selected: model.selection,
                            choose: { model.selection = $0.choice; showModels = false },
                            favorite: { try controller.setModelFavorite(providerID: $0.providerID, modelID: $0.model.id, favorite: !$0.model.favorite) })
                            .frame(height: 320)
                    }
                    if model.selection == nil { Text("请展开模型目录选择已启用文本模型；无可用模型时到模型服务配置。").font(.caption).foregroundStyle(.orange) }
                }
            }
            if let preview = model.preview {
                AgentXCard {
                    Text("预览：\(preview.application.name)").font(.headline)
                    Text(preview.includedContent).font(.caption)
                    DisclosureGroup("查看提示词与应用设定") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(preview.definitions) { definition in
                                Text(definition.name).font(.subheadline.bold())
                                Text(definition.prompt).font(.caption).textSelection(.enabled)
                            }
                            if let experience = preview.application.experience?.published?.configuration ?? preview.application.experience?.draft {
                                Text("应用介绍：" + experience.intro).font(.caption)
                                Text("应用规则：" + (experience.rules.isEmpty ? "未设置" : experience.rules)).font(.caption)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    AgentXAppPackageMetadata(app: preview.application, instances: preview.instances)
                    Text("运行能力：内建文本对话\(preview.frontend == nil ? "" : "与声明式表单界面")；无包内代码执行。").font(.caption)
                    Text("安装只写入配置并创建实例，保持停用，不自动运行。").font(.caption).foregroundStyle(AgentXTheme.accent)
                    ForEach(preview.missingRequirements, id: \.self) { Text("需处理：" + $0).font(.caption).foregroundStyle(.orange) }
                    if !preview.canInstall { Text("依赖未满足或 ID 冲突：修正上方 ID / 模型，或先在模型服务配置依赖，再重新预览。").font(.caption) }
                }
            } else { Text("填写后点击“重新预览”，查看实际清单、依赖和权限后再确认。").foregroundStyle(AgentXTheme.muted) }
        }
    }
}

struct AgentXAppPackageMetadata: View {
    let app: AgentXApplication
    let instances: [AgentXInstance]
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(app.id) · 版本 \(AgentXAppManifestFormatter.display(app.version)) · 运行框架 \(app.requiredRuntime ?? "未声明")")
            Text("来源：\(app.manifestSource ?? "未声明") · 作者：\(app.manifestAuthor ?? "未声明")")
            Text("依赖声明")
            ForEach(AgentXAppManifestFormatter.requirements(app.manifest?["requires"]), id: \.self) { Text($0).padding(.leading, 8) }
            if !instances.isEmpty { Text("实例模型：" + instances.map { $0.providerID + " / " + $0.model }.joined(separator: "；")) }
            Text("声明权限（不代表操作系统授权）")
            ForEach(AgentXAppManifestFormatter.permissions(app.manifest?["permissions"]), id: \.self) { Text($0).padding(.leading, 8) }
        }.font(.caption).foregroundStyle(AgentXTheme.muted).textSelection(.enabled)
    }
}
