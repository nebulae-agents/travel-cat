import AppKit
import SwiftUI
import TravelUI

@MainActor
final class TravelUtilityWindowController: NSWindowController, NSWindowDelegate {
    static let statusSize = NSSize(width: 420, height: 520)
    static let postcardSize = NSSize(width: 520, height: 680)
    static let albumSize = NSSize(width: 760, height: 700)
    static let settingsSize = NSSize(width: 480, height: 520)
    private var onWindowClosed: (() -> Void)?
    private var minimumContentSize = TravelUtilityWindowController.statusSize
    private var recoveringMinimumSize = false

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

    func show(content: AnyView, size: NSSize, minimumContentSize: NSSize? = nil) {
        guard let window else { return }
        self.minimumContentSize = minimumContentSize ?? NSSize(
            width: size == Self.albumSize ? Self.albumSize.width : Self.statusSize.width,
            height: min(size.height, 520)
        )
        window.contentMinSize = self.minimumContentSize
        window.delegate = self
        if let hostingView = window.contentView as? NSHostingView<AnyView> {
            hostingView.rootView = content
        } else {
            let hostingView = NSHostingView(rootView: content)
            hostingView.sizingOptions = []
            window.contentView = hostingView
        }
        window.setContentSize(size)
        window.contentView?.frame = NSRect(origin: .zero, size: size)
        clampToVisibleScreen(window)
        guard !NSScreen.screens.isEmpty else { return }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func resize(to size: NSSize) {
        guard let window else { return }
        minimumContentSize = NSSize(width: size == Self.albumSize ? Self.albumSize.width : Self.statusSize.width,
                                   height: min(size.height, 520))
        window.contentMinSize = minimumContentSize
        window.setContentSize(size)
        clampToVisibleScreen(window)
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
        // Keep the whole frame visible, including on displays smaller than the route minimum.
        window.setFrame(WindowPositionStore.clamp(window.frame, to: [screen.visibleFrame]), display: false)
    }

    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === self.window,
              !recoveringMinimumSize else { return }
        recoveringMinimumSize = true
        defer { recoveringMinimumSize = false }
        let repairingMinimum = window.contentMinSize != minimumContentSize
        if repairingMinimum { window.contentMinSize = minimumContentSize }
        var minimum = minimumContentSize
        if let screen = window.screen ?? NSScreen.main {
            let available = window.contentRect(forFrameRect: screen.visibleFrame).size
            minimum.width = min(minimum.width, available.width)
            minimum.height = min(minimum.height, available.height)
        }
        var content = window.contentRect(forFrameRect: window.frame)
        let recovered = NSSize(width: max(content.width, minimum.width), height: max(content.height, minimum.height))
        guard repairingMinimum || recovered != content.size else { return }
        content.size = recovered
        window.setFrame(window.frameRect(forContentRect: content), display: false)
        clampToVisibleScreen(window)
    }

    func windowWillClose(_ notification: Notification) {
        onWindowClosed?()
    }
}
