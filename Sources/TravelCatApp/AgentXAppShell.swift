import SwiftUI

/// The narrow rail separates application work (top) from platform administration (bottom).
@MainActor
struct AgentXAppRail: View {
    @ObservedObject var controller: AgentXController
    @State private var holdingStop = false
    @State private var confirmingStop = false
    var body: some View {
        VStack(spacing: 8) {
            route(.overview)
            route(.chat)
            route(.members)
            route(.inbox)
            route(.appFiles)
            Spacer(minLength: 20)
            route(.apps)
            Menu {
                ForEach([AgentXPage.platformOverview, .providers, .definitions, .instances, .backups, .governance]) { page in
                    Button(page.title, systemImage: page.icon) { controller.navigate(to: page) }
                }
            } label: { Image(systemName: "building.2").frame(width: 36, height: 36) }
                .menuStyle(.borderlessButton).help("平台基石").accessibilityLabel("平台基石")
            Button { confirmingStop = true } label: {
                Image(systemName: holdingStop ? "stop.circle.fill" : "stop.circle")
            }.buttonStyle(.plain)
                .foregroundStyle(.red).frame(width: 40, height: 40).contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 2, pressing: { holdingStop = $0 }) { controller.softStopAll() }
                .help("长按 2 秒停止全部宿主文本运行；不含外部工作台")
                .accessibilityLabel("停止全部宿主文本运行")
                .confirmationDialog("请求停止全部宿主文本运行？", isPresented: $confirmingStop) {
                    Button("确认软停止", role: .destructive) { controller.softStopAll() }
                    Button("取消", role: .cancel) {}
                } message: { Text("等待取消确认，不含外部工作台。也可长按此按钮 2 秒。") }
            route(.settings)
        }.padding(.vertical, 12).frame(width: 48).background(AgentXTheme.sidebar)
    }
    private func route(_ page: AgentXPage) -> some View {
        Button {
            if page == .chat { controller.openFrontend() } else { controller.navigate(to: page) }
        } label: {
            Image(systemName: page.icon).frame(width: 40, height: 40)

        }.buttonStyle(.plain).help(page.title).accessibilityLabel(page.title)
            .disabled(!page.isPlatform && controller.currentApp == nil)
    }
}

