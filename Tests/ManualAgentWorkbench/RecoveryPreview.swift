// Production asynchronous bootstrap with controllable in-memory credentials; no real Keychain/account.
import AppKit
import SwiftUI

extension Bundle { static var module: Bundle { .main } }

actor RecoveryPreviewCredentials: AsyncTravelServiceCredentialStoring {
    private var values: [String: String]
    private var waiting = true
    private var denied = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(values: [String: String]) { self.values = values }
    func deny() { waiting = false; denied = true; continuation?.resume(); continuation = nil }
    func allow() { waiting = false; denied = false; continuation?.resume(); continuation = nil }
    func read(id: String) async throws -> String? {
        if waiting { await withCheckedContinuation { continuation = $0 } }
        if denied { throw TravelServiceCredentialError.keychain(-25293) }
        return values[id]
    }
    func save(_ secret: String?, id: String) async throws { values[id] = secret }
}

@MainActor final class RecoveryPreviewRuntime: AgentRuntimeClient {
    var onEvent: (([String: Any]) -> Void)?
    var onExit: (() -> Void)?
    func launch(python: String) throws { throw WorkbenchFailure("此离线夹具不会启动运行时。") }
    func request(_ method: String, _ params: [String: Any], timeout: UInt64) async throws -> [String: Any] { throw WorkbenchFailure("此离线夹具不会发送运行时请求。") }
    func shutdown() {}
}

@MainActor struct RecoveryPreviewSurface: View {
    @ObservedObject var model: AgentWorkbenchModel
    let credentials: RecoveryPreviewCredentials
    @State private var responses = 0
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("离线钥匙串验收").font(.caption)
                Button("响应检查 +1（\(responses)）") { responses += 1 }
                Spacer()
                Button("模拟拒绝授权") { Task { await credentials.deny() } }
                Button("允许再次授权") { Task { await credentials.allow() } }
            }.padding(10)
            Divider()
            AgentWorkbenchView(model: model)
        }.task { await model.loadStorage() }
    }
}

@main @MainActor struct RecoveryPreview {
    static func main() throws {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("travelcat-keychain-preview-\(UUID().uuidString)")
        let key = Data(repeating: 17, count: 32), auditKey = Data(repeating: 29, count: 32)
        var instance = WorkbenchInstance(name: "已保存的 Agent（离线）", image: "fixture@sha256:" + String(repeating: "a", count: 64), command: ["fixture"])
        instance.provider.model = "fixture-only"
        var task = WorkbenchTask(instanceID: instance.id, title: "授权恢复后仍保留的原对话")
        task.status = .completed
        task.messages = [.init(role: "user", text: "这条消息与会话标识在拒绝并重试后保持不变。"), .init(role: "assistant", text: "原密钥和加密对话已恢复；此验收夹具不会访问真实账号。")]
        try WorkbenchStore(root: root, keyData: key).save(.init(instances: [instance], tasks: [task]))
        _ = try AgentAuditStore(root: root.appendingPathComponent("audit-v1"), keyData: auditKey)
        let credentials = RecoveryPreviewCredentials(values: ["workbench-content-v1": key.base64EncodedString(), "audit-journal-v1": auditKey.base64EncodedString()])
        let model = AgentWorkbenchModel(root: root, credentialStores: .init(content: credentials, audit: credentials, models: credentials), client: RecoveryPreviewRuntime())
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 790), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Travel Cat · 钥匙串恢复验收（离线夹具）"; window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 760, height: 650)
        let hosting = NSHostingView(rootView: RecoveryPreviewSurface(model: model, credentials: credentials)); hosting.sizingOptions = []; window.contentView = hosting
        let menu = NSMenu(), appItem = NSMenuItem(), appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出离线夹具", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); appItem.submenu = appMenu; menu.addItem(appItem); app.mainMenu = menu
        window.center(); window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in MainActor.assumeIsolated { app.stop(nil) } }
        app.run()
        NotificationCenter.default.removeObserver(observer); model.shutdown(); try? FileManager.default.removeItem(at: root)
    }
}
