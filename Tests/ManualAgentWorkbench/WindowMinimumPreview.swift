// Offline native acceptance for the production utility-window resize boundary.
// No account, Keychain, network, runtime, real workspace or production data.
import AppKit
import SwiftUI

extension Bundle { static var module: Bundle { .main } }

@MainActor private final class WindowFixtureCredentials: TravelServiceCredentialStoring {
    private var values: [String: String] = [:]
    func read(id: String) throws -> String? { values[id] }
    func save(_ secret: String?, id: String) throws { values[id] = secret }
}

@MainActor private final class WindowFixtureRuntime: AgentRuntimeClient {
    var onEvent: (([String: Any]) -> Void)?
    var onExit: (() -> Void)?
    func launch(python: String) throws { throw WorkbenchFailure("离线窗口夹具不启动运行时。") }
    func request(_ method: String, _ params: [String: Any], timeout: UInt64) async throws -> [String: Any] {
        throw WorkbenchFailure("离线窗口夹具不执行任务。")
    }
    func shutdown() {}
}

@MainActor private final class WindowMinimumFixture: NSObject {
    let controller = TravelUtilityWindowController()
    let model: AgentWorkbenchModel
    private var observer: NSObjectProtocol?
    private var lastAction = "default"
    private let receipt = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("acceptance-geometry.json")

    init(model: AgentWorkbenchModel) {
        self.model = model
        super.init()
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: controller.window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recordGeometry() }
        }
        controller.setCloseHandler { NSApplication.shared.stop(nil) }
    }

    func installMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        add("关闭验收", action: #selector(close), to: appMenu, key: "q")
        let fixtureItem = NSMenuItem(title: "验收", action: nil, keyEquivalent: ""); menu.addItem(fixtureItem)
        let fixtureMenu = NSMenu(title: "验收"); fixtureItem.submenu = fixtureMenu
        add("默认窗口 1000×740", action: #selector(showDefault), to: fixtureMenu)
        add("最小窗口 760×600", action: #selector(showMinimum), to: fixtureMenu)
        add("模拟外部缩小 75×39", action: #selector(forceTinyFrame), to: fixtureMenu)
        let windows = NSMenuItem(title: "Window", action: nil, keyEquivalent: ""); menu.addItem(windows)
        let windowMenu = NSMenu(title: "Window"); windows.submenu = windowMenu
        NSApplication.shared.windowsMenu = windowMenu
        NSApplication.shared.mainMenu = menu
    }

    private func add(_ title: String, action: Selector, to menu: NSMenu, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self; menu.addItem(item)
    }

    @objc func showDefault() {
        lastAction = "default"
        controller.show(content: AnyView(AgentWorkbenchView(model: model)), size: .init(width: 1000, height: 740),
                        minimumContentSize: .init(width: 760, height: 600))
        recordGeometry()
    }

    @objc func showMinimum() {
        lastAction = "minimum"
        controller.window?.setContentSize(.init(width: 760, height: 600))
        controller.bringToFront()
        recordGeometry()
    }

    @objc func forceTinyFrame() {
        guard let window = controller.window else { return }
        lastAction = "external75x39"
        var frame = window.frame; frame.size = .init(width: 75, height: 39)
        window.setFrame(frame, display: true)
        controller.bringToFront()
        recordGeometry()
    }

    @objc func close() { controller.window?.performClose(nil) }

    private func recordGeometry() {
        guard let window = controller.window else { return }
        let content = window.contentRect(forFrameRect: window.frame).size
        window.title = "Travel Cat · 窗口尺寸验收（\(Int(content.width))×\(Int(content.height))）"
        let visible = window.screen?.visibleFrame ?? .zero
        let value: [String: Any] = [
            "action": lastAction, "contentWidth": content.width, "contentHeight": content.height,
            "minimumWidth": window.contentMinSize.width, "minimumHeight": window.contentMinSize.height,
            "frameX": window.frame.minX, "frameY": window.frame.minY,
            "frameWidth": window.frame.width, "frameHeight": window.frame.height,
            "screenContainsWindow": visible.contains(window.frame), "taskCount": model.state.tasks.count,
            "instanceCount": model.state.instances.count
        ]
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]) {
            try? data.write(to: receipt, options: .atomic)
        }
    }

    func finish() { if let observer { NotificationCenter.default.removeObserver(observer) } }
}

@main @MainActor struct WindowMinimumPreview {
    static func main() throws {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("travelcat-window-minimum-\(UUID().uuidString)")
        let model = AgentWorkbenchModel(root: root, credentials: WindowFixtureCredentials(), client: WindowFixtureRuntime())
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let instance = WorkbenchInstance(name: "窗口布局（离线）", image: "fixture", command: ["fixture"])
        var task = WorkbenchTask(instanceID: instance.id, title: "最小窗口：标题、侧栏、思考内容与输入区")
        task.status = .completed
        task.messages = [
            .init(role: "user", text: "检查缩放后的完整布局，不发送任何任务。"),
            .init(role: "assistant", text: "离线思考样本：此内容应默认折叠。", sourceKind: "acp.agent_thought_chunk"),
            .init(role: "assistant", text: "普通答案应直接可见。检查会话操作、滚动区域、输入框和发送提示均可使用。", sourceKind: "acp.agent_message_chunk")
        ]
        var second = WorkbenchTask(instanceID: instance.id, title: "另一条离线对话用于核对侧栏")
        second.status = .completed
        model.state.instances = [instance]; model.state.tasks = [task, second]
        model.preferredInstanceID = instance.id; model.selectedTaskID = task.id
        let fixture = WindowMinimumFixture(model: model)
        fixture.installMenu(); fixture.showDefault()
        app.run()
        fixture.finish()
    }
}
