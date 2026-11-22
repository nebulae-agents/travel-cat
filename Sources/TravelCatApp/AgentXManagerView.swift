import AppKit
import SwiftUI

enum AgentXTheme {
    private static func color(_ dark: UInt32, _ light: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }
    static let background = color(0x0F1115, 0xF3F4F7)
    static let sidebar = color(0x12151B, 0xF3F4F7)
    static let surface = color(0x161A22, 0xFFFFFF)
    static let border = color(0x2A3140, 0xD9DDE4)
    static let text = color(0xE6E9EF, 0x1B1F27)
    static let accent = color(0xF0A04B, 0xB8651A)
    static let muted = color(0xAEB6C4, 0x4B5565)
    static let running = color(0x3DD6C1, 0x0E8F7E)
}

struct AgentXCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(AgentXTheme.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(AgentXTheme.border, lineWidth: 1))
    }
}

enum AgentXEditor: String, Identifiable { case app, provider, definition, instance; var id: Self { self } }

@MainActor
struct AgentXManagerView: View {
    @ObservedObject var controller: AgentXController
    var applicationService: AgentXManagedApplicationService? = nil
    var openJourney: () -> Void = {}
    var openAlbum: () -> Void = {}
    var openTravelPrompt: () -> Void = {}
    var travelPending = false
    var workbenchPending = 0
    var openWorkbench: () -> Void = {}
    var workbenchContent: (() -> AnyView)? = nil
    @State private var editor: AgentXEditorPresentation?
    @State private var migrationMessage: String?
    @State private var blackCatTab = 0
    @State private var holdingStop = false
    private var isFront: Bool { controller.page == .chat }
    private var pendingCount: Int { AgentXAppNavigationPolicy.pending(app: controller.currentApp, unread: controller.currentUnreadCount, travel: travelPending, workbench: workbenchPending) }
    private var usesUsageAssistant: Bool { controller.usesUsageAssistant }

