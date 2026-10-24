// Isolated offline fixture using production conversation, disclosure, Markdown, approval and composer.
// No account, Keychain, network, sidecar, real workspace or user data.
import AppKit
import SwiftUI

extension Bundle { static var module: Bundle { .main } }

private enum ThinkingSamples {
    static let thought = "7. 已收到的思考 summary\r\n9) 保持编号与字节 🙂  \r\n\r\n````swift\r\n\tlet emoji = \"🙂\"  \r\n" + String(repeating: "long_code_", count: 30) + "\r\n" + (1...24).map { "\tline_\($0)\r\n" }.joined() + "```\r\n````\r\n"
    static let nativeDetail = "{\r\n\t\"text\":\"已保存的 text🙂  \",\r\n\t\"summary\":[{\"type\":\"summary_text\",\"text\":\"7. summary\\r\\n9) 保持编号\"}],\r\n\t\"content\":[{\"type\":\"reasoning_text\",\"text\":\"~~~text\\r\\n\\tNative 🙂  \\r\\n~~~\\r\\n\"}]\r\n}\r\n"
    static let large = String(repeating: "超限思考🙂\r\n\t", count: 12_000)
}
@MainActor private final class ThinkingCredentials: TravelServiceCredentialStoring {
    private var values: [String: String] = [:]
    func read(id: String) throws -> String? { values[id] }
    func save(_ secret: String?, id: String) throws { values[id] = secret }
}
@MainActor private final class ThinkingRuntime: AgentRuntimeClient {
    var onEvent: (([String: Any]) -> Void)?
    var onExit: (() -> Void)?
    func launch(python: String) throws { throw WorkbenchFailure("离线思考夹具不启动运行时。") }
    func request(_ method: String, _ params: [String: Any], timeout: UInt64) async throws -> [String: Any] {
        if method == "permission" || method == "native_permission" { return ["accepted": true] }
        if method == "native_background_status" { return ["threadId": "offline-thinking-thread", "count": 0, "itemIds": []] }
        throw WorkbenchFailure("离线思考夹具不执行此操作。")
    }
    func shutdown() {}
}
@MainActor private struct ThinkingSurface: View {
    @ObservedObject var model: AgentWorkbenchModel
    @StateObject private var presentation = AgentWorkbenchPresentation()
    @State private var selected = 0
    @State private var streaming = false
    @State private var sequence = 0
    let resize: (NSSize) -> Void
    private func viewport(_ width: CGFloat, _ height: CGFloat) { resize(.init(width: width, height: height + 41)) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Button("ACP") { selected = 0 }
                Button("Native") { selected = 1 }
                Button("1000×740") { viewport(1000, 740) }
                Button("760×600") { viewport(760, 600) }
                Button(streaming ? "暂停追加" : "追加思考") { streaming.toggle() }
                Button("追加答案") { model.state.tasks[selected].messages.append(.init(role: "assistant", text: "新增普通答案 \(sequence)：思考 reasoning <think>标签</think>均可直接阅读。")) }
                Button("刷新审批") {
                    model.permissions = model.permissions.map { .init(id: $0.id, taskID: $0.taskID, title: "离线审批刷新 \(sequence)", detail: $0.detail, options: $0.options, nativeBinding: $0.nativeBinding) }
                    sequence += 1
                }
                Button("超限思考") { model.state.tasks[0].messages.append(.init(role: "assistant", text: ThinkingSamples.large, sourceKind: "acp.agent_thought_chunk")); selected = 0 }
            }.buttonStyle(.bordered).controlSize(.small).padding(.horizontal, 8).frame(height: 40)
            Divider()
            AgentConversationView(model: model, presentation: presentation, task: model.state.tasks[selected],
                artifacts: {}, audit: {}, handoff: { _ in }, settings: {})
        }.workbenchSurface().task(id: streaming) {
            guard streaming else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                sequence += 1
                model.state.tasks[0].messages[1].text += "追加 \(sequence) · 🙂\r\n"
                // Only fixture state changes: the production Native model does not acquire delta support.
                model.state.tasks[1].nativeState?.items[0].detail = ThinkingSamples.nativeDetail.replacingOccurrences(of: "已保存的 text", with: "已保存的 text \(sequence)")
            }
        }
    }
}

