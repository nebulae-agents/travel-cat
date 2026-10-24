// Offline test-owned bytes shown through the production artifact model and view.
// A/B changes are fixture writes, not Agent output.
import AppKit
import SwiftUI
import PDFKit

extension Bundle { static var module: Bundle { .main } }

// Size buttons describe the production viewport; fixture controls live above it.
private enum ArtifactFixtureViewport {
    static let controlsHeight: CGFloat = 40
    static let chromeHeight: CGFloat = 41 // fixed controls + one-point divider
    static func windowContentSize(_ viewport: NSSize) -> NSSize {
        .init(width: viewport.width, height: viewport.height + chromeHeight)
    }
}
@MainActor private final class ArtifactPreviewCredentials: TravelServiceCredentialStoring {
    var values: [String: String] = [:]
    func read(id: String) throws -> String? { values[id] }
    func save(_ secret: String?, id: String) throws { values[id] = secret }
}
@MainActor private final class ArtifactPreviewRuntime: AgentRuntimeClient {
    var onEvent: (([String: Any]) -> Void)?
    var onExit: (() -> Void)?
    var files: [String: Data]
    let baseline: [String: Data]
    init(files: [String: Data]) { self.files = files; baseline = files }
    func launch(python: String) throws { throw WorkbenchFailure("离线制品夹具不连接运行时。") }
    func shutdown() {}
    func request(_ method: String, _ params: [String: Any], timeout: UInt64) async throws -> [String: Any] {
        if method == "artifact_changes" {
            return ["bindingId": "offline-artifact-binding", "executionId": "offline-artifact-execution", "checkedAt": Date().timeIntervalSince1970,
                "baselineCapturedAt": 1_000, "inventoryComplete": true, "hashComplete": true, "baselineInventoryComplete": true, "baselineHashComplete": true,
                "files": files.map { path, bytes in ["path": path, "size": bytes.count, "sha256": WorkbenchArtifactPreview.digest(bytes), "change": bytes == baseline[path] ? "unchanged" : "modified"] }]
        }
        guard method == "export", let path = params["path"] as? String, let bytes = files[path] else { throw WorkbenchFailure("离线夹具仅支持制品读取。") }
        return ["name": (path as NSString).lastPathComponent, "base64": bytes.base64EncodedString(), "bindingId": "offline-artifact-binding", "executionId": "offline-artifact-execution"]
    }
}
@MainActor private struct ArtifactPreviewSurface: View {
    @ObservedObject var model: AgentWorkbenchModel
    let runtime: ArtifactPreviewRuntime
    let taskID: UUID
    let resize: (NSSize) -> Void
    @State private var changed = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("离线夹具 · 测试字节，不代表 Agent 产出").font(.caption)
                Spacer()
                Button("1000 × 740") { resize(.init(width: 1000, height: 740)) }
                Button("760 × 600") { resize(.init(width: 760, height: 600)) }
                Button(changed ? "已写入同长 B" : "外部测试写入 A→B") { runtime.files["report.txt"] = Data("Version B\n".utf8); changed = true }.disabled(changed)
            }.controlSize(.small).padding(.horizontal, 8).frame(height: ArtifactFixtureViewport.controlsHeight)
            Divider().frame(height: 1)
            AgentArtifactsView(model: model, taskID: taskID)
        }
    }
}
@main @MainActor struct ArtifactPreview {
    static func main() throws {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let root = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("artifact-session")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("downloads"), withIntermediateDirectories: false)
        let png = try image()
        let pdf = try document()
        let files = ["report.txt": Data("Version A\n".utf8), "preview.png": png, "two-pages.pdf": pdf]
        let expected = root.appendingPathComponent("expected")
        try FileManager.default.createDirectory(at: expected, withIntermediateDirectories: false)
        for (path, bytes) in files { try bytes.write(to: expected.appendingPathComponent(path)) }
        try Data("Version B\n".utf8).write(to: expected.appendingPathComponent("report-B.txt"))
        let runtime = ArtifactPreviewRuntime(files: files)
        let model = AgentWorkbenchModel(root: root.appendingPathComponent("store"), credentials: ArtifactPreviewCredentials(), client: runtime)
        let instance = WorkbenchInstance(name: "制品验收（离线）", image: "fixture", command: ["fixture"])
        var task = WorkbenchTask(instanceID: instance.id, title: "PNG / 两页 PDF / 同长 A→B")
        task.status = .completed; task.sessionID = "offline-artifact-session"
        model.state.instances = [instance]; model.state.tasks = [task]; model.liveTasks.insert(task.id); model.persist()
        let manifest = files.mapValues { ["bytes": $0.count, "sha256": WorkbenchArtifactPreview.digest($0)] as [String: Any] }
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("expected-manifest.json"))
        let window = NSWindow(contentRect: .init(x: 100, y: 100, width: 1000, height: 740 + ArtifactFixtureViewport.chromeHeight), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Travel Cat · 制品验收（离线夹具）"; window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua); window.contentMinSize = ArtifactFixtureViewport.windowContentSize(.init(width: 760, height: 600))
        let host = NSHostingView(rootView: ArtifactPreviewSurface(model: model, runtime: runtime, taskID: task.id, resize: { window.setContentSize(ArtifactFixtureViewport.windowContentSize($0)) }))
        host.sizingOptions = []; window.contentView = host; window.center(); window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in MainActor.assumeIsolated { app.stop(nil) } }
        app.run(); NotificationCenter.default.removeObserver(observer); model.shutdown()
        // Preserve expected bytes, downloads and metadata for exact external read-back.
    }
    static func image() throws -> Data {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 360, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        NSColor(calibratedRed: 0.88, green: 0.95, blue: 0.91, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 640, height: 360).fill()
        NSColor.systemOrange.setFill(); NSBezierPath(ovalIn: .init(x: 430, y: 180, width: 120, height: 120)).fill()
        ("OFFLINE PNG · 640 × 360" as NSString).draw(at: .init(x: 40, y: 90), withAttributes: [.font: NSFont.systemFont(ofSize: 27), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw WorkbenchFailure("PNG fixture unavailable") }; return data
    }
    static func document() throws -> Data {
        let data = NSMutableData()
        var media = CGRect(x: 0, y: 0, width: 540, height: 720)
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &media, nil) else { throw WorkbenchFailure("PDF fixture unavailable") }
        for page in 1...2 {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            ("OFFLINE PDF · PAGE \(page) OF 2" as NSString).draw(at: .init(x: 40, y: 580), withAttributes: [.font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.black])
            NSColor(calibratedRed: page == 1 ? 0.85 : 0.95, green: 0.90, blue: page == 1 ? 0.95 : 0.80, alpha: 1).setFill(); NSRect(x: 40, y: 120, width: 460, height: 400).fill()
            NSGraphicsContext.restoreGraphicsState(); context.endPDFPage()
        }
        context.closePDF(); return data as Data
    }
}
