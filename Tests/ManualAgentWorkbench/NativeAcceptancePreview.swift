// Real production Native client and setup, independent empty workspace and profile.
// No automatic connection, login or task. Official account state is never copied or removed.
import AppKit
import SwiftUI

extension Bundle { static var module: Bundle { .main } }

// Size buttons describe the production viewport; fixture controls live above it.
private enum NativeFixtureViewport {
    static let controlsHeight: CGFloat = 40
    static let chromeHeight: CGFloat = 41 // fixed controls + one-point divider
    static func windowContentSize(_ viewport: NSSize) -> NSSize {
        .init(width: viewport.width, height: viewport.height + chromeHeight)
    }
}
@MainActor private final class NativeAcceptanceWindowProbe {
    weak var window: NSWindow?
    var launchCompleted = false
    func snapshot() -> [String: Any] {
        var value: [String: Any] = ["exists": window != nil, "launchCompleted": launchCompleted,
            "applicationActive": NSApplication.shared.isActive]
        guard let window else { return value }
        let content = window.contentRect(forFrameRect: window.frame).size
        value.merge(["visible": window.isVisible, "miniaturized": window.isMiniaturized,
            "key": window.isKeyWindow, "frameX": window.frame.minX, "frameY": window.frame.minY,
            "frameWidth": window.frame.width, "frameHeight": window.frame.height,
            "contentWidth": content.width, "contentHeight": content.height,
            "minimumWidth": window.contentMinSize.width, "minimumHeight": window.contentMinSize.height,
            "screenContainsWindow": window.screen?.visibleFrame.contains(window.frame) ?? false]) { _, new in new }
        return value
    }
}
@MainActor private final class NativeAcceptanceCredentials: TravelServiceCredentialStoring {
    var values: [String: String] = [:]
    func read(id: String) throws -> String? { values[id] }
    func save(_ secret: String?, id: String) throws { values[id] = secret }
}
@MainActor private final class NativeAcceptanceClient: AgentRuntimeClient {
    var onEvent: (([String: Any]) -> Void)?
    var onExit: (() -> Void)?
    let actual = AgentSidecarClient()
    let root: URL
    init(root: URL) {
        self.root = root
        actual.onEvent = { [weak self] in self?.onEvent?($0) }
        actual.onExit = { [weak self] in self?.onExit?() }
    }
    func launch(python: String) throws { try actual.launch(python: python) }
    func shutdown() { actual.shutdown() }
    func request(_ method: String, _ params: [String: Any], timeout: UInt64) async throws -> [String: Any] {
        let profile = (params["profileRoot"] as? String).map { URL(fileURLWithPath: $0) }
        let receipt = profile?.appendingPathComponent("travelcat-daemon.json")
        let previouslyExisted = receipt.map { FileManager.default.fileExists(atPath: $0.path) } ?? true
        let result = try await actual.request(method, params, timeout: timeout)
        if method == "native_connect", !previouslyExisted, let receipt,
           !FileManager.default.fileExists(atPath: root.appendingPathComponent("daemon-ownership.json").path) {
            // Only this fresh fixture's first native_connect can establish ownership.
            let bytes = try Data(contentsOf: receipt)
            let value: [String: Any] = ["firstLaunchOwned": true, "parameters": params,
                "receiptSHA256": WorkbenchArtifactPreview.digest(bytes), "receipt": try JSONSerialization.jsonObject(with: bytes),
                "capturedAt": Date().timeIntervalSince1970]
            try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("daemon-ownership.json"), options: .withoutOverwriting)
        }
        return result
    }
}
/// Keep AppKit's run loop alive while the real sidecar receives EOF and exits.
/// Metadata stays false on timeout, cancellation, unexpected app stop or failed publication.
@MainActor private final class NativeAcceptanceShutdown {
    let root: URL
    let model: AgentWorkbenchModel
    let client: NativeAcceptanceClient
    let snapshot: @MainActor @Sendable () -> Void
    var timer: Timer?
    private var closing = false
    init(root: URL, model: AgentWorkbenchModel, client: NativeAcceptanceClient, snapshot: @escaping @MainActor @Sendable () -> Void) {
        self.root = root; self.model = model; self.client = client; self.snapshot = snapshot
    }
    func tick() { if !closing { snapshot() } }
    func close(app: NSApplication) {
        guard !closing else { return }
        closing = true; timer?.invalidate(); timer = nil
        snapshot() // Freeze fresh terminal/background evidence before model shutdown invalidates observations.
        model.shutdown()
        Task { @MainActor in
            let confirmed = await client.actual.waitForExit(timeout: .seconds(10))
            let metadata = root.appendingPathComponent("acceptance-metadata.json")
            do {
                guard var value = try JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any] else {
                    throw WorkbenchFailure("验收元数据无法读取；退出证据未发布。")
                }
                value["clientDetached"] = confirmed
                value["sidecarExitConfirmed"] = confirmed
                value["sidecarExitStatus"] = confirmed ? "processTerminationObserved" : "timeoutOrCancelled"
                value["sidecarExitCheckedAt"] = Date().timeIntervalSince1970
                try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: metadata, options: .atomic)
            } catch {
                // Original false metadata remains; do not publish a successful detach fallback.
                try? Data("{\"exitEvidencePublicationFailed\":true}\n".utf8).write(to: root.appendingPathComponent("shutdown-evidence-error.json"), options: .atomic)
            }
            app.stop(nil)
            // An async completion can run inside nextEvent's nested run loop.
            // Wake only this app with a non-input event so run() can return.
            if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) { app.postEvent(wake, atStart: false) }
        }
    }
    func appRunReturned() {
        timer?.invalidate(); timer = nil
        if !closing { snapshot(); model.shutdown() } // No actual exit observation: leave false.
    }
}
@MainActor private struct NativeAcceptanceSurface: View {
    @ObservedObject var model: AgentWorkbenchModel
    let instance: WorkbenchInstance
    let record: () async -> Void
    @State private var setup = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("真实 Native 验收 · 独立空目录 · 默认不发任务").font(.caption)
                Spacer()
                Button("打开官方登录设置") { setup = true }
                Button("记录验收元数据") { Task { await record() } }
            }.controlSize(.small).padding(.horizontal, 8).frame(height: NativeFixtureViewport.controlsHeight)
            Divider().frame(height: 1)
            AgentWorkbenchView(model: model)
        }.sheet(isPresented: $setup) { NativeAgentSetupView(model: model, instance: model.state.instances.first(where: { $0.id == instance.id }) ?? instance, didSave: { model.preferredInstanceID = $0 }) }
    }
}
// Launch Services may start a preview in the background. Present only once AppKit
// has finished launching, and let a Dock reopen restore the same owned window.
@MainActor private final class NativeAcceptanceApplication: NSObject, NSApplicationDelegate {
    let controller: TravelUtilityWindowController
    let content: AnyView
    let shutdown: NativeAcceptanceShutdown
    let probe: NativeAcceptanceWindowProbe

