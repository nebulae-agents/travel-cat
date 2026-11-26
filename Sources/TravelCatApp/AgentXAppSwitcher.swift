import AppKit
import SwiftUI

/// Reused by the switcher and application management. Enabling grants permission only.
@MainActor
struct AgentXApplicationToggle: View {
    @ObservedObject var controller: AgentXController
    let app: AgentXApplication
    @State private var submitting = false
    @State private var failure: String?
    @State private var failureOperationID: UUID?
    private var action: (title: String, enabled: Bool, targetEnabled: Bool) {
        AgentXAppNavigationPolicy.stopAction(enabled: app.enabled, state: controller.applicationStopStates[app.id])
    }
    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            Button {
                submitting = true; failure = nil; failureOperationID = nil
                let target = action.targetEnabled
                Task { @MainActor in
                    defer { submitting = false }
                    do { try await controller.setApplicationEnabled(app.id, enabled: target) }
                    catch { failureOperationID = target ? nil : controller.stopOperations[app.id]?.id; failure = error.localizedDescription }
                }
            } label: { Text(action.title).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()) }
                .disabled(submitting || !action.enabled)
            if case .unverified(let reason) = controller.applicationStopStates[app.id] {
                Text("停止未确认：\(reason)").font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            } else if let failure = AgentXStopOperation.visibleFailure(failure, operationID: failureOperationID, current: controller.stopOperations[app.id]) { Text(failure).font(.caption).foregroundStyle(.orange) }
        }
    }
}

