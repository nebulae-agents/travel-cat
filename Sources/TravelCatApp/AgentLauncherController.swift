import AppKit
import SwiftUI
import TravelUI

/// One mailbox for postcards and agent work; separate hit testing preserves house dragging.
@MainActor
final class AgentLauncherController: NSObject, NSWindowDelegate {
    private let panel: MailboxPanel
    private let positionStore: MailboxPositionStore
    private var relativeOffset: CGPoint?
    private var inboxWindow: NSPanel?
    private var inboxOffset: CGPoint?
    private var isPositioningInbox = false
    private let viewState = MailboxViewState()
    private let action: () -> Void
    private let openPostcard: (UUID) -> Void
    private let openAlbum: () -> Void
    private weak var model: AgentWorkbenchModel?
    private weak var petModel: AppModel?
    private var anchor: NSRect?

    init(model: AgentWorkbenchModel?, petModel: AppModel? = nil, openPostcard: @escaping (UUID) -> Void = { _ in },
         openAlbum: @escaping () -> Void = {}, positionStore: MailboxPositionStore = MailboxPositionStore(), action: @escaping () -> Void) {
        self.positionStore = positionStore; self.relativeOffset = positionStore.offset; self.inboxOffset = positionStore.inboxOffset
        self.action = action; self.model = model; self.petModel = petModel
        self.openPostcard = openPostcard; self.openAlbum = openAlbum
        panel = MailboxPanel(contentRect: NSRect(origin: .zero, size: MailboxPlacement.size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.title = "小黑的邮筒"
        panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = false; panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: MailboxButtonView(state: viewState) { [weak self] in self?.toggleInbox() })
        panel.primaryAction = { [weak self] in self?.toggleInbox() }
        panel.moveTo = { [weak self] origin in
            guard let self, let anchor = self.anchor else { return }
            let offset = CGPoint(x: origin.x - anchor.minX, y: origin.y - anchor.minY)
            let frame = MailboxPlacement.frame(beside: anchor, screens: NSScreen.screens.map(\.visibleFrame), offset: offset)
            self.panel.setFrame(frame, display: true)
            self.relativeOffset = CGPoint(x: frame.minX - anchor.minX, y: frame.minY - anchor.minY)
            self.positionInbox()
        }
        panel.didEndMove = { [weak self] in
            guard let self, let offset = self.relativeOffset else { return }
            self.positionStore.save(offset)
        }
        refresh()
    }
    func update(model: AgentWorkbenchModel) { self.model = model; refresh() }
    func refresh() {
        let cards = petModel.map { pet in
            pet.unreadPostcardIDs.compactMap { id -> MailboxEntry? in
                guard let event = pet.events.first(where: { $0.id == id }) else { return nil }
                return .postcard(id: id, date: event.occurredAt)
            }
        } ?? []
        viewState.inbox = MailboxInbox.project(tasks: model?.state.tasks ?? [],
            pendingTaskIDs: (model?.permissions.map(\.taskID) ?? []) + (model?.modelApprovals.map(\.taskID) ?? []), postcards: cards)
    }
    func show(beside frame: NSRect) {
        anchor = frame
        panel.setFrame(MailboxPlacement.frame(beside: frame, screens: NSScreen.screens.map(\.visibleFrame), offset: relativeOffset), display: true)
        panel.orderFrontRegardless()
        positionInbox()
    }
    func hide() { inboxWindow?.orderOut(nil); panel.orderOut(nil) }
    func toggleInbox() {
        if inboxWindow?.isVisible == true { closeInbox(); return }
        refresh()
        let window: NSPanel
        if let existing = inboxWindow { window = existing }
        else {
            window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 390, height: 430),
                styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
            window.title = "小黑的邮筒 · 消息"
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.hidesOnDeactivate = false
            window.isMovable = true
            window.titlebarAppearsTransparent = true
            window.appearance = NSAppearance(named: .aqua)
            window.backgroundColor = NSColor(CottageTheme.paper)
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.delegate = self
            inboxWindow = window
        }
        let hosting = NSHostingView(rootView: MailboxInboxView(state: viewState,
            open: { [weak self] id in self?.openEntry(id) },
            openAgents: { [weak self] in self?.closeInbox(); self?.action() },
            openAlbum: { [weak self] in self?.closeInbox(); self?.openAlbum() },
            close: { [weak self] in self?.closeInbox() }))
        hosting.sizingOptions = []
        window.contentView = hosting
        window.setContentSize(NSSize(width: 390, height: 430))
        positionInbox(includeHidden: true)
        panel.resignKey()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    private func closeInbox() {
        inboxWindow?.orderOut(nil)
        // A nonactivating desktop panel must release key focus before navigation.
        panel.resignKey()
    }
    private func positionInbox(includeHidden: Bool = false) {
        guard let window = inboxWindow, includeHidden || window.isVisible else { return }
        isPositioningInbox = true
        window.setFrame(MailboxPlacement.inboxFrame(beside: panel.frame, size: window.frame.size,
            screens: NSScreen.screens.map(\.visibleFrame), offset: inboxOffset), display: true)
        isPositioningInbox = false
    }
    func windowDidMove(_ notification: Notification) {
        guard !isPositioningInbox, let window = notification.object as? NSWindow,
              window === inboxWindow, window.isVisible else { return }
        let offset = CGPoint(x: window.frame.minX - panel.frame.minX, y: window.frame.minY - panel.frame.minY)
        inboxOffset = offset
        positionStore.saveInbox(offset)
    }
    /// Revalidate at the moment of navigation; stale cards cannot open another task.
    func openEntry(_ id: String) {
        refresh()
        guard let entry = viewState.inbox.entries.first(where: { $0.id == id }) else { return }
        closeInbox()
        switch entry.destination {
        case .task(let taskID):
            guard model?.state.tasks.contains(where: { $0.id == taskID }) == true else { return }
            model?.openConversation(taskID)
            action()
        case .postcard(let eventID): openPostcard(eventID)
        }
    }
}

/// Own mouse tracking keeps a drag from triggering the SwiftUI button on release.
@MainActor
private final class MailboxPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var primaryAction: (() -> Void)?
    var moveTo: ((CGPoint) -> Void)?
    var didEndMove: (() -> Void)?
    private var startPointer: CGPoint?
    private var startOrigin = CGPoint.zero
    private var dragged = false
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            startPointer = convertPoint(toScreen: event.locationInWindow)
            startOrigin = frame.origin; dragged = false
        case .leftMouseDragged:
            guard let startPointer else { return }
            let point = convertPoint(toScreen: event.locationInWindow)
            let dx = point.x - startPointer.x, dy = point.y - startPointer.y
            if hypot(dx, dy) > 3 { dragged = true }
            if dragged { moveTo?(CGPoint(x: startOrigin.x + dx, y: startOrigin.y + dy)) }
        case .leftMouseUp:
            guard startPointer != nil else { return }
            startPointer = nil
            if dragged { didEndMove?() } else { primaryAction?() }
        default: super.sendEvent(event)
        }
    }
}
