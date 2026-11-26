import SwiftUI

@MainActor
struct AgentXAppHeader: View {
    @ObservedObject var controller: AgentXController
    let pending: Int
    private var settings: Bool { !controller.page.isPlatform && controller.appArea == .backstage }
    var body: some View {
        HStack(spacing: 12) {
            if controller.page.isPlatform || settings {
                Button {
                    if controller.page.isPlatform { controller.returnToApplication() } else { controller.openFrontend() }
                } label: {
                    Label("回到 \(controller.currentApp?.name ?? "应用")", systemImage: "chevron.left").frame(minHeight: 44)
                }.buttonStyle(.plain).disabled(controller.currentApp == nil)
            } else {
                Button { controller.shellOverlay = .switcher } label: {
                    HStack(spacing: 8) {
                        AgentXApplicationIcon(app: controller.currentApp)
                        Text(controller.currentApp?.name ?? "选择应用").font(.headline).lineLimit(1)
                        Image(systemName: "chevron.down").font(.caption)
                    }.frame(minHeight: 44)
                }.buttonStyle(.plain).help("切换应用 ⌘K").accessibilityLabel("切换应用")
            }
            Spacer(minLength: 0)
            if settings {
                AgentXSettingsDraftActions(controller: controller).id(controller.selectedAppID)
            } else if !controller.page.isPlatform {
                if let run = controller.currentRuns.last(where: { !$0.status.terminal }) {
                    HStack(spacing: 8) {
                        AgentXStopStatusButton(controller: controller, appID: run.appID,
                            compactTitle: controller.state.instances.first(where: { $0.id == run.instanceID }).map { $0.name + "正在回应" } ?? "任务进行中")
                        Button("停止") { controller.cancel(run.id) }.frame(minHeight: 44)
                            .disabled(run.status == .cancelling).help("停止当前回应")
                    }.padding(.horizontal, 10).background(AgentXTheme.running.opacity(0.1), in: Capsule())
                }
                icon("历史", symbol: "clock.arrow.circlepath") { controller.navigate(to: .runs) }
                icon("设置", symbol: "slider.horizontal.3", help: "设置 ⌘,") { controller.openBackstage() }
            }
        }.padding(.horizontal, 20).padding(.vertical, 8)
    }
    private func icon(_ title: String, symbol: String, help: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 44, height: 44) }
            .buttonStyle(.plain).help(help ?? title).accessibilityLabel(title).disabled(controller.currentApp == nil)
    }
}

@MainActor
struct AgentXSettingsNavigation: View {
    @ObservedObject var controller: AgentXController
    @State private var more = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("设置").font(.title3.bold()).padding(12)
            ForEach([AgentXPage.members, .sceneRules, .characters]) { route($0) }
            Button { more.toggle() } label: {
                HStack { Text("更多"); Spacer(); Image(systemName: more ? "chevron.up" : "chevron.down") }.frame(minHeight: 44)
            }.buttonStyle(.plain).padding(.horizontal, 12).accessibilityLabel(more ? "收起更多设置" : "展开更多设置")
            if more {
                ForEach([AgentXPage.workflows, .appModels, .runs, .appFiles, .appSettings]) { route($0) }
            }
            Spacer()
        }.padding(12).frame(width: 200).background(AgentXTheme.sidebar)
    }
    private func route(_ page: AgentXPage) -> some View {
        Button { controller.navigate(to: page) } label: {
            Text(page.title).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.horizontal, 12)
                .background(controller.page == page ? AgentXTheme.accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
    }
}

@MainActor
struct AgentXShellShortcuts: View {
    @ObservedObject var controller: AgentXController
    var body: some View {
        Group {
            Button("切换应用") { controller.shellOverlay = .switcher }.keyboardShortcut("k", modifiers: .command)
            Button("搜索应用与内容") { controller.shellOverlay = .switcher }.keyboardShortcut("p", modifiers: .command)
            Button("应用设置") { controller.openBackstage() }.keyboardShortcut(",", modifiers: .command)
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
