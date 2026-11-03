import AppKit
import SwiftUI

@MainActor
final class AgentXWindowController: NSWindowController {
    init(controller: AgentXController, openJourney: @escaping () -> Void, openAlbum: @escaping () -> Void,
         travelPending: Bool, openTravelPrompt: @escaping () -> Void = {},
         workbenchPending: Int = 0, openWorkbench: @escaping () -> Void = {}, workbenchContent: (() -> AnyView)? = nil) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "AgentX Manager"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 960, height: 640)
        window.setFrameAutosaveName("AgentXManagerWindow")
        let host = NSHostingView(rootView: AgentXManagerView(controller: controller, openJourney: openJourney,
            openAlbum: openAlbum, openTravelPrompt: openTravelPrompt, travelPending: travelPending,
            workbenchPending: workbenchPending, openWorkbench: openWorkbench, workbenchContent: workbenchContent))
        host.sizingOptions = []
        window.contentView = host
        super.init(window: window)
        window.center()
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
    func updateTravelPending(_ pending: Bool) {
        guard let host = window?.contentView as? NSHostingView<AgentXManagerView> else { return }
        host.rootView.travelPending = pending
    }
    func updateWorkbenchPending(_ count: Int) {
        guard let host = window?.contentView as? NSHostingView<AgentXManagerView> else { return }
        host.rootView.workbenchPending = count
    }
    func updateWorkbenchContent(_ content: @escaping () -> AnyView) {
        guard let host = window?.contentView as? NSHostingView<AgentXManagerView> else { return }
        host.rootView.workbenchContent = content
    }
    func present() {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
