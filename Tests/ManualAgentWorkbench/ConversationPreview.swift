// Production workbench, deterministic conversation metadata, temporary encrypted storage.
// No account, Keychain, sidecar, network, or user state.
import AppKit
import SwiftUI

extension Bundle { static var module: Bundle { .main } }

@MainActor private final class ConversationPreviewCredentials: TravelServiceCredentialStoring {
    var values: [String: String] = [:]
    func read(id: String) throws -> String? { values[id] }
    func save(_ secret: String?, id: String) throws { values[id] = secret }
}
@MainActor private final class ConversationPreviewRuntime: AgentRuntimeClient {
    var onEvent: (([String: Any]) -> Void)?
    var onExit: (() -> Void)?
    func launch(python: String) throws { throw WorkbenchFailure("离线会话管理夹具不启动运行时。") }
    func shutdown() {}
    func request(_ method: String, _ params: [String: Any], timeout: UInt64) async throws -> [String: Any] {
        guard method == "native_background_status" else { throw WorkbenchFailure("离线夹具不执行会话控制或模型调用。") }
        return ["threadId": "fixture-thread", "count": 0, "itemIds": []]
    }
}
@MainActor private struct ConversationPreviewSurface: View {
    @ObservedObject var model: AgentWorkbenchModel
    let archivedID: UUID
    let savedStore: WorkbenchStore
    let resize: (NSSize) -> Void
    let openMailbox: (UUID) -> Void
    let lateReply: () -> Void
    @State private var failing = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("1000 × 740") { resize(.init(width: 1000, height: 740)) }
                Button("760 × 600") { resize(.init(width: 760, height: 600)) }
                Button("待确认重现") {
                    model.permissions = [.init(id: "fixture-approval", taskID: archivedID, title: "离线待确认夹具", detail: "固定预览内容，不会执行操作。", options: [])]
                    model.mutate(archivedID) { $0.status = .awaitingPermission }
                    model.openConversation(archivedID)
                }
                Button("从邮筒打开") {
                    if let i = model.state.tasks.firstIndex(where: { $0.id == archivedID }) {
                        model.state.tasks[i].unread = true
                        openMailbox(archivedID)
                    }
                }
                Button("迟到回复重现", action: lateReply)
                Toggle("模拟保存失败", isOn: $failing).toggleStyle(.checkbox)
                    .onChange(of: failing) { _, value in model.store = value ? WorkbenchStore(root: URL(fileURLWithPath: "/dev/null")) : savedStore }
            }.controlSize(.small).padding(8)
            Divider()
            AgentWorkbenchView(model: model)
        }
    }
}

@main @MainActor struct ConversationPreview {
    static func main() throws {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("travelcat-conversation-preview-\(UUID().uuidString)")
        let runtime = ConversationPreviewRuntime()
        let model = AgentWorkbenchModel(root: root, credentials: ConversationPreviewCredentials(), client: runtime)
        let instance = WorkbenchInstance(name: "会话管理（离线）", image: "fixture", command: ["fixture"])
        func task(_ title: String, offset: TimeInterval, archived: Bool = false) -> WorkbenchTask {
            var task = WorkbenchTask(instanceID: instance.id, title: title)
            task.status = .completed; task.sessionID = "fixture-thread"; task.createdAt = Date(timeIntervalSince1970: 1_000 + offset)
            task.nativeState = NativeTaskState(threadID: "fixture-thread", turnID: "fixture-turn", connection: .connected)
            task.nativeState?.recordTurnStatus("fixture-turn", status: "completed")
            task.messages = [.init(role: "user", text: "保留原始问题🙂\r\n本地 literal [a-z].* 搜索。"), .init(role: "assistant", text: "# 本地会话管理\n\n搜索 Hello 或中文、重命名、置顶、归档和恢复；草稿独立保留。")]
            if archived { task.archivedAt = Date(timeIntervalSince1970: 2_000) }
            return task
        }
        var first = task("中文本地搜索 [a-z].* · 原始标题", offset: 1)
        first.pinnedAt = Date(timeIntervalSince1970: 1_500)
        var second = task("稳定置顶 Hello", offset: 2)
        second.pinnedAt = Date(timeIntervalSince1970: 1_400)
        let archived = task("已归档 · 草稿保留与恢复", offset: 3, archived: true)
        var legacy = WorkbenchTask(instanceID: instance.id, title: "旧 ACP 记录 · 清理证据缺失")
        legacy.status = .completed; legacy.createdAt = Date(timeIntervalSince1970: 900)
        model.state.instances = [instance]; model.state.tasks = [legacy, archived, second, first]
        model.liveTasks = [first.id, second.id, archived.id]
        model.updateDraft(.task(archived.id)) { $0.text = "归档中也保留的草稿🙂" }
        model.openConversation(first.id); model.persist()
        let savedStore = model.store
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 740), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Travel Cat · 会话管理验收（离线夹具）"; window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua); window.contentMinSize = NSSize(width: 760, height: 600)
        let launcher = AgentLauncherController(model: model) { window.makeKeyAndOrderFront(nil) }
        let host = NSHostingView(rootView: ConversationPreviewSurface(model: model, archivedID: archived.id, savedStore: savedStore,
            resize: { window.setContentSize($0) }, openMailbox: { launcher.openEntry("task-\($0)") }, lateReply: {
                runtime.onEvent?(["event": "native", "taskId": archived.id.uuidString, "instanceId": instance.id.uuidString,
                    "data": ["method": "item/agentMessage/delta", "params": ["threadId": "fixture-thread", "turnId": "fixture-turn", "itemId": "late-fixture-reply", "delta": "迟到的离线回复🙂\n"]]])
            }))
        host.sizingOptions = []; window.contentView = host
        window.center(); window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in MainActor.assumeIsolated { app.stop(nil) } }
        app.run()
        NotificationCenter.default.removeObserver(observer); launcher.hide(); model.store = savedStore; model.shutdown()
        try? FileManager.default.removeItem(at: root)
    }
}