@MainActor
struct AgentXAppHeader: View {
    @ObservedObject var controller: AgentXController
    let pending: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button { controller.shellOverlay = .switcher } label: {
                    HStack(spacing: 8) {
                        AgentXApplicationIcon(app: controller.currentApp)
                        Text(controller.currentApp?.name ?? "选择应用").font(.headline).lineLimit(1)
                        Image(systemName: "chevron.down").font(.caption)
                    }
                }.buttonStyle(.plain).help("切换应用 ⌘K").accessibilityLabel("切换应用")
                HStack(spacing: 4) {
                    Button("前台") { controller.openFrontend() }
                        .tint(controller.appArea == .frontend && !controller.page.isPlatform ? AgentXTheme.accent : .secondary)
                    Button("后台") { controller.openBackstage() }
                        .tint(controller.appArea == .backstage && !controller.page.isPlatform ? AgentXTheme.accent : .secondary)
                }.buttonStyle(.bordered).fixedSize().disabled(controller.currentApp == nil)
                if controller.page.isPlatform {
                    Text("› 平台 › \(controller.page.title)").foregroundStyle(AgentXTheme.muted).lineLimit(1)
                    Button("返回 \(controller.currentApp?.name ?? "应用")") { controller.returnToApplication() }.disabled(controller.currentApp == nil)
                } else if controller.currentApp != nil {
                    Text("\(controller.appArea == .frontend ? "前台" : "后台") / \(controller.page.title)")
                        .lineLimit(1).truncationMode(.middle)
                        .help("\(controller.currentApp?.name ?? "") / \(controller.appArea == .frontend ? "前台" : "后台") / \(controller.page.title)")
                        .accessibilityLabel("\(controller.currentApp?.name ?? "") / \(controller.appArea == .frontend ? "前台" : "后台") / \(controller.page.title)")
                    if let app = controller.currentApp {
                        AgentXStopStatusButton(controller: controller, appID: app.id)
                    }
                }
                Spacer(minLength: 0)
                Button { controller.shellOverlay = .search } label: { Image(systemName: "magnifyingglass").accessibilityLabel("搜索当前应用") }
                    .help("搜索当前应用的模块、成员、运行 ⌘P").disabled(controller.currentApp == nil)
                Button { controller.navigate(to: .inbox) } label: { Label("\(pending)", systemImage: pending > 0 ? "bell.badge" : "bell") }
                    .help("当前应用待处理").disabled(controller.currentApp == nil)
                Menu {
                    ForEach([AgentXPage.configuration, .sceneRules, .characters, .workflows, .members, .appModels, .runs, .appFiles, .appSettings]) { page in
                        Button(page.title, systemImage: page.icon) { controller.navigate(to: page) }
                    }
                    Divider()
                    Button("简洁皮肤") { attempt { try controller.setFrontSkin(.simple) } }
                    Button("沉浸皮肤") { attempt { try controller.setFrontSkin(.immersive) } }
                } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
                    .menuStyle(.borderlessButton).fixedSize().help("后台与应用菜单").accessibilityLabel("后台与应用菜单")
                    .disabled(controller.currentApp == nil)
            }
            if !controller.page.isPlatform, let app = controller.currentApp {
                if controller.appArea == .frontend {
                    AgentXModuleTabs(controller: controller, appID: app.id).id(app.id)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach([AgentXPage.configuration, .members, .sceneRules, .characters, .workflows, .runs, .appFiles, .appSettings]) { page in
                                Button(page.title) { controller.navigate(to: page) }
                                    .buttonStyle(.bordered)
                                    .tint(controller.page == page ? AgentXTheme.accent : .secondary)
                            }
                        }
                    }
                }
            }
        }.padding(.horizontal, 20).padding(.vertical, 12)
    }
    private func attempt(_ body: () throws -> Void) { do { try body() } catch { controller.errorMessage = error.localizedDescription } }
}

@MainActor
private struct AgentXModuleTabs: View {
    @ObservedObject var controller: AgentXController
    @ObservedObject var session: AgentXFrontendSession
    init(controller: AgentXController, appID: String) {
        self.controller = controller; session = controller.frontendSession(appID: appID)
    }
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(controller.currentModules) { module in
                    Button(module.title) { controller.selectModule(module.id) }
                        .buttonStyle(.plain).padding(.horizontal, 12).padding(.vertical, 7)
                        .background((session.selectedModule == module.id || (session.selectedModule.isEmpty && controller.currentModules.first?.id == module.id)) && controller.page == module.page ? AgentXTheme.accent.opacity(0.16) : .clear, in: Capsule())
                }
            }
        }
    }
}

@MainActor
struct AgentXShellShortcuts: View {
    @ObservedObject var controller: AgentXController
    var body: some View {
        Group {
            Button("切换应用") { controller.shellOverlay = .switcher }.keyboardShortcut("k", modifiers: .command)
            Button("搜索当前应用") { if controller.currentApp != nil { controller.shellOverlay = .search } }.keyboardShortcut("p", modifiers: .command)
            ForEach(0..<9) { index in
                Button("切换应用 \(index + 1)") { controller.selectApplicationShortcut(index) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
        }.frame(width: 0, height: 0).clipped().accessibilityHidden(true)
    }
}

/// Manifest icons are literal text/emoji only; never resource paths or executable content.
struct AgentXApplicationIcon: View {
    let app: AgentXApplication?
    private var symbol: String {
        switch app?.kind {
        case .blackcat: "pawprint.fill"
        case .workbench: "terminal"
        case .chat: "bubble.left.and.bubble.right"
        default: "square.stack.3d.up"
        }
    }
    var body: some View {
        Group {
            if let icon = app?.declaredIcon, !icon.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(icon).lineLimit(1).minimumScaleFactor(0.5)
            } else { Image(systemName: symbol) }
        }.font(.title3).frame(width: 26, height: 26).clipped().accessibilityHidden(true)
    }
}
