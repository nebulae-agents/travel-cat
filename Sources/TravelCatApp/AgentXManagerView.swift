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
    var openJourney: () -> Void = {}
    var openAlbum: () -> Void = {}
    var openTravelPrompt: () -> Void = {}
    var travelPending = false
    var workbenchPending = 0
    var openWorkbench: () -> Void = {}
    var workbenchContent: (() -> AnyView)? = nil
    @State private var editor: AgentXEditor?
    @State private var editingProvider: AgentXProvider?
    @State private var editingDefinition: AgentXDefinition?
    @State private var editingInstance: AgentXInstance?
    @State private var migrationMessage: String?

    var body: some View {
        HStack(spacing: 0) {
            if !controller.singleMode { if controller.page == .chat { frontRail } else { sidebar } }
            VStack(spacing: 0) {
                header
                Divider().overlay(AgentXTheme.border)
                if let error = controller.errorMessage {
                    HStack {
                        Label(error, systemImage: "exclamationmark.triangle").textSelection(.enabled)
                        Spacer()
                        if controller.isLoaded { Button("关闭提示") { controller.errorMessage = nil } }
                    }.padding(12).background(Color.red.opacity(0.12))
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) { content }
                        .padding(28).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .background(AgentXTheme.background).foregroundStyle(AgentXTheme.text)
        .tint(AgentXTheme.accent)
        .frame(minWidth: 960, minHeight: 640)
        .sheet(item: $editor) { kind in AgentXEditorView(controller: controller, kind: kind, existingProvider: editingProvider, existingDefinition: editingDefinition, existingInstance: editingInstance) }
    }

    private var frontRail: some View {
        VStack(spacing: 12) {
            railButton(.overview)
            Divider()
            railButton(.chat)
            railButton(.instances)
            railButton(.runs)
            railButton(.apps)
            Spacer()
            railButton(.inbox)
            railButton(.configuration)
        }.padding(.vertical, 16).frame(width: 64).frame(maxHeight: .infinity).background(AgentXTheme.sidebar)
    }
    private func railButton(_ page: AgentXPage) -> some View {
        Button { controller.page = page } label: {
            Image(systemName: page.icon).font(.system(size: 20)).frame(width: 44, height: 44)
                .background(controller.page == page ? AgentXTheme.accent.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).help(page.title).accessibilityLabel(page.title)
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill").font(.title2).foregroundStyle(AgentXTheme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("AgentX Manager").font(.headline)
                    Text("本地优先 · 原生工作台").font(.caption).foregroundStyle(AgentXTheme.muted)
                }
            }.padding(.vertical, 18)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    navigation(.overview)
                    sectionLabel("应用层")
                    navigation(.apps)
                    Picker("当前应用", selection: $controller.selectedAppID) {
                        ForEach(controller.state.apps) { app in Text(app.name).tag(app.id) }
                    }.labelsHidden().padding(.vertical, 8).accessibilityLabel("当前应用")
                    navigation(.chat)
                    navigation(.configuration)
                    navigation(.runs)
                    sectionLabel("基石")
                    navigation(.providers)
                    navigation(.instances)
                    navigation(.definitions)
                    sectionLabel("平台")
                    navigation(.inbox)
                    navigation(.settings)
                }
            }
            Divider()
            Label("\(controller.state.activeCount) 个运行中", systemImage: "waveform.path")
                .font(.caption).foregroundStyle(AgentXTheme.running).padding(.vertical, 6)
            Text("配置、记忆与应用各自独立").font(.caption2).foregroundStyle(AgentXTheme.muted)
        }.padding(16).frame(width: 232).frame(maxHeight: .infinity)
            .background(AgentXTheme.sidebar)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(AgentXTheme.muted).padding(.top, 18).padding(.leading, 10)
    }
    private func navigation(_ page: AgentXPage) -> some View {
        Button { controller.page = page } label: {
            HStack {
                Label(page.title, systemImage: page.icon)
                Spacer()
                if page == .inbox && controller.state.unreadCount + (travelPending ? 1 : 0) + workbenchPending > 0 {
                    Text("\(controller.state.unreadCount + (travelPending ? 1 : 0) + workbenchPending)").font(.caption.monospacedDigit())
                        .padding(.horizontal, 7).padding(.vertical, 3).background(AgentXTheme.accent.opacity(0.2), in: Capsule())
                }
            }.frame(minHeight: 44).padding(.horizontal, 10).contentShape(Rectangle())
                .background(controller.page == page ? AgentXTheme.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(controller.page == page ? AgentXTheme.accent : AgentXTheme.muted)
        }.buttonStyle(.plain)
    }
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text(controller.page.title).font(.system(size: 22, weight: .bold))
                Text(controller.page == .chat || controller.page == .runs ? controller.currentApp?.name ?? "选择应用" : "应用 ← Agent 实例 ← 模型服务")
                    .font(.caption).foregroundStyle(AgentXTheme.muted)
            }
            Spacer()
            if controller.singleMode {
                Button("完整平台", systemImage: "sidebar.left") { controller.singleMode = false }
            }
            Button { controller.page = .inbox } label: { Label("待处理 \(controller.state.unreadCount + (travelPending ? 1 : 0) + workbenchPending)", systemImage: "bell") }
                .help("打开待处理收件箱")
        }.padding(.horizontal, 28).padding(.vertical, 20)
    }

    @ViewBuilder private var content: some View {
        switch controller.page {
        case .overview: overview
        case .apps: applications
        case .providers: providers
        case .definitions: definitions
        case .instances: instances
        case .configuration: AgentXAppConfigurationView(controller: controller)
        case .chat: chat
        case .runs: runList(controller.state.runs.filter { $0.appID == controller.selectedAppID }.reversed(), inbox: false)
        case .inbox:
            if workbenchPending > 0 {
                HStack {
                    Label("Agent 工作台有 \(workbenchPending) 项待处理", systemImage: "tray.full")
                    Spacer()
                    Button("打开工作台", action: openWorkbench)
                }.padding().background(AgentXTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            }
            if travelPending {
                AgentXCard {
                    Label("BlackCat · 旅行提醒", systemImage: "pawprint.fill").font(.headline)
                    Text("打开对应的明信片或旅程并确认此条提醒；如果存储异常，提醒会保留。").foregroundStyle(AgentXTheme.muted)
                    Button("查看并确认提醒", action: openTravelPrompt)
                }
            }
            runList(controller.state.runs.filter { $0.status.terminal && !$0.isRead }.reversed(), inbox: true)
        case .settings: settings
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
                    Button("配置模型服务") { controller.page = .providers }.buttonStyle(.borderedProminent)
                    Button("查看所有应用") { controller.page = .apps }
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
            Text("原生内嵌 · 旅行与陪伴 · 平台管理入口").foregroundStyle(AgentXTheme.muted)
            HStack {
                Button("当前旅程", action: openJourney).buttonStyle(.borderedProminent)
                Button("旅行册", action: openAlbum)
                Spacer()
                Button("入口设置") { controller.page = .settings }
            }
        }
    }
    private var applications: some View {
        Group {
            actionHeader("应用空间", button: "新建应用", kind: .app)
            blackCatCard
            ForEach(controller.state.apps.filter { $0.kind != .blackcat }) { app in
                AgentXCard {
                    Label(app.name, systemImage: "bubble.left.and.bubble.right").font(.headline)
                    Text("\(app.kind == .workbench ? "Agent 工作台" : "应用前台") · \(controller.state.instances.filter { $0.appID == app.id }.count) 个实例").foregroundStyle(AgentXTheme.muted)
                    HStack {
                        Button("进入前台") { controller.openApp(app.id) }.buttonStyle(.borderedProminent)
                        Button("配置台") { controller.selectedAppID = app.id; controller.page = .configuration }
                    }
                }
            }
        }
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
                    Text(provider.models.joined(separator: "  ·  ")).foregroundStyle(AgentXTheme.running)
                    Text("\(provider.serviceProtocol.title) · \(controller.state.instances.filter { $0.providerID == provider.id }.count) 个实例引用").font(.caption).foregroundStyle(AgentXTheme.muted)
                    Button("编辑配置") { editingProvider = provider; editingDefinition = nil; editingInstance = nil; editor = .provider }
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
                    Button("编辑定义 / 发布") { editingProvider = nil; editingInstance = nil; editingDefinition = definition; editor = .definition }
                }
            }
        }
    }
    private var instances: some View {
        Group {
            if controller.currentApp?.kind == .workbench { workbenchModule }
            else {
                actionHeader("\(controller.currentApp?.name ?? "应用") · 实例", button: "创建实例", kind: .instance)
                if controller.currentInstances.isEmpty { empty("此应用还没有实例", detail: "选择定义与模型服务，将角色加入应用。", action: "创建实例", kind: .instance) }
                ForEach(controller.currentInstances) { instance in
                    AgentXCard {
                        HStack { Label(instance.name, systemImage: "cpu").font(.headline); Spacer(); Text("原生对话").font(.caption).foregroundStyle(AgentXTheme.running) }
                        Text(instance.model).font(.system(.body, design: .monospaced))
                        Text("定义：\(controller.state.definitions.first { $0.id == instance.definitionID }?.name ?? "未知") · 独立记忆 / 工作目录 / 配置 / 凭据引用").foregroundStyle(AgentXTheme.muted).font(.caption)
                        HStack {
                            Button("开始对话") { controller.selectedInstanceID = instance.id; controller.page = .chat }.buttonStyle(.borderedProminent)
                            Button("编辑实例") { editingProvider = nil; editingDefinition = nil; editingInstance = instance; editor = .instance }
                                .disabled(controller.state.runs.contains { $0.instanceID == instance.id && !$0.status.terminal })
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
        if controller.currentApp?.kind == .workbench {
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
        } else {
            if controller.currentApp?.kind == .blackcat { blackCatCard }
            if let instance = controller.currentInstance {
                AgentXChatView(controller: controller, instance: instance)
            } else {
                empty("为应用添加一个对话 Agent", detail: "先配置模型服务与定义，然后创建实例。", action: "创建实例", kind: .instance)
            }
        }
    }
    private func runList(_ runs: [AgentXRun], inbox: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(inbox ? "需要你关注的结果" : "真实运行与结果").font(.headline)
                Spacer()
                if inbox && !runs.isEmpty { Button("全部标记已读") { perform { try controller.markAllRead() } } }
            }
            if runs.isEmpty {
                AgentXCard {
                    Label(inbox ? "暂时没有待处理事项" : "还没有运行记录", systemImage: inbox ? "checkmark.circle" : "clock")
                    Button("进入应用前台") { controller.page = .chat }
                }
            }
            ForEach(runs) { run in
                AgentXCard {
                    HStack {
                        Text(controller.state.apps.first { $0.id == run.appID }?.name ?? run.appID).font(.headline)
                        Spacer()
                        Text(run.status.label).foregroundStyle(run.status == .failed ? .red : AgentXTheme.running)
                    }
                    Text(run.prompt).lineLimit(3).textSelection(.enabled)
                    if let failure = run.failure { Text(failure).foregroundStyle(.orange) }
                    Text(run.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(AgentXTheme.muted)
                    HStack {
                        Button("查看对话") { controller.selectedAppID = run.appID; controller.selectedInstanceID = run.instanceID; controller.page = .chat }
                        if run.status.terminal && !run.isRead { Button("标记已读") { perform { try controller.markRead(run.id) } } }
                        if !run.status.terminal { Button("取消运行") { controller.cancel(run.id) }.disabled(run.status == .cancelling) }
                    }
                }
            }
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
                    Text("完整管理平台").tag("")
                    ForEach(controller.state.apps) { app in Text("单应用 · \(app.name)").tag(app.id) }
                }
                Text("单应用模式隐藏侧栏，可随时返回完整平台。BlackCat 显示开关独立生效。").font(.caption).foregroundStyle(AgentXTheme.muted)
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
    private func actionHeader(_ text: String, button: String, kind: AgentXEditor) -> some View {
        HStack { Text(text).font(.headline); Spacer(); Button(button, systemImage: "plus") { editingProvider = nil; editingDefinition = nil; editingInstance = nil; editor = kind }.buttonStyle(.borderedProminent).disabled(!controller.isLoaded) }
    }
    private func empty(_ title: String, detail: String, action: String, kind: AgentXEditor) -> some View {
        AgentXCard {
            Text(title).font(.title3.bold())
            Text(detail).foregroundStyle(AgentXTheme.muted)
            Button(action) { editingProvider = nil; editingDefinition = nil; editingInstance = nil; editor = kind }.buttonStyle(.borderedProminent).disabled(!controller.isLoaded)
        }
    }
    private func perform(_ operation: () throws -> Void) { do { try operation() } catch { controller.errorMessage = error.localizedDescription } }
}

@MainActor
private struct AgentXChatView: View {
    @ObservedObject var controller: AgentXController
    let instance: AgentXInstance
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Picker("对话实例", selection: Binding(get: { instance.id }, set: { controller.selectedInstanceID = $0 })) {
                ForEach(controller.currentInstances) { Text($0.name).tag($0.id) }
            }
            ForEach(controller.state.runs.filter { $0.instanceID == instance.id }) { run in
                AgentXCard {
                    Text("你").font(.caption).foregroundStyle(AgentXTheme.accent)
                    Text(run.prompt).textSelection(.enabled)
                    Divider()
                    HStack { Text(instance.name).font(.headline); Spacer(); Text(run.status.label).font(.caption).foregroundStyle(AgentXTheme.running) }
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
                    Text("\(instance.model) · 纯文本 · 不执行工具").font(.caption).foregroundStyle(AgentXTheme.muted)
                    Spacer()
                    Button("发送", systemImage: "arrow.up") { controller.send(controller.drafts[instance.id] ?? "", instanceID: instance.id) }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                        .disabled(!controller.isLoaded || (controller.drafts[instance.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controller.state.runs.contains { $0.instanceID == instance.id && !$0.status.terminal })
                }
            }
        }
    }
}