@main @MainActor struct ThinkingPreview {
    static func main() throws {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("travelcat-thinking-preview-\(UUID().uuidString)")
        let model = AgentWorkbenchModel(root: root, credentials: ThinkingCredentials(), client: ThinkingRuntime())
        let acp = WorkbenchInstance(name: "ACP 思考（离线）", image: "fixture", command: ["fixture"])
        var native = WorkbenchInstance(name: "Native 思考（离线）", image: "", command: [])
        native.native = .init(executable: "/usr/bin/false", workspace: root.path, model: "offline")
        var acpTask = WorkbenchTask(instanceID: acp.id, title: "ACP：明确类型默认折叠，普通正文直接阅读")
        acpTask.status = .awaitingPermission
        acpTask.messages = [.init(role: "user", text: "检查思考折叠、原文与输入。"),
            .init(role: "assistant", text: ThinkingSamples.thought, sourceKind: "acp.agent_thought_chunk"),
            .init(role: "assistant", text: "普通答案：思考、reasoning 和 <think>标签</think> 保持正文。\r\n7. 可以直接阅读\r\n9) 不需要展开思考", sourceKind: "acp.agent_message_chunk"),
            .init(role: "assistant", text: "旧记录没有来源字段，仍直接显示。"),
            .init(role: "assistant", text: "未知来源 future.reasoning 仍直接显示。", sourceKind: "future.reasoning")]
        var nativeTask = WorkbenchTask(instanceID: native.id, title: "Native：只读已有 detail，原始记录完整保留")
        nativeTask.status = .awaitingPermission
        nativeTask.nativeState = NativeTaskState(threadID: "offline-thinking-thread", turnID: "offline-thinking-turn", connection: .connected, items: [
            .init(id: "reasoning", turnID: "offline-thinking-turn", kind: "reasoning", title: "reasoning", detail: ThinkingSamples.nativeDetail, status: "unknown"),
            .init(id: "empty", kind: "reasoning", title: "reasoning", detail: "{\"summary\":[],\"content\":[]}", status: "unknown"),
            .init(id: "future-reasoning", kind: "reasoning", title: "reasoning", detail: "{\"futurePayload\":\"未知格式🙂  \\r\\n\"}", status: "unknown"),
            .init(id: "legacy-reasoning", kind: "reasoning", title: "reasoning", detail: "旧纯文本 reasoning detail\r\n\t🙂  ", status: "unknown"),
            .init(id: "future-process", kind: "futureProcess", title: "未知过程仍可查看", detail: "未知 kind 保留在运行过程中。\r\n\t🙂", status: "unknown")])
        nativeTask.messages = [.init(role: "user", text: "查看已收到的 Native 内容。"), .init(role: "assistant", text: "Native 正常答案含 reasoning <think>普通文字</think>，直接可读。", runtimeItemID: "answer")]
        model.state.instances = [acp, native]; model.state.tasks = [acpTask, nativeTask]
        model.liveTasks = [acpTask.id, nativeTask.id]
        model.permissions = [acpTask, nativeTask].map { task in
            .init(id: "offline-thinking-approval-" + task.id.uuidString, taskID: task.id, title: "离线审批保持可见", detail: "固定审批只测试布局和焦点，不执行命令。", options: [.init(id: task.nativeState == nil ? "deny" : "decline", title: "拒绝夹具操作", kind: "reject_once")],
                nativeBinding: task.nativeState == nil ? nil : .init(requestHash: String(repeating: "a", count: 64), threadID: "offline-thinking-thread", turnID: "offline-thinking-turn", itemID: "offline-thinking-approval", expiresAt: Date().addingTimeInterval(3600)))
        }
        // Expectations stay beside this independent temporary bundle, never in a user workspace.
        let expected = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("expected")
        try FileManager.default.createDirectory(at: expected, withIntermediateDirectories: true)
        try Data(ThinkingSamples.thought.utf8).write(to: expected.appendingPathComponent("acp-thought.txt"))
        try Data(ThinkingSamples.nativeDetail.utf8).write(to: expected.appendingPathComponent("native-detail.json"))
        try Data(ThinkingSamples.large.utf8).write(to: expected.appendingPathComponent("large-acp-thought.txt"))
        let window = NSWindow(contentRect: .init(x: 100, y: 100, width: 1000, height: 781), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Travel Cat · 思考折叠验收（离线夹具）"; window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua); window.contentMinSize = .init(width: 760, height: 641)
        let host = NSHostingView(rootView: ThinkingSurface(model: model, resize: { window.setContentSize($0) }))
        host.sizingOptions = []; window.contentView = host
        window.center(); window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in MainActor.assumeIsolated { app.stop(nil) } }
        app.run()
        NotificationCenter.default.removeObserver(observer); model.shutdown(); try? FileManager.default.removeItem(at: root)
    }
}