    var body: some View {
        HStack(spacing: 0) {
            AgentXAppRail(controller: controller)
            VStack(spacing: 0) {
                AgentXAppHeader(controller: controller, pending: pendingCount)
                Divider().overlay(AgentXTheme.border)
                if let issue = controller.pilotConnectionIssue {
                    Label(issue, systemImage: "wifi.slash").padding(8)
                }
                if let error = controller.errorMessage {
                    HStack {
                        Label(error, systemImage: "exclamationmark.triangle").textSelection(.enabled)
                        Spacer()
                        if controller.isLoaded { Button("关闭提示") { controller.errorMessage = nil } }
                    }.padding(12).background(Color.red.opacity(0.12))
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) { content }
                        .id(AgentXAppNavigationPolicy.contentScope(page: controller.page, appID: controller.selectedAppID))
                        .padding(28)
                        .frame(maxWidth: isFront && controller.currentApp?.kind != .workbench ? 956 : .infinity, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .background(AgentXTheme.background).foregroundStyle(AgentXTheme.text)
        .tint(AgentXTheme.accent)
        .frame(minWidth: 960, minHeight: 640)
        .overlay(alignment: .bottomTrailing) {
            if !controller.page.isPlatform && controller.currentApp != nil {
                Button { controller.assistantPresented.toggle() } label: {
                    Label(usesUsageAssistant ? "使用助手" : "配置助手", systemImage: "sparkles").padding(10)
                }.buttonStyle(.bordered).background(AgentXTheme.surface, in: Capsule()).padding(16)
                .popover(isPresented: $controller.assistantPresented) {
                    AgentXAssistantPanel(controller: controller, isFront: usesUsageAssistant).frame(width: 380)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let notice = controller.undoNotice {
                HStack {
                    Text(notice)
                    Button("撤销") { performAsync { try await controller.undoLastChange() } }
                        .disabled(!controller.canUndo).keyboardShortcut("z", modifiers: .command)
                }.padding(14).background(AgentXTheme.surface, in: Capsule())
                    .overlay(Capsule().stroke(AgentXTheme.border)).padding(16)
            }
        }
        .task {
            guard controller.hasPilotApps else { return }
            while !Task.isCancelled {
                await controller.refreshPilotRuns()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .background(AgentXShellShortcuts(controller: controller))
        .onChange(of: controller.shellContextGeneration) { _, generation in
            editor = editor?.retained(in: generation); migrationMessage = nil; blackCatTab = 0
        }
        .sheet(item: $controller.shellOverlay) { overlay in
            switch overlay {
            case .switcher: AgentXAppSwitcher(controller: controller)
            case .search: AgentXAppSearch(controller: controller)
            }
        }
        .sheet(item: $editor) { presentation in
            AgentXEditorView(controller: controller, kind: presentation.kind,
                             existingProvider: presentation.existingProvider,
                             existingDefinition: presentation.existingDefinition,
                             existingInstance: presentation.existingInstance)
        }
    }

    @ViewBuilder private var content: some View {
        switch controller.page {
        case .overview: applicationOverview
        case .platformOverview: overview
        case .module: moduleContent
        case .apps: applications
        case .providers: providers
        case .definitions: definitions
        case .instances, .members: instances
        case .sceneRules, .appModels, .appFiles, .appSettings:
            AgentXAppStudioView(controller: controller, section: controller.page)
        case .backups: settings
        case .governance: governance
        case .configuration: AgentXAppConfigurationView(controller: controller)
        case .characters: AgentXCharacterStudioView(controller: controller).frame(minHeight: 650)
        case .workflows: AgentXWorkflowStudioView(controller: controller)
        case .chat: chat
        case .runs: runList(controller.state.runs.filter { $0.appID == controller.selectedAppID }.reversed(), inbox: false)
        case .inbox:
            if controller.currentApp?.kind == .workbench && workbenchPending > 0 {
                HStack {
                    Label("Agent 工作台有 \(workbenchPending) 项待处理", systemImage: "tray.full")
                    Spacer()
                    Button("打开工作台", action: openWorkbench)
                }.padding().background(AgentXTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            }
            if controller.currentApp?.kind == .blackcat && travelPending {
                AgentXCard {
                    Label("BlackCat · 旅行提醒", systemImage: "pawprint.fill").font(.headline)
                    Text("打开对应的明信片或旅程并确认此条提醒；如果存储异常，提醒会保留。").foregroundStyle(AgentXTheme.muted)
                    Button("查看并确认提醒", action: openTravelPrompt)
                }
            }
            runList(controller.currentRuns.filter { $0.status.terminal && !$0.isRead }.reversed(), inbox: true)
        case .settings: settings
        }
    }

    @ViewBuilder private var applicationOverview: some View {
        if let app = controller.currentApp {
            VStack(alignment: .leading, spacing: 8) {
                Text(app.name).font(.system(size: 26, weight: .semibold))
                Text("当前应用 · 已启用").foregroundStyle(AgentXTheme.muted)
            }
            HStack(spacing: 16) {
                metric("成员", count: controller.currentInstances.count, icon: "person.2")
                metric("本地运行中", count: controller.currentRuns.filter { !$0.status.terminal }.count, icon: "waveform.path")
                metric("待处理", count: pendingCount, icon: "tray")
            }
            AgentXCard {
                Text("应用入口").font(.headline)
                Text("本地运行仅来自宿主记录；外部引擎状态未在此汇总。").font(.caption).foregroundStyle(AgentXTheme.muted)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                    ForEach(controller.currentModules) { module in
                        Button { controller.selectModule(module.id) } label: {
                            Label(module.title, systemImage: module.page.icon).frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                        }
                    }
                }
            }
            runList(Array(controller.currentRuns.suffix(5).reversed()), inbox: false)
        } else {
            AgentXCard {
                Text("没有已启用的应用").font(.title2)
                Text("在应用管理中启用已有应用，或使用切换器查看已停用应用。")
                Button("应用管理") { controller.navigate(to: .apps) }
            }
        }
    }

    @ViewBuilder private var moduleContent: some View {
        if let app = controller.currentApp {
            let module = AgentXAppNavigationPolicy.module(controller.currentModuleID)
            if module.id == "stage" {
                if app.experience?.published != nil { AgentXExperienceFrontView(controller: controller) }
                else { AgentXCard { Text("尚无已发布场景"); Button("配置场景") { controller.navigate(to: .sceneRules) } } }
            } else if module.id == "world-state" || module.id == "npc-memory" {
                AgentXCard {
                    Text(module.title).font(.title2)
                    Text("以下为已发布资料，不代表模拟引擎的实时状态。").font(.caption).foregroundStyle(AgentXTheme.muted)
                    if let experience = app.experience?.published?.configuration {
                        if module.id == "world-state" {
                            Text(experience.title).font(.headline)
                            Text(experience.intro.isEmpty ? "未发布场景背景" : experience.intro).textSelection(.enabled)
                            Text(experience.rules.isEmpty ? "未发布规则" : experience.rules).textSelection(.enabled)
                        }
                        Text(experience.sharedMemory.isEmpty ? "未发布共享记忆" : experience.sharedMemory).textSelection(.enabled)
                    } else { Text("尚无已发布场景或共享记忆。") }
                    if module.id == "npc-memory" {
                        ForEach(controller.currentInstances) { instance in
                            Text(instance.name).font(.headline)
                            if let memory = controller.displayedCharacterMemory(instanceID: instance.id) {
                                Text(memory.isEmpty ? "未发布人物记忆设定" : memory).textSelection(.enabled)
                            }
                        }
                    }
                    Button("编辑场景与规则") { controller.navigate(to: .sceneRules) }
                    Button("编辑人物") { controller.navigate(to: .characters) }
                }
            } else if module.id == "director-intervention" {
                AgentXCard {
                    Text("导演干预").font(.title2)
                    Text("实时模拟干预引擎尚未接入。可在后台修改场景与人物，发布后用于后续对话。")
                    Button("场景与规则") { controller.navigate(to: .sceneRules) }
                    Button("人物定制") { controller.navigate(to: .characters) }
                }
            } else {
                AgentXCard { Text("模块暂不可用").font(.title2); Text("当前宿主不支持模块：\(module.id)。应用声明与输入已保留。") }
            }
        }
    }

    private var overview: some View {
        Group {
            VStack(alignment: .leading, spacing: 8) {
                Text("让每个 Agent，都有自己的工作空间。").font(.system(size: 26, weight: .semibold))
                Text("连接模型，定义角色，组装应用。BlackCat 与 Dock 共用一个管理入口。")
                    .foregroundStyle(AgentXTheme.muted)
            }
            HStack(spacing: 16) {
                metric("应用", count: controller.state.apps.count, icon: "square.stack.3d.up")
                metric("Agent 实例", count: controller.state.instances.count, icon: "cpu")
                metric("模型服务", count: controller.state.providers.count, icon: "server.rack")
                metric("待处理", count: controller.state.unreadCount + (travelPending ? 1 : 0) + workbenchPending, icon: "tray")
            }
            AgentXCard {
                Label("从模型服务开始", systemImage: "point.3.connected.trianglepath.dotted").font(.headline)
                Text("① 配置模型服务   →   ② 创建 Agent 定义   →   ③ 新建应用与实例   →   ④ 进入前台对话")
                    .foregroundStyle(AgentXTheme.muted).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("配置模型服务") { controller.navigate(to: .providers) }.buttonStyle(.borderedProminent)
                    Button("查看所有应用") { controller.navigate(to: .apps) }
                }
            }
            blackCatCard
            AgentXCard {
                Label("当前运行能力", systemImage: "checkmark.shield").font(.headline)
                Text("原生文本对话 · 宿主模型连接 · 无工具执行权限").foregroundStyle(AgentXTheme.running)
                Text("模型服务支持多协议文本请求；Agent 工作台保留受控 Codex / ACP 路径。设置可登记离线迁移、应用包升级、回滚和状态备份。其他框架与统一预算尚未接入。")
                    .font(.caption).foregroundStyle(AgentXTheme.muted)
            }
        }
    }
    private func metric(_ title: String, count: Int, icon: String) -> some View {
        AgentXCard {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(AgentXTheme.muted)
            Text("\(count)").font(.system(size: 30, weight: .semibold, design: .monospaced))
        }
    }
    private var blackCatCard: some View {
        AgentXCard {
            HStack {
                Label("BlackCat", systemImage: "pawprint.fill").font(.title3.bold())
                Spacer()
                Text(controller.state.blackCatEnabled ? "● 桌宠入口已启用" : "○ Dock 入口").foregroundStyle(AgentXTheme.running).font(.caption)
            }
            Text("原生内嵌 · 旅行与陪伴").foregroundStyle(AgentXTheme.muted)
            HStack {
                Button("当前旅程", action: openJourney).buttonStyle(.borderedProminent)
                Button("旅行册", action: openAlbum)
                Spacer()
                Menu("更多") { Button("入口设置") { controller.navigate(to: .settings) } }
            }
        }
    }
    private var applications: some View {
        AgentXAppManagementView(controller: controller, service: applicationService)
    }
    private var providers: some View {
        Group {
            actionHeader("统一模型服务", button: "添加服务", kind: .provider)
            if controller.state.providers.isEmpty { empty("还没有模型服务", detail: "添加 OpenAI 兼容服务或本机模型，密钥保存在系统钥匙串。", action: "添加服务", kind: .provider) }
            ForEach(controller.state.providers) { provider in
                AgentXCard {
                    HStack {
                        Label(provider.name, systemImage: "server.rack").font(.headline)
                        Spacer()
                        Toggle("启用", isOn: Binding(get: { provider.enabled }, set: { value in perform { try controller.setProviderEnabled(provider.id, enabled: value) } })).toggleStyle(.switch)
                    }
                    Text(provider.baseURL).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Text("目录 \(provider.models.count) 个 · 可用文本模型 \(provider.enabledModels.count) 个").foregroundStyle(AgentXTheme.running)
                    Text(provider.enabledModels.prefix(8).joined(separator: "  ·  ")).font(.caption).lineLimit(3)
                    if provider.isOpenRouter {
                        HStack {
                            Button(controller.refreshingCatalogs.contains(provider.id) ? "正在更新…" : "更新模型目录") {
                                Task { await controller.refreshOpenRouterCatalog(providerID: provider.id, force: true) }
                            }.disabled(!provider.enabled || controller.refreshingCatalogs.contains(provider.id))
                            if let date = provider.catalogRefreshedAt { Text("上次更新：" + date.formatted(date: .abbreviated, time: .shortened)).font(.caption) }
                            else { Text("尚未同步").font(.caption) }
                        }
                        if let error = controller.catalogErrors[provider.id] { Text(error).font(.caption).foregroundStyle(.orange) }
                        Text("启动时检查目录，24 小时内使用缓存；新模型需手动启用。").font(.caption).foregroundStyle(AgentXTheme.muted)
                    }
                    Text("\(provider.serviceProtocol.title) · \(controller.state.instances.filter { $0.providerID == provider.id }.count) 个实例引用").font(.caption).foregroundStyle(AgentXTheme.muted)
                    Button("编辑配置") { presentEditor(AgentXEditorPresentation(provider: provider)) }
                }
            }
        }
    }
    private var definitions: some View {
        Group {
            actionHeader("可复用的角色定义", button: "创建定义", kind: .definition)
            if controller.state.definitions.isEmpty { empty("定义 Agent 的职责", detail: "系统提示词定义角色行为；每个实例保留独立对话记录。", action: "创建定义", kind: .definition) }
            ForEach(controller.state.definitions) { definition in
                AgentXCard {
                    Label(definition.name, systemImage: "person.text.rectangle").font(.headline)
                    Text(definition.isPublished ? "已发布版本 \(definition.publishedRevision ?? 1)" : "仅草稿 · 尚未发布").font(.caption).foregroundStyle(AgentXTheme.muted)
                    Text(definition.prompt.isEmpty ? definition.draft?.source ?? "" : definition.prompt).lineLimit(5).textSelection(.enabled).foregroundStyle(AgentXTheme.muted)
                    Button("编辑定义 / 发布") { presentEditor(AgentXEditorPresentation(definition: definition)) }
                }
            }
        }
    }
    private var visibleInstances: [AgentXInstance] { controller.page == .instances ? controller.state.instances : controller.currentInstances }
    private var instances: some View {
        Group {
            if controller.page == .members && controller.currentApp?.kind == .workbench { workbenchModule }
            else {
                actionHeader(controller.page == .instances ? "所有应用 · Agent 实例" : "\(controller.currentApp?.name ?? "应用") · 成员", button: "创建实例", kind: .instance)
                if visibleInstances.isEmpty { empty("还没有实例", detail: "选择定义与模型服务，将角色加入应用。", action: "创建实例", kind: .instance) }
                ForEach(visibleInstances) { instance in
                    AgentXCard {
                        HStack { Label(instance.name, systemImage: "cpu").font(.headline); Spacer(); Text("原生对话").font(.caption).foregroundStyle(AgentXTheme.running) }
                        Text(instance.model).font(.system(.body, design: .monospaced))
                        Text("定义：\(controller.state.definitions.first { $0.id == instance.definitionID }?.name ?? "未知") · 独立记忆 / 工作目录 / 配置 / 凭据引用").foregroundStyle(AgentXTheme.muted).font(.caption)
                        HStack {
                            Button("开始对话") { if controller.selectApplication(instance.appID) { controller.selectedInstanceID = instance.id; controller.navigate(to: .chat) } }.buttonStyle(.borderedProminent)
                            Button("编辑实例") { if controller.selectApplication(instance.appID) { presentEditor(AgentXEditorPresentation(instance: instance)) } }
                                .disabled(controller.isInstanceBusy(instance.id))
                        }
                    }
                }
            }
        }
    }
    @ViewBuilder private var workbenchModule: some View {
        if let workbenchContent {
            workbenchContent().frame(minHeight: 600)
        } else {
            AgentXCard {
                Label("Agent 工作台", systemImage: "terminal").font(.headline)
                Text("工作台由宿主提供独立会话与运行配置；已导入的旧记录仅以只读方式展示。")
                Button("打开工作台") { openWorkbench() }
            }
        }
    }
    @ViewBuilder private var chat: some View {
        if controller.currentApp?.kind == .blackcat {
            blackCatLauncher
        } else if controller.currentApp?.kind == .workbench {
            workbenchModule
        } else if let app = controller.currentApp, !app.canRunHostText {
            AgentXCard {
                Text(app.name).font(.headline)
                Text("此应用类型（\(app.kind.rawValue)）尚未接入运行框架。配置与已有文件已保留。")
                    .foregroundStyle(AgentXTheme.muted)
            }
        } else if let app = controller.currentApp,
                  AgentXFrontendStore(root: controller.repository.root, appID: app.id).exists {
            AgentXFrontendView(controller: controller, appID: app.id).id(app.id)
        } else if controller.currentApp?.experience?.published?.configuration.layout == .scene && controller.frontSkin == .immersive {
            AgentXExperienceFrontView(controller: controller)
        } else {
            if let instance = controller.currentInstance {
                AgentXChatView(controller: controller, instance: instance)
            } else {
                empty("为应用添加一个对话 Agent", detail: "先配置模型服务与定义，然后创建实例。", action: "创建实例", kind: .instance)
            }
        }
    }
    private var blackCatLauncher: some View {
        VStack(alignment: .leading, spacing: 20) {
            Picker("BlackCat 面板", selection: $blackCatTab) {
                Text("应用").tag(0)
                Text("待处理 · \(pendingCount)").tag(1)
                Text("动态").tag(2)
            }.pickerStyle(.segmented)
            if blackCatTab == 0 {
                if let urgent = controller.currentRuns.last(where: { $0.status == .failed && !$0.isRead }) {
                    runList([urgent], inbox: true, allowMarkAll: false)
                }
                blackCatApplications
            } else if blackCatTab == 1 {
                if controller.currentApp?.kind == .blackcat && travelPending { AgentXCard { Label("旅行提醒", systemImage: "pawprint"); Button("查看并确认提醒", action: openTravelPrompt) } }
                if controller.currentApp?.kind == .workbench && workbenchPending > 0 { AgentXCard { Text("工作台有 \(workbenchPending) 项待处理"); Button("打开工作台", action: openWorkbench) } }
                runList(controller.currentRuns.filter { $0.status.terminal && !$0.isRead }.reversed(), inbox: true)
            } else {
                runList(Array(controller.currentRuns.suffix(20).reversed()), inbox: false)
            }
        }
    }
    private var blackCatApplications: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("今天，想做点什么？").font(.system(size: 28, weight: .semibold))
                Text("查看旅程与明信片，或与 BlackCat 对话。") .foregroundStyle(AgentXTheme.muted)
            }
            if pendingCount > 0 {
                AgentXCard {
                    Label("需要你看看 · \(pendingCount)", systemImage: "bell.badge").font(.headline)
                    Button("查看全部待处理") { blackCatTab = 1 }.buttonStyle(.borderedProminent)
                }
            }
            blackCatCard
            if let instance = controller.currentInstance {
                DisclosureGroup("和 BlackCat 对话") { AgentXChatView(controller: controller, instance: instance) }
            }
        }
    }

    private func runList(_ runs: [AgentXRun], inbox: Bool, allowMarkAll: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(inbox ? "需要你关注的结果" : "运行与结果").font(.headline)
                Spacer()
                if inbox && allowMarkAll && !runs.isEmpty { Button("全部标记已读") { performAsync { try await controller.markAllRead() } } }
            }
            if runs.isEmpty {
                AgentXCard {
                    Label(inbox ? "暂时没有待处理事项" : "还没有运行记录", systemImage: inbox ? "checkmark.circle" : "clock")
                    Button("进入应用前台") { controller.navigate(to: .chat) }
                }
            }
            ForEach(runs) { run in
                AgentXCard {
                    HStack {
                        Text(controller.state.apps.first { $0.id == run.appID }?.name ?? run.appID).font(.headline)
                        Spacer()
                        Text(run.displayedStatus).foregroundStyle(run.status == .failed ? .red : AgentXTheme.running)
                    }
                    if run.purpose == .usageAssistant { Label("使用助手", systemImage: "sparkles").font(.caption).foregroundStyle(AgentXTheme.accent) }
                    if run.purpose == .configuration { Label("配置助手 · 定义建议", systemImage: "sparkles").font(.caption).foregroundStyle(AgentXTheme.accent) }
                    Text(run.prompt).lineLimit(3).textSelection(.enabled)
                    AgentXPilotRunIdentity(run: run)
                    if let failure = run.failure { Text(failure).foregroundStyle(.orange) }
                    Text(run.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(AgentXTheme.muted)
                    HStack {
                        Button(run.purpose == .configuration ? "查看配置建议" : run.purpose == .workflow ? "查看工作流" : run.purpose == .characterPreview ? "查看人物试说" : "查看对话") { controller.openRun(run) }.buttonStyle(.borderedProminent)
                        if run.status.terminal && !run.isRead { Button("标记已读") { performAsync { try await controller.markRead(run.id) } } }
                        if !run.status.terminal { Button("取消运行") { controller.cancel(run.id) }.disabled(run.status == .cancelling) }
                    }
                }
            }
        }
    }
    private var softStopControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(holdingStop ? "继续按住…" : "软停止 · 长按 2 秒", systemImage: "stop.circle")
                .frame(maxWidth: .infinity, minHeight: 40).contentShape(Rectangle())
                .foregroundStyle(.red)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.red.opacity(0.65)))
                .onLongPressGesture(minimumDuration: 2, pressing: { holdingStop = $0 }) { controller.softStopAll() }
                .accessibilityLabel("长按两秒请求停止全部宿主文本运行")
            Text("仅宿主文本运行；等待取消确认，不含外部工作台。")
                .font(.caption2).foregroundStyle(AgentXTheme.muted)
        }
    }
    private var governance: some View {
        Group {
            AgentXCard {
                Label("运行与安全边界", systemImage: "checkmark.shield").font(.headline)
                Text("当前活跃运行：\(controller.state.activeCount) · 未读结果：\(controller.state.unreadCount)")
                Text("统一预算、费用统计及独立审批审计尚未接入。下方展示已保存的真实运行记录。")
                    .foregroundStyle(AgentXTheme.muted)
                softStopControl
                Text("全平台应用停止状态").font(.headline)
                ForEach(controller.state.apps) { app in
                    HStack { Text(app.name); Spacer(); AgentXStopStatusButton(controller: controller, appID: app.id) }
                }
            }
            runList(Array(controller.state.runs.reversed()), inbox: false)
        }
    }
    private var settings: some View {
        Group {
            if let storage = controller.hostStorage {
                AgentXAppLifecycleView(apps: controller.state.apps,
                    coordinator: AgentXOfflineAppLifecycle(root: controller.repository.root, locator: storage.coordinator.locator),
                    migrationPending: { storage.hasPendingMigration })
            }
            AgentXCard {
                Label("桌面入口", systemImage: "dock.rectangle").font(.headline)
                Toggle("显示 BlackCat 桌宠", isOn: Binding(get: { controller.state.blackCatEnabled }, set: { value in perform { try controller.setBlackCatEnabled(value) } })).toggleStyle(.switch)
                Text("关闭后其他应用继续运行。Dock 数字提示未读结果、工作台审批与旅行待处理事项，点击图标进入管理窗口。").foregroundStyle(AgentXTheme.muted)
            }
            AgentXCard {
                Label("启动方式", systemImage: "macwindow").font(.headline)
                Picker("默认入口", selection: Binding(get: { controller.state.singleAppID ?? "" }, set: { id in perform { try controller.setSingleApp(id.isEmpty ? nil : id) } })) {
                    Text("恢复上次应用").tag("")
                    ForEach(controller.enabledApps) { app in Text("单应用 · \(app.name)").tag(app.id) }
                }
                Text("单应用模式限制应用切换；需在此处或切换器明确退出。BlackCat 显示开关独立生效。").font(.caption).foregroundStyle(AgentXTheme.muted)
            }
            AgentXCard {
                Label("数据与迁移边界", systemImage: "folder").font(.headline)
                Text(controller.repository.root.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Text("平台、提供方、模板、应用配置与运行记录分层保存；BlackCat 与工作台数据分别位于 apps 内。密钥保留在本机钥匙串。迁移在正常退出后的下一次启动执行，完成前仍使用当前目录，旧目录保留。").foregroundStyle(AgentXTheme.muted)
                HStack {
                    Button("选择迁移目标…") { chooseMigrationDestination() }
                    Button("取消待执行迁移") { updateMigration { try $0.cancelMigration(); return "待执行迁移已取消。" } }
                }
                if let migrationMessage { Text(migrationMessage).textSelection(.enabled) }
            }
        }
    }
    private func updateMigration(_ action: (AgentXHostStorage) throws -> String) {
        do {
            guard let storage = controller.hostStorage else { throw AgentXError.unavailable }
            migrationMessage = try action(storage)
        } catch { migrationMessage = error.localizedDescription }
    }
    private func chooseMigrationDestination() {
        let panel = NSSavePanel()
        panel.title = "选择新的 AgentX 根目录"
        panel.prompt = "登记迁移"
        panel.nameFieldStringValue = "AgentXData"
        panel.canCreateDirectories = true
        panel.message = "填写尚不存在的新目录。正常退出后重新启动完成迁移；当前不会复制或切换。"
        guard panel.runModal() == .OK, let target = panel.url else { return }
        updateMigration { storage in
            try storage.requestMigration(to: target)
            return "已登记目标：\(target.path)。尚未迁移；请正常退出再启动。旧写入者未确认退出时将保留当前目录并报告原因。"
        }
    }
    private func presentEditor(_ presentation: AgentXEditorPresentation) {
        editor = presentation.scoped(to: controller.shellContextGeneration)
    }

    private func actionHeader(_ text: String, button: String, kind: AgentXEditor) -> some View {
        HStack { Text(text).font(.headline); Spacer(); Button(button, systemImage: "plus") { presentEditor(AgentXEditorPresentation(create: kind)) }.buttonStyle(.borderedProminent).disabled(!controller.isLoaded) }
    }
    private func empty(_ title: String, detail: String, action: String, kind: AgentXEditor) -> some View {
        AgentXCard {
            Text(title).font(.title3.bold())
            Text(detail).foregroundStyle(AgentXTheme.muted)
            Button(action) { presentEditor(AgentXEditorPresentation(create: kind)) }.buttonStyle(.borderedProminent).disabled(!controller.isLoaded)
        }
    }
    private func performAsync(_ operation: @escaping @MainActor () async throws -> Void) {
        Task { do { try await operation() } catch { controller.errorMessage = error.localizedDescription } }
    }
    private func perform(_ operation: () throws -> Void) { do { try operation() } catch { controller.errorMessage = error.localizedDescription } }
}

