// Production conversation and Markdown views; deterministic in-memory streaming only.
// No account, Keychain, network, sidecar, real workspace or user data.
import AppKit
import SwiftUI

extension Bundle { static var module: Bundle { .main } }

@MainActor private final class MarkdownPreviewCredentials: TravelServiceCredentialStoring {
    var values: [String: String] = [:]
    func read(id: String) throws -> String? { values[id] }
    func save(_ secret: String?, id: String) throws { values[id] = secret }
}
@MainActor private final class MarkdownPreviewRuntime: AgentRuntimeClient {
    var onEvent: (([String: Any]) -> Void)?
    var onExit: (() -> Void)?
    func launch(python: String) throws { throw WorkbenchFailure("离线阅读夹具不启动运行时。") }
    func request(_ method: String, _ params: [String: Any], timeout: UInt64) async throws -> [String: Any] {
        guard method == "permission" else { throw WorkbenchFailure("此夹具只模拟一次审批回读。") }
        return ["accepted": true]
    }
    func shutdown() {}
}
@MainActor private struct MarkdownPreviewSurface: View {
    @ObservedObject var model: AgentWorkbenchModel
    @StateObject private var presentation = AgentWorkbenchPresentation()
    @State private var streaming = false
    @State private var sequence = 0
    let resize: (NSSize) -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("1000 × 740") { resize(NSSize(width: 1000, height: 740)) }
                Button("760 × 600") { resize(NSSize(width: 760, height: 600)) }
                Button(streaming ? "暂停流式夹具" : "追加流式夹具") { streaming.toggle() }
                Button("超限原文") {
                    model.state.tasks[0].messages.append(.init(role: "assistant", text: String(repeating: "超限原文🙂\r\n", count: 12_000)))
                }
            }.controlSize(.small).padding(8)
            Divider()
            AgentConversationView(model: model, presentation: presentation, task: model.state.tasks[0],
                artifacts: {}, audit: {}, handoff: { _ in }, settings: {})
        }.workbenchSurface().task(id: streaming) {
            guard streaming else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                sequence += 1
                // Stable message identity; a raw sheet opened earlier must keep its snapshot/selection.
                model.state.tasks[0].messages[3].text += "追加 \(sequence) · 🙂\r\n"
            }
        }
    }
}

@main @MainActor struct MarkdownPreview {
    static func main() throws {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("travelcat-markdown-preview-\(UUID().uuidString)")
        let model = AgentWorkbenchModel(root: root, credentials: MarkdownPreviewCredentials(), client: MarkdownPreviewRuntime())
        let instance = WorkbenchInstance(name: "Markdown 阅读（离线）", image: "fixture", command: ["fixture"])
        var task = WorkbenchTask(instanceID: instance.id, title: "Markdown 阅读与原文选择验收")
        task.status = .awaitingPermission
        task.messages = [
            .init(role: "user", text: "保持原始内容，查看列表、长代码与流式原文。"),
            .init(role: "assistant", text: "中英列表 Intro\n7. 第一项 first\n   继续说明 continuation\n9) 保留编号 second\n  - 嵌套 nested\n\t+ tab indent\n2026.10.24 与 -42 保持普通文本。\n"),
            .init(role: "assistant", text: "````swift\r\n\r\n\tlet emoji = \"🙂\"  \r\n" + String(repeating: "long_code_", count: 30) + "\r\n" + (1...24).map { "\tline_\($0)\r\n" }.joined() + "```\r\n\r\n````\r\n"),
            .init(role: "assistant", text: "~~~text\r\n打开原文后再追加流式内容，选择应保持。🙂\r\n")
        ]
        model.state.instances = [instance]; model.state.tasks = [task]
        model.permissions = [.init(id: "offline-reading-approval", taskID: task.id, title: "离线审批保持可见", detail: "这是阅读夹具中的固定审批；不会执行命令。", options: [.init(id: "deny", title: "拒绝夹具操作", kind: "reject_once")])]
        model.liveTasks.insert(task.id)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 740), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Travel Cat · Markdown 阅读验收（离线夹具）"; window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentMinSize = NSSize(width: 760, height: 600)
        let host = NSHostingView(rootView: MarkdownPreviewSurface(model: model, resize: { window.setContentSize($0) }))
        host.sizingOptions = []; window.contentView = host
        window.center(); window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in MainActor.assumeIsolated { app.stop(nil) } }
        app.run()
        NotificationCenter.default.removeObserver(observer); model.shutdown(); try? FileManager.default.removeItem(at: root)
    }
}