    init(controller: TravelUtilityWindowController, content: AnyView,
         shutdown: NativeAcceptanceShutdown, probe: NativeAcceptanceWindowProbe) {
        self.controller = controller; self.content = content
        self.shutdown = shutdown; self.probe = probe
        super.init()
        controller.setCloseHandler { [weak shutdown] in shutdown?.close(app: .shared) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.mainMenu = AcceptanceApplicationMenu.make(
            target: self, show: #selector(showWindow), close: #selector(close))
        controller.show(content: content,
            size: NativeFixtureViewport.windowContentSize(.init(width: 1000, height: 740)),
            minimumContentSize: NativeFixtureViewport.windowContentSize(.init(width: 760, height: 600)))
        controller.window?.title = "Travel Cat · 真实 Native 独立验收"
        controller.window?.appearance = NSAppearance(named: .aqua)
        probe.launchCompleted = true
        shutdown.tick()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(); return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        shutdown.close(app: sender); return .terminateCancel
    }

    @objc func showWindow() { controller.bringToFront(); shutdown.tick() }
    @objc func close() { controller.window?.performClose(nil) }

    func finish() { shutdown.appRunReturned(); controller.setCloseHandler(nil) }
}
@main @MainActor struct NativeAcceptancePreview {
    static func main() throws {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let root = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("native-session")
        // A second launch must use a fresh app/root; never reopen with a lost in-memory store key.
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let client = NativeAcceptanceClient(root: root)
        let model = AgentWorkbenchModel(root: root.appendingPathComponent("store"), credentials: NativeAcceptanceCredentials(), client: client)
        var configuredInstance = NativeAgentSetupView.newInstance()
        configuredInstance.name = "本机 Codex · 独立验收"
        configuredInstance.native?.workspace = workspace.path
        let instance = configuredInstance
        try JSONSerialization.data(withJSONObject: ["instanceId": instance.id.uuidString, "workspace": workspace.path,
            "store": model.store.root.path, "executable": instance.native?.executable ?? "", "automaticTask": false], options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("fixture.json"))
        let windowProbe = NativeAcceptanceWindowProbe()
        let snapshot: @MainActor @Sendable () -> Void = {
            let tasks: [[String: Any]] = model.state.tasks.map { task in
                let native = task.nativeState
                return ["taskId": task.id.uuidString, "instanceId": task.instanceID.uuidString, "status": task.status.rawValue,
                    "threadId": native?.threadID ?? "", "turnId": native?.turnID ?? "", "turnStatuses": native?.turnStatuses ?? [:],
                    "backgroundCount": model.freshNativeBackgroundObservation(task.id)?.count ?? -1,
                    "auditKinds": model.auditRecords(taskID: task.id).compactMap { $0["kind"] as? String }]
            }
            let value: [String: Any] = ["recordedAt": Date().timeIntervalSince1970, "clientDetached": false, "sidecarExitConfirmed": false, "sidecarExitStatus": "notObserved", "tasks": tasks,
                "instanceId": instance.id.uuidString, "authenticated": model.nativeConnections[instance.id]?.authenticated ?? false,
                "modelCount": model.nativeConnections[instance.id]?.models.count ?? 0, "window": windowProbe.snapshot()]
            try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("acceptance-metadata.json"), options: .atomic)
        }
        let controller = TravelUtilityWindowController()
        windowProbe.window = controller.window
        let content = AnyView(NativeAcceptanceSurface(model: model, instance: instance, record: {
            for task in model.state.tasks where [.completed, .cancelled, .failed].contains(task.status) { await model.refreshNativeBackgroundStatus(task.id) }
            snapshot()
        }))
        let shutdown = NativeAcceptanceShutdown(root: root, model: model, client: client, snapshot: snapshot)
        let delegate = NativeAcceptanceApplication(controller: controller, content: content, shutdown: shutdown, probe: windowProbe)
        app.delegate = delegate
        shutdown.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak shutdown] _ in MainActor.assumeIsolated { shutdown?.tick() } }
        snapshot(); app.run(); delegate.finish()
        // Detach preserves daemon, profile and official login. Use the exact ownership receipt cleanup tool after terminal/background-zero verification.
    }
}