@MainActor
struct AgentXAppSwitcher: View {
    @ObservedObject var controller: AgentXController
    var travelPending = false
    var workbenchPending = 0
    @State private var query = ""
    @State private var selectedID: String?
    @State private var holdingStop = false
    @State private var confirmingStop = false
    @FocusState private var searching: Bool
    private var matches: [AgentXApplication] {
        controller.state.apps.filter { query.isEmpty || ($0.name + " " + $0.id).localizedCaseInsensitiveContains(query) }
    }
    private var contentMatches: [AgentXAppSearchResult] { query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : controller.applicationSearch(query) }
    private var running: Int { controller.state.runs.filter { !$0.status.terminal }.count }
    private var selectable: [AgentXApplication] { matches.filter { $0.enabled && (controller.state.singleAppID == nil || controller.state.singleAppID == $0.id) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("切换应用").font(.title2.bold()); Spacer(); Button { controller.shellOverlay = nil } label: { Text("关闭").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()) }.keyboardShortcut(.cancelAction) }
            TextField("搜索应用，或这个应用里的模块、成员、运行", text: $query).textFieldStyle(.roundedBorder).focused($searching).frame(minHeight: 44).accessibilityLabel("搜索应用或内容")
            if controller.singleMode {
                HStack {
                    Text("单应用模式：仅可进入当前指定应用").font(.caption)
                    Spacer()
                    Button("退出单应用模式") {
                        do { try controller.setSingleApp(nil) }
                        catch { controller.errorMessage = error.localizedDescription }
                    }
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        group("已启用", enabled: true)
                        group("已停用", enabled: false)
                        if !contentMatches.isEmpty {
                            Text("当前应用内容").font(.caption).foregroundStyle(AgentXTheme.muted)
                            ForEach(contentMatches) { result in
                                Button { _ = controller.openSearchResult(result) } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(result.title).lineLimit(2)
                                        Text(result.detail).font(.caption).foregroundStyle(AgentXTheme.muted)
                                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(8)
                                        .background(selectedID == result.id ? AgentXTheme.accent.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
                                }.buttonStyle(.plain).id(result.id)
                            }
                        }
                        if matches.isEmpty && contentMatches.isEmpty { Text("没有匹配结果").foregroundStyle(AgentXTheme.muted) }
                    }
                }.onChange(of: selectedID) { _, id in if let id { proxy.scrollTo(id) } }
            }
            Divider()
            Text("平台").font(.caption).foregroundStyle(AgentXTheme.muted)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading) {
                ForEach([AgentXPage.apps, .providers, .backups, .settings]) { page in
                    Button(page == .apps ? "管理应用" : page == .settings ? "平台设置" : page.title) {
                        controller.navigate(to: page); controller.shellOverlay = nil
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
            }
            Divider()
            HStack {
                Text("\(running) 个任务进行中").font(.caption)
                Spacer()
                if running > 0 {
                    Button("长按停止全部") { confirmingStop = true }
                        .frame(minHeight: 44).foregroundStyle(.red)
                        .onLongPressGesture(minimumDuration: 2, pressing: { holdingStop = $0 }) { controller.softStopAll() }
                        .help("长按 2 秒停止全部宿主文本运行；不含外部工作台")
                        .accessibilityLabel("停止全部宿主文本运行")
                        .confirmationDialog("请求停止全部宿主文本运行？", isPresented: $confirmingStop) {
                            Button("确认软停止", role: .destructive) { controller.softStopAll() }
                            Button("取消", role: .cancel) {}
                        } message: { Text("等待取消确认，不含外部工作台。也可长按此按钮 2 秒。") }
                }
            }
            if let error = controller.errorMessage { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            Text("↑↓ 选择 · Enter 进入 · Esc 关闭 · ⌘1–9 进入已启用应用。启用不会自动打开或运行。")
                .font(.caption).foregroundStyle(AgentXTheme.muted)
        }.padding(24).frame(width: 620, height: 660)
            .background(AgentXTheme.background).foregroundStyle(AgentXTheme.text)
            .background(AgentXPaletteKeys(move: move, choose: choose, close: { controller.shellOverlay = nil }))
            .onAppear { searching = true; selectedID = AgentXAppNavigationPolicy.initialSwitcherSelection(in: selectable, currentID: controller.selectedAppID) ?? contentMatches.first?.id }
            .onChange(of: query) { _, _ in selectedID = AgentXAppNavigationPolicy.initialSwitcherSelection(in: selectable, currentID: controller.selectedAppID) ?? contentMatches.first?.id }
            .onChange(of: selectableIDs) { _, ids in if !ids.contains(selectedID ?? "") { selectedID = ids.first } }
    }
    private func group(_ title: String, enabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.bold()).foregroundStyle(AgentXTheme.muted)
            ForEach(matches.filter { $0.enabled == enabled }) { app in
                HStack(alignment: .top, spacing: 12) {
                    AgentXApplicationIcon(app: app).padding(.top, 8)
                    Button {
                        if controller.selectApplication(app.id) { if controller.page.isPlatform { controller.returnToApplication() }; controller.shellOverlay = nil }
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                Text(app.name).font(.headline)
                                if controller.currentApp?.id == app.id {
                                    Text("当前").font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(AgentXTheme.running.opacity(0.16), in: Capsule())
                                }
                                if let index = controller.enabledApps.firstIndex(where: { $0.id == app.id }), index < 9 {
                                    Text("⌘\(index + 1)").font(.caption.monospaced()).foregroundStyle(AgentXTheme.muted)
                                }
                            }
                            Text(status(app)).font(.caption).foregroundStyle(AgentXTheme.muted)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(!selectable.contains(where: { $0.id == app.id }))
                    if !app.enabled { AgentXApplicationToggle(controller: controller, app: app).frame(maxWidth: 250, alignment: .trailing) }
                }.padding(8).background(selectedID == app.id ? AgentXTheme.accent.opacity(0.15) : AgentXTheme.surface, in: RoundedRectangle(cornerRadius: 10)).id(app.id)
            }
        }
    }
    private var selectableIDs: [String] { selectable.map(\.id) + contentMatches.map(\.id) }
    private func status(_ app: AgentXApplication) -> String {
        let runs = controller.state.runs.filter { $0.appID == app.id }
        if let run = runs.last(where: { !$0.status.terminal }) {
            return (controller.state.instances.first { $0.id == run.instanceID }?.name ?? "成员") + "正在回应"
        }
        if app.kind == .blackcat && travelPending { return "旅行提醒等你查看" }
        if app.kind == .workbench && workbenchPending > 0 { return "\(workbenchPending) 项工作台内容待处理" }
        let unread = runs.filter { $0.status.terminal && !$0.isRead }.count
        if unread > 0 { return "\(unread) 条运行结果等你查看" }
        if let last = runs.last { return "上次使用：" + last.startedAt.formatted(date: .abbreviated, time: .shortened) }
        return "尚未运行"
    }
    private func move(_ offset: Int) {
        guard !selectableIDs.isEmpty else { return }
        let current = selectableIDs.firstIndex(of: selectedID ?? "") ?? 0
        selectedID = selectableIDs[(current + offset + selectableIDs.count) % selectableIDs.count]
    }
    private func choose() {
        guard let selectedID else { return }
        if let result = contentMatches.first(where: { $0.id == selectedID }) { _ = controller.openSearchResult(result); return }
        if controller.selectApplication(selectedID) { if controller.page.isPlatform { controller.returnToApplication() }; controller.shellOverlay = nil }
    }
}

