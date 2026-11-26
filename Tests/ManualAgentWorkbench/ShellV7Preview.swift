import AppKit
import SwiftUI
@testable import TravelCatApp

@MainActor private final class PreviewCredentials: TravelServiceCredentialStoring {
    var values: [String: String] = [:]
    func read(id: String) throws -> String? { values[id] }
    func save(_ secret: String?, id: String) throws { values[id] = secret }
}
@MainActor private final class PreviewApplication: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let controller: AgentXController
    let root: URL
    var window: NSWindow?
    var timer: Timer?
    var ticks = 0
    let seconds = min(max(Int(ProcessInfo.processInfo.environment["AGENTX_SHELL_V7_SECONDS"] ?? "900") ?? 900, 1), 1800)
    init(controller: AgentXController, root: URL) { self.controller = controller; self.root = root }
    func log(_ value: String) { FileHandle.standardError.write(Data((value + "\n").utf8)) }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: .init(x: 80, y: 80, width: 1280, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        self.window = window
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.title = "AgentX Shell v7 — 隔离预览"
        window.contentView = NSHostingView(rootView: AgentXManagerView(controller: controller))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        log("SHELL_V7_PREVIEW_READY pid=\(ProcessInfo.processInfo.processIdentifier) root=\(root.path) appRunning=\(NSApp.isRunning)")
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.ticks += 1
                if self.ticks <= 3 || self.ticks % 30 == 0 { self.log("SHELL_V7_HEARTBEAT tick=\(self.ticks) appRunning=\(NSApp.isRunning)") }
                if self.ticks >= self.seconds { self.stop() }
            }
        }
    }
    func windowWillClose(_ notification: Notification) { stop() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { stop(); return .terminateCancel }
    func stop() {
        timer?.invalidate(); timer = nil
        controller.softStopAll()
        NSApp.stop(nil)
        if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) { NSApp.postEvent(event, atStart: false) }
    }
}
@main @MainActor private enum ShellV7Preview {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("AppShell-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = AgentXRepository(root: root)
        var state = AgentXState()
        state.apps = [.init(id: "a", name: "A", kind: .chat), .init(id: "b", name: "B", kind: .chat)]
        state.currentAppID = "b"
        try repo.save(state)
        let c = AgentXController(repository: repo, credentials: PreviewCredentials(), respond: { _, _, _, _ in
            try await Task.sleep(for: .seconds(20))
            return "这是隔离预览的模拟回应。输入、运行、停止与发布使用真实界面和控制器。"
        }, autoRefreshCatalogs: false)
        try c.addProvider(name: "隔离模拟服务", address: "http://127.0.0.1:1", models: "fixture", secret: "")
        try c.addDefinition(name: "预览成员", prompt: "仅供壳 v7 本地验收")
        let provider = c.state.providers[0]
        let definition = c.state.definitions[0]
        for appID in ["a", "b"] {
            try c.addInstance(name: "预览成员 " + appID, appID: appID, definitionID: definition.id, providerID: provider.id, model: "fixture")
            var experience = AgentXAppExperience()
            experience.title = "隔离预览 · 应用 " + appID
            experience.intro = "这是一段用于界面验收的场景说明。选择下面的行动后，文字只会进入输入框；可以修改后再发送。"
            experience.layout = .scene
            experience.choices = ["先询问当前进展。", "整理下一步行动。", "换一个角度继续。"]
            try c.saveExperienceDraft(appID: appID, configuration: experience, expectedDraft: nil)
            try c.publishExperience(appID: appID)
        }
        c.openFrontend()
        let delegate = PreviewApplication(controller: c, root: root)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
        delegate.log("SHELL_V7_PREVIEW_EXIT ticks=\(delegate.ticks)")
    }
}