@MainActor
private struct AgentXChatView: View {
    @ObservedObject var controller: AgentXController
    let instance: AgentXInstance
    var body: some View {
        let reviewNotice = controller.pilotReviewNotice(for: instance.id)
        VStack(alignment: .leading, spacing: 20) {
            Picker("对话实例", selection: Binding(get: { instance.id }, set: { controller.selectedInstanceID = $0 })) {
                ForEach(controller.currentInstances) { Text($0.name).tag($0.id) }
            }
            AgentXModelPicker(controller: controller, instance: instance)
            AgentXConfigurationSummaryView(controller: controller, instance: instance)
            ForEach(controller.state.runs.filter { $0.instanceID == instance.id && $0.purpose == nil }) { run in
                AgentXCard {
                    Text("你").font(.caption).foregroundStyle(AgentXTheme.accent)
                    Text(run.prompt).textSelection(.enabled)
                    Divider()
                    HStack { Text(instance.name).font(.headline); Spacer(); Text(run.displayedStatus).font(.caption).foregroundStyle(AgentXTheme.running) }
                    if let model = run.actualModel { Text(model + (run.runtimeCore == "pi-agent-core" ? " · Pi" : "")).font(.caption2).foregroundStyle(AgentXTheme.muted) }
                    AgentXRunConfigurationLabel(run: run)
                    if !run.response.isEmpty { Text(run.response).textSelection(.enabled) }
                    if let failure = run.failure { Text(failure).foregroundStyle(.orange) }
                    if !run.status.terminal {
                        HStack { ProgressView().controlSize(.small); Button("取消") { controller.cancel(run.id) }.disabled(run.status == .cancelling) }
                    }
                }
            }
            AgentXCard {
                TextEditor(text: Binding(get: { controller.drafts[instance.id] ?? "" }, set: { controller.drafts[instance.id] = $0 }))
                    .font(.body).frame(minHeight: 90, maxHeight: 180).scrollContentBackground(.hidden)
                    .accessibilityLabel("发送给 Agent 的消息")
                HStack {
                    Text("⌘ Return 发送 · \(controller.effectiveInstance(instance).model)").font(.caption).foregroundStyle(AgentXTheme.muted)
                    Spacer()
                    Button("发送", systemImage: "arrow.up") { controller.send(controller.drafts[instance.id] ?? "", instanceID: instance.id) }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                        .disabled(!controller.isLoaded || (controller.drafts[instance.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controller.isInstanceBusy(instance.id) || reviewNotice != nil)
                }
                if let reviewNotice { Text(reviewNotice).font(.caption).foregroundStyle(.orange) }
            }
        }
    }
}
