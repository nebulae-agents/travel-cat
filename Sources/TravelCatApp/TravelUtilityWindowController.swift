import AppKit
import SwiftUI

@MainActor
final class TravelUtilityWindowController: NSWindowController, NSWindowDelegate {
    static let statusSize = NSSize(width: 420, height: 520)
    static let postcardSize = NSSize(width: 520, height: 680)
    static let albumSize = NSSize(width: 760, height: 700)
    static let settingsSize = NSSize(width: 480, height: 520)
    private var onWindowClosed: (() -> Void)?

    init() {
        super.init(window: Self.makeWindow(content: AnyView(EmptyView()), size: Self.statusSize))
        window?.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static func makeWindow(content: AnyView, size: NSSize) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Travel Cat"
        window.level = .normal
        window.isReleasedWhenClosed = false
        let hostingView = NSHostingView(rootView: content)
        hostingView.sizingOptions = []
        window.contentView = hostingView
        window.setContentSize(size)
        window.contentMinSize = NSSize(width: Self.statusSize.width, height: 520)
        window.contentView?.frame = NSRect(origin: .zero, size: size)
        window.center()
        return window
    }

    func show(content: AnyView, size: NSSize) {
        guard let window else { return }
        window.delegate = self
        if let hostingView = window.contentView as? NSHostingView<AnyView> {
            hostingView.rootView = content
        } else {
            let hostingView = NSHostingView(rootView: content)
            hostingView.sizingOptions = []
            window.contentView = hostingView
        }
        window.setContentSize(size)
        window.contentMinSize = NSSize(
            width: size == Self.albumSize ? Self.albumSize.width : Self.statusSize.width,
            height: min(size.height, 520)
        )
        window.contentView?.frame = NSRect(origin: .zero, size: size)
        clampToVisibleScreen(window)
        guard !NSScreen.screens.isEmpty else { return }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func bringToFront() {
        guard let window else { return }
        if window.isVisible {
            window.orderFront(nil)
            window.makeKey()
        } else {
            window.makeKeyAndOrderFront(nil)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func setCloseHandler(_ handler: (() -> Void)?) {
        onWindowClosed = handler
    }

    private func clampToVisibleScreen(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        window.setFrame(window.constrainFrameRect(window.frame, to: screen), display: false)
    }

    func windowWillClose(_ notification: Notification) {
        onWindowClosed?()
    }
}
