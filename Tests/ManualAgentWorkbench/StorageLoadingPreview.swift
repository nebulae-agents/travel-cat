// Offline production recovery surface; never uses Keychain, accounts or runtime processes.
import AppKit
import SwiftUI

extension Bundle { static var module: Bundle { .main } }
private actor LoadingCredentials: AsyncTravelServiceCredentialStoring {
    var values: [String: String] = [:]
    var paused: Set<String> = []
    var waiter: CheckedContinuation<Void, Never>?
    func read(id: String) async throws -> String? {
        if paused.insert(id).inserted { await withCheckedContinuation { waiter = $0 } }
        return values[id]
    }
    func save(_ secret: String?, id: String) async throws { values[id] = secret }
    func release() { waiter?.resume(); waiter = nil }
}
@MainActor private final class OfflineRuntime: AgentRuntimeClient {
    var onEvent: (([String: Any]) -> Void)?
    var onExit: (() -> Void)?
    func launch(python: String) throws { throw WorkbenchFailure("离线夹具不启动运行时") }
    func request(_ method: String, _ params: [String: Any], timeout: UInt64) async throws -> [String: Any] { throw WorkbenchFailure("离线夹具不发送请求") }
    func shutdown() {}
}
@MainActor private struct LoadingSurface: View {
    @ObservedObject var model: AgentWorkbenchModel
    let credentials: LoadingCredentials
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("离线加载验收 · 无真实钥匙串")
                Spacer()
                Button("模拟已等待20秒") { model.storageLoadStartedAt = Date().addingTimeInterval(-20) }
                Button("结束模拟系统请求") { Task { await credentials.release() } }
            }.padding(8)
            Divider()
            AgentWorkbenchView(model: model)
        }
    }
}
@MainActor private final class LoadingApplication: NSObject, NSApplicationDelegate {
    let controller = TravelUtilityWindowController()
    let credentials = LoadingCredentials()
    let root: URL
    let model: AgentWorkbenchModel
    init(root: URL) {
        self.root = root
        model = AgentWorkbenchModel(root: root, credentialStores: .init(content: credentials, audit: credentials, models: credentials), client: OfflineRuntime())
        super.init()
        controller.setCloseHandler { [weak self] in self?.close() }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.mainMenu = AcceptanceApplicationMenu.make(target: self, show: #selector(show), close: #selector(close))
        controller.show(content: AnyView(LoadingSurface(model: model, credentials: credentials)), size: .init(width: 1000, height: 740), minimumContentSize: .init(width: 760, height: 650))
        controller.window?.title = "Travel Cat · 安全存储加载离线验收"
        Task { await model.loadStorage() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(); return false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { close(); return .terminateCancel }
    @objc func show() { controller.bringToFront() }
    @objc func close() {
        model.shutdown()
        Task {
            await credentials.release()
            NSApplication.shared.stop(nil)
            if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) { NSApplication.shared.postEvent(event, atStart: false) }
        }
    }
}
@main @MainActor struct StorageLoadingPreview {
    static func main() throws {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("travelcat-storage-fixture-" + UUID().uuidString)
        let delegate = LoadingApplication(root: root)
        app.delegate = delegate; app.run()
        delegate.controller.setCloseHandler(nil)
        try? FileManager.default.removeItem(at: root)
    }
}