@MainActor
struct AgentXAppSearch: View {
    @ObservedObject var controller: AgentXController
    @State private var query = ""
    @State private var index = 0
    @FocusState private var searching: Bool
    private var results: [AgentXAppSearchResult] { controller.applicationSearch(query) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("搜索 · \(controller.currentApp?.name ?? "")").font(.title2.bold()); Spacer(); Button { controller.shellOverlay = nil } label: { Text("关闭").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()) }.keyboardShortcut(.cancelAction) }
            TextField("模块、成员名称 / 模型、运行提问 / 状态", text: $query).textFieldStyle(.roundedBorder).focused($searching)
            Text("仅当前应用；不搜索文件正文、回答内容或其他应用。")
                .font(.caption).foregroundStyle(AgentXTheme.muted)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { offset, result in
                            Button { _ = controller.openSearchResult(result) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(result.title).lineLimit(2)
                                    Text(result.detail).font(.caption).foregroundStyle(AgentXTheme.muted)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                    .background(index == offset ? AgentXTheme.accent.opacity(0.15) : AgentXTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain).id(offset)
                        }
                        if results.isEmpty { Text("没有匹配结果") }
                    }
                }.onChange(of: index) { _, value in proxy.scrollTo(value) }
            }
        }.padding(24).frame(width: 620, height: 500).background(AgentXTheme.background).foregroundStyle(AgentXTheme.text)
            .background(AgentXPaletteKeys(move: { offset in if !results.isEmpty { index = (index + offset + results.count) % results.count } }, choose: {
                if results.indices.contains(index) { _ = controller.openSearchResult(results[index]) }
            }, close: { controller.shellOverlay = nil }))
            .onAppear { searching = true }.onChange(of: query) { _, _ in index = 0 }
    }
}

/// A window-scoped monitor keeps arrow navigation working while the search field owns focus.
private struct AgentXPaletteKeys: NSViewRepresentable {
    let move: (Int) -> Void
    let choose: () -> Void
    let close: () -> Void
    final class Coordinator {
        var monitor: Any?
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        if let monitor = context.coordinator.monitor { NSEvent.removeMonitor(monitor) }
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak view] event in
            guard let window = view?.window, event.window === window,
                  let action = AgentXPaletteKeyPolicy.action(keyCode: event.keyCode, modifiers: event.modifierFlags, firstResponder: window.firstResponder) else { return event }
            switch action {
            case .move(let offset): move(offset)
            case .choose: choose()
            case .close: close()
            }
            return nil
        }
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor); coordinator.monitor = nil }
    }
}

@MainActor
enum AgentXPaletteKeyPolicy {
    enum Action: Equatable { case move(Int), choose, close }
    static func action(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, firstResponder: NSResponder?) -> Action? {
        guard modifiers.intersection([.command, .control, .option]).isEmpty else { return nil }
        // Candidate navigation and commit/cancel belong to the input method until composition ends.
        guard (firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return nil }
        switch keyCode {
        case 125: return .move(1)
        case 126: return .move(-1)
        case 36, 76: return .choose
        case 53: return .close
        default: return nil
        }
    }
}
