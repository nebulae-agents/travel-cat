import AppKit
import SwiftUI
import TravelUI

@MainActor
private final class StandalonePetSceneState: ObservableObject {
    @Published var isActive = false
}

@MainActor
private struct StandalonePetContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var scene: StandalonePetSceneState
    var body: some View {
        PetHouseView(phase: model.snapshot.phase, hasUnreadPostcard: !model.unreadPostcardIDs.isEmpty, isActive: scene.isActive, reaction: model.homeCareReaction)
    }
}

@MainActor
private final class StandalonePetPanel: NSPanel {
    var primaryAction: (() -> Void)?
    var petMenu: NSMenu?
    private var mouseDownEvent: NSEvent?
    private var dragged = false
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .rightMouseDown:
            if let petMenu, let contentView { NSMenu.popUpContextMenu(petMenu, with: event, for: contentView) }
            return
        case .leftMouseDown:
            mouseDownEvent = event
            dragged = false
        case .leftMouseDragged:
            if let start = mouseDownEvent,
               hypot(event.locationInWindow.x - start.locationInWindow.x, event.locationInWindow.y - start.locationInWindow.y) > 3 {
                dragged = true
                mouseDownEvent = nil
                performDrag(with: start)
            }
            return
        case .leftMouseUp:
            let shouldOpen = mouseDownEvent != nil && !dragged
            mouseDownEvent = nil
            if shouldOpen { primaryAction?() }
            return
        default: break
        }
        super.sendEvent(event)
    }
}

/// Owns only the compact desktop surface; every navigation route opens another window.
@MainActor
final class StandalonePetController: NSWindowController, NSWindowDelegate, NSMenuDelegate {
    let contextMenu = NSMenu()
    private let positionStore: WindowPositionStore
    private let model: AppModel
    private let scene = StandalonePetSceneState()
    private let routes: [() -> Void]

    init(model: AppModel, openJourney: @escaping () -> Void, openPostcard: @escaping () -> Void,
         openAlbum: @escaping () -> Void, openSupplies: @escaping () -> Void,
         positionStore: WindowPositionStore = WindowPositionStore()) {
        self.positionStore = positionStore
        self.model = model
        routes = [openJourney, openPostcard, openAlbum, openSupplies]
        let panel = StandalonePetPanel(contentRect: CGRect(origin: .zero, size: PetWindowController.compactSize),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        let hosting = TransparentHostingView(rootView: AnyView(StandalonePetContent(model: model, scene: scene)))
        hosting.sizingOptions = []
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hosting
        super.init(window: panel)
        panel.delegate = self
        panel.primaryAction = openJourney
        for (index, title) in ["当前旅程", "最新明信片", "旅行册", "用品"].enumerated() {
            let item = NSMenuItem(title: title, action: #selector(performRoute(_:)), keyEquivalent: "")
            item.tag = index
            item.target = self
            contextMenu.addItem(item)
        }
        contextMenu.addItem(.separator())
        let hideItem = NSMenuItem(title: "隐藏桌宠", action: #selector(hidePet(_:)), keyEquivalent: "")
        hideItem.target = self
        contextMenu.addItem(hideItem)
        contextMenu.autoenablesItems = false
        contextMenu.delegate = self
        menuNeedsUpdate(contextMenu)
        panel.petMenu = contextMenu
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        restorePosition()
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
    deinit { NotificationCenter.default.removeObserver(self) }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let hasPostcards = model.latestAvailableTripID() != nil
        for item in menu.items where item.tag == 1 || item.tag == 2 {
            item.isEnabled = hasPostcards
        }
    }

    static func permitsDesktopPresentation(bundleURL: URL, identifier: String?) -> Bool {
        guard bundleURL.pathExtension == "app", let identifier else { return false }
        return SingleInstancePolicy.ownershipIdentifier(identifier) == "com.nebulae.travelcat"
    }
    func show() {
        // Unit-test and command-line hosts may render offscreen but must never add desktop pets.
        guard Self.permitsDesktopPresentation(bundleURL: Bundle.main.bundleURL, identifier: Bundle.main.bundleIdentifier) else { return }
        clampPosition()
        window?.orderFrontRegardless()
        scene.isActive = window?.isVisible == true
    }
    func hide() { scene.isActive = false; window?.orderOut(nil) }
    @objc private func hidePet(_ sender: NSMenuItem) { hide() }
    @objc private func performRoute(_ sender: NSMenuItem) {
        guard routes.indices.contains(sender.tag) else { return }
        routes[sender.tag]()
    }
    func locatorSelection() -> PetCompanionAnchor? {
        guard let window, window.isVisible, let screen = window.screen ?? NSScreen.screens.first else { return nil }
        return PetCompanionAnchor(appKitBounds: window.frame, screenFrame: screen.visibleFrame)
    }
    func windowDidMove(_ notification: Notification) {
        guard let window else { return }
        positionStore.save(origin: window.frame.origin, displayID: PetWindowController.displayIdentifier(for: window.screen))
    }
    @objc private func screensChanged(_ notification: Notification) { clampPosition() }
    private func clampPosition() {
        guard let window else { return }
        window.setFrame(WindowPositionStore.clamp(window.frame, to: NSScreen.screens.map(\.visibleFrame)), display: true)
    }
    private func restorePosition() {
        guard let window else { return }
        let screen = window.screen ?? NSScreen.screens.first
        let identifier = positionStore.lastDisplayIdentifier ?? PetWindowController.displayIdentifier(for: screen)
        if let frame = positionStore.restoredFrame(size: window.frame.size, displayID: identifier,
                                                  visibleFrames: NSScreen.screens.map(\.visibleFrame)) {
            window.setFrame(frame, display: false)
        } else if let visible = screen?.visibleFrame {
            window.setFrameOrigin(CGPoint(x: visible.maxX - window.frame.width - 24, y: visible.minY + 24))
        }
    }
}
