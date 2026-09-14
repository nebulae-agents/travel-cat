import AppKit
import SwiftUI
import TravelStorage

@MainActor
protocol BubbleCancellation: AnyObject {
    func cancel()
}

@MainActor
protocol BubbleScheduling: AnyObject {
    func after(
        _ seconds: TimeInterval,
        _ action: @escaping @MainActor () -> Void
    ) -> BubbleCancellation
}

@MainActor
protocol BubbleCollapseAnimating: AnyObject {
    func animateSlip(
        _ view: NSView,
        toward edge: PetCompanionEdge,
        completion: @escaping @MainActor () -> Void
    ) -> BubbleCancellation
}

enum PetTravelBubbleCollapseGeometry {
    private static let scale: CGFloat = 0.72

    static func scaledFrame(in bounds: NSRect, toward edge: PetCompanionEdge) -> NSRect {
        let size = NSSize(width: bounds.width * scale, height: bounds.height * scale)
        switch edge {
        case .bottomTrailing:
            return NSRect(x: bounds.maxX - size.width, y: bounds.minY, width: size.width, height: size.height)
        case .bottomLeading:
            return NSRect(x: bounds.minX, y: bounds.minY, width: size.width, height: size.height)
        case .trailing:
            return NSRect(
                x: bounds.maxX - size.width,
                y: bounds.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
        case .leading:
            return NSRect(
                x: bounds.minX,
                y: bounds.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
        }
    }
}

@MainActor
private final class AppKitBubbleCollapseCancellation: BubbleCancellation, @unchecked Sendable {
    weak var view: NSView?
    private(set) var isCancelled = false

    init(view: NSView) {
        self.view = view
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        view?.layer?.removeAllAnimations()
        view?.alphaValue = 1
    }

    func complete(_ completion: @MainActor () -> Void) {
        guard !isCancelled else { return }
        isCancelled = true
        completion()
    }
}

@MainActor
final class AppKitBubbleCollapseAnimator: BubbleCollapseAnimating {
    static let duration: TimeInterval = 0.18

    func animateSlip(
        _ view: NSView,
        toward edge: PetCompanionEdge,
        completion: @escaping @MainActor () -> Void
    ) -> BubbleCancellation {
        view.wantsLayer = true
        let token = AppKitBubbleCollapseCancellation(view: view)
        let targetFrame = PetTravelBubbleCollapseGeometry.scaledFrame(
            in: view.bounds,
            toward: edge
        )
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            view.animator().alphaValue = 0
            view.animator().frame = targetFrame
        } completionHandler: {
            Task { @MainActor in
                token.complete(completion)
            }
        }
        return token
    }
}

@MainActor
private final class TimerBubbleCancellation: BubbleCancellation {
    private var timer: Timer?

    init(timer: Timer) {
        self.timer = timer
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }
}

@MainActor
final class TimerBubbleScheduler: BubbleScheduling {
    func after(
        _ seconds: TimeInterval,
        _ action: @escaping @MainActor () -> Void
    ) -> BubbleCancellation {
        let timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            Task { @MainActor in action() }
        }
        return TimerBubbleCancellation(timer: timer)
    }
}

final class PetTravelBubblePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .mouseMoved {
            updateMousePassthrough(atScreenPoint: NSEvent.mouseLocation)
        }
        super.sendEvent(event)
    }

    func updateMousePassthrough(atScreenPoint point: NSPoint) {
        guard let contentView else {
            ignoresMouseEvents = true
            return
        }
        let contentPoint = convertPoint(fromScreen: point)
        ignoresMouseEvents = contentView.hitTest(contentPoint) == nil
    }
}

@MainActor
final class PetTravelBubbleHostingView: NSHostingView<AnyView> {
    enum HitRegion {
        case full
        case paw
        case disabled
    }

    var hitRegion: HitRegion = .full

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        switch hitRegion {
        case .disabled:
            return nil
        case .paw:
            let diameter = min(bounds.width - 16, bounds.height - 16)
            guard diameter > 0 else { return nil }
            let radius = diameter / 2
            let center = NSPoint(x: bounds.midX, y: bounds.midY)
            let normalizedX = (point.x - center.x) / radius
            let normalizedY = (point.y - center.y) / radius
            guard normalizedX * normalizedX + normalizedY * normalizedY <= 1 else {
                return nil
            }
        case .full:
            break
        }
        return super.hitTest(point)
    }
}

private final class BubbleEventMonitorToken: @unchecked Sendable {
    private var raw: Any?

    init(_ raw: Any) {
        self.raw = raw
    }

    deinit {
        MainActor.assumeIsolated {
            if let raw { NSEvent.removeMonitor(raw) }
        }
    }
}

@MainActor
final class PetTravelBubbleController: NSWindowController {
    enum Presentation: Equatable {
        case hidden
        case slip
        case collapsing
        case paw
    }

    static let slipSize = NSSize(width: 286, height: 138)
    static let pawSize = NSSize(width: 66, height: 64)
    private static let collapseDelay: TimeInterval = 8
    private static let followDelay: TimeInterval = 0.25

    private final class Session {
        let delivery: PetTravelPromptDelivery
        let isTestJourney: Bool
        let onTap: () -> Void
        let onRouteSelected: (PetTravelRoute) -> Void
        let onAvailableForReplacement: () -> Void
        let onTestRequested: (() -> Void)?
        var didTap = false
        var replacementSignaled = false

        init(
            delivery: PetTravelPromptDelivery,
            isTestJourney: Bool,
            onTap: @escaping () -> Void,
            onRouteSelected: @escaping (PetTravelRoute) -> Void,
            onTestRequested: (() -> Void)?,
            onAvailableForReplacement: @escaping () -> Void
        ) {
            self.delivery = delivery
            self.isTestJourney = isTestJourney
            self.onTap = onTap
            self.onRouteSelected = onRouteSelected
            self.onTestRequested = onTestRequested
            self.onAvailableForReplacement = onAvailableForReplacement
        }
    }

    private(set) var presentation: Presentation = .hidden
    private(set) var frameUpdateCount = 0
    private(set) var rootViewInstallCount = 0
    private(set) var renderedEdge: PetCompanionEdge?
    private var collapseToken: BubbleCancellation?
    private var collapseAnimationToken: BubbleCancellation?
    private var followToken: BubbleCancellation?
    private var globalMouseMonitor: BubbleEventMonitorToken?
    private var session: Session?
    private var placement: PetCompanionPlacement?
    private var menuActionHandlers: [Int: @MainActor () -> Void] = [:]
    private var nextMenuActionID = 0
    private var testActionsEnabled = false
    private let locate: () -> PetCompanionAnchor?
    private let scheduler: BubbleScheduling
    private let collapseAnimator: BubbleCollapseAnimating?
    private let tapMenuEnabled: Bool

    convenience init(locator: @escaping () -> PetCompanionAnchor?, tapMenuEnabled: Bool = false) {
        self.init(
            locator: locator,
            scheduler: TimerBubbleScheduler(),
            collapseAnimator: AppKitBubbleCollapseAnimator(),
            tapMenuEnabled: tapMenuEnabled
        )
    }

    convenience init(
        locator: @escaping () -> PetCompanionAnchor?,
        scheduler: BubbleScheduling,
        tapMenuEnabled: Bool = false
    ) {
        self.init(locator: locator, scheduler: scheduler, collapseAnimator: nil, tapMenuEnabled: tapMenuEnabled)
    }

    init(
        locator: @escaping () -> PetCompanionAnchor?,
        scheduler: BubbleScheduling,
        collapseAnimator: BubbleCollapseAnimating?,
        tapMenuEnabled: Bool = false
    ) {
        locate = locator
        self.scheduler = scheduler
        self.collapseAnimator = collapseAnimator
        self.tapMenuEnabled = tapMenuEnabled
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @discardableResult
    func show(
        delivery: PetTravelPromptDelivery,
        isTestJourney: Bool = false,
        onTap: @escaping () -> Void,
        onRouteSelected: ((PetTravelRoute) -> Void)? = nil,
        onTestRequested: (() -> Void)? = nil,
        onAvailableForReplacement: @escaping () -> Void
    ) -> Bool {
        guard let selection = locate(),
              let placement = Self.placement(for: selection, companionSize: Self.slipSize)
        else {
            return false
        }

        cancelTimers()
        session = nil

        let newSession = Session(
            delivery: delivery,
            isTestJourney: isTestJourney,
            onTap: onTap,
            onRouteSelected: onRouteSelected ?? { _ in onTap() },
            onTestRequested: onTestRequested,
            onAvailableForReplacement: onAvailableForReplacement
        )
        session = newSession
        self.placement = placement
        presentation = .slip

        let panel: PetTravelBubblePanel
        if let existingPanel = window as? PetTravelBubblePanel {
            panel = existingPanel
        } else {
            panel = Self.makePanel()
            window = panel
            startMousePassthroughMonitoring(panel)
        }
        installRootView(for: newSession, placement: placement)
        updateFrame(to: placement.frame, force: true)
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()

        collapseToken = scheduler.after(isTestJourney ? 2 : Self.collapseDelay) { [weak self, weak newSession] in
            guard let self, let newSession else { return }
            self.collapseToPaw(newSession)
        }
        startFollowing(newSession)
        return true
    }

    func performTap() {
        guard let session else { return }
        handleTap(session)
    }

    func settingsDidChange(followCodexPet: Bool) {
        guard !followCodexPet, let session else { return }
        let shouldSignalReplacement = !session.replacementSignaled
        session.replacementSignaled = true
        let onAvailableForReplacement = session.onAvailableForReplacement

        hide(session)
        if shouldSignalReplacement {
            onAvailableForReplacement()
        }
    }

    static func shouldIncludeTestAction(
        testActionsEnabled: Bool,
        hasCallback: Bool
    ) -> Bool {
        testActionsEnabled && hasCallback
    }

    func setTestActionsEnabled(_ enabled: Bool) {
        testActionsEnabled = enabled
    }

    func dismissPresentation() {
        guard let session else {
            window?.orderOut(nil)
            presentation = .hidden
            return
        }
        hide(session)
    }

    private static func placement(
        for selection: PetCompanionAnchor,
        companionSize: NSSize
    ) -> PetCompanionPlacement? {
        PetCompanionLayout.place(
            anchor: selection.appKitBounds,
            companionSize: companionSize,
            visibleFrame: selection.screenFrame
        )
    }

    private static func makePanel() -> PetTravelBubblePanel {
        let panel = PetTravelBubblePanel(
            contentRect: NSRect(origin: .zero, size: slipSize),
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.worksWhenModal = true
        panel.acceptsMouseMovedEvents = true
        return panel
    }

    private func installRootView(for session: Session, placement: PetCompanionPlacement) {
        let content = PetTravelBubbleContent(delivery: session.delivery)
        let rootView = AnyView(
            PetTravelBubbleView(
                content: session.isTestJourney ? content.markedAsTestJourney : content,
                isCollapsed: presentation == .paw,
                edge: placement.edge,
                onTap: { [weak self, weak session] in
                    guard let self, let session else { return }
                    self.handleTap(session)
                }
            )
        )

        let hitRegion: PetTravelBubbleHostingView.HitRegion = presentation == .paw ? .paw : .full
        if let hostingView = window?.contentView as? PetTravelBubbleHostingView {
            hostingView.rootView = rootView
            hostingView.hitRegion = hitRegion
            hostingView.alphaValue = 1
        } else {
            let hostingView = PetTravelBubbleHostingView(rootView: rootView)
            hostingView.sizingOptions = []
            hostingView.hitRegion = hitRegion
            window?.contentView = hostingView
        }
        window?.contentView?.frame = NSRect(origin: .zero, size: currentCompanionSize)
        renderedEdge = placement.edge
        rootViewInstallCount += 1
    }

    private func collapseToPaw(_ expectedSession: Session) {
        guard session === expectedSession, presentation == .slip else { return }
        collapseToken = nil
        guard let selection = locate(),
              let pawPlacement = Self.placement(for: selection, companionSize: Self.pawSize)
        else {
            failClosed(expectedSession)
            return
        }
        followToken?.cancel()
        followToken = nil

        guard let collapseAnimator,
              let panel = window as? PetTravelBubblePanel,
              let hostingView = panel.contentView as? PetTravelBubbleHostingView
        else {
            finishCollapse(expectedSession, placement: pawPlacement)
            signalReplacementOnce(expectedSession)
            return
        }

        presentation = .collapsing
        hostingView.hitRegion = .disabled
        panel.ignoresMouseEvents = true
        collapseAnimationToken = collapseAnimator.animateSlip(
            hostingView,
            toward: pawPlacement.edge
        ) { [weak self, weak expectedSession] in
            guard let self, let expectedSession else { return }
            self.finishCollapse(expectedSession, placement: pawPlacement)
        }
        signalReplacementOnce(expectedSession)
    }

    private func finishCollapse(
        _ expectedSession: Session,
        placement pawPlacement: PetCompanionPlacement
    ) {
        guard session === expectedSession,
              presentation == .slip || presentation == .collapsing
        else { return }
        collapseAnimationToken = nil
        presentation = .paw
        placement = pawPlacement
        installRootView(for: expectedSession, placement: pawPlacement)
        updateFrame(to: pawPlacement.frame, force: true)
        refreshMousePassthrough()
        startFollowing(expectedSession)
    }

    private func handleTap(_ expectedSession: Session) {
        guard session === expectedSession, !expectedSession.didTap else { return }
        expectedSession.didTap = true
        let shouldSignalReplacement = !expectedSession.replacementSignaled
        expectedSession.replacementSignaled = true
        let onTap = expectedSession.onTap
        let onRouteSelected = expectedSession.onRouteSelected
        let requestedTestAction = expectedSession.onTestRequested
        let onTestRequested = Self.shouldIncludeTestAction(
            testActionsEnabled: testActionsEnabled,
            hasCallback: requestedTestAction != nil
        ) ? requestedTestAction : nil
        let onAvailableForReplacement = expectedSession.onAvailableForReplacement

        hide(expectedSession)

        if tapMenuEnabled && ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            presentTapMenu(
                onRouteSelected: onRouteSelected,
                availableRoutes: bubbleMenuRoutes(for: expectedSession.delivery),
                onTap: onTap,
                onTestRequested: onTestRequested
            )
        } else {
            onTap()
        }
        if shouldSignalReplacement {
            onAvailableForReplacement()
        }
    }

    private func presentTapMenu(
        onRouteSelected: @escaping (PetTravelRoute) -> Void,
        availableRoutes: [PetTravelRoute],
        onTap: @escaping () -> Void,
        onTestRequested: (() -> Void)?
    ) {
        var handled = false
        var actionIDs: [Int] = []
        let menu = NSMenu()

        var uniqueRoutes: [PetTravelRoute] = []
        for route in availableRoutes where !uniqueRoutes.contains(route) {
            uniqueRoutes.append(route)
        }
        for route in uniqueRoutes {
            let routeID = nextMenuActionID
            nextMenuActionID += 1
            actionIDs.append(routeID)
            menuActionHandlers[routeID] = {
                handled = true
                onRouteSelected(route)
            }
            let item = NSMenuItem(
                title: menuTitle(for: route),
                action: #selector(executeMenuAction(_:)),
                keyEquivalent: ""
            )
            item.tag = routeID
            item.target = self
            menu.addItem(item)
        }

        if let onTestRequested {
            let testID = nextMenuActionID
            nextMenuActionID += 1
            actionIDs.append(testID)
            menuActionHandlers[testID] = {
                handled = true
                onTestRequested()
            }
            let item = NSMenuItem(
                title: "测试",
                action: #selector(executeMenuAction(_:)),
                keyEquivalent: ""
            )
            item.tag = testID
            item.target = self
            menu.addItem(item)
        }

        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)

        if !handled {
            onTap()
        }

        for actionID in actionIDs {
            menuActionHandlers[actionID] = nil
        }
    }

    private func bubbleMenuRoutes(for delivery: PetTravelPromptDelivery) -> [PetTravelRoute] {
        let routes: [PetTravelRoute]
        switch delivery {
        case .prompt(.postcardReady(let eventID, let tripID, _, _, _)):
            routes = [.status, .postcard(eventID: eventID, tripID: tripID)]
        case .prompt(.returned(_, let tripID, _)):
            routes = [.status, .album(tripID)]
        case .prompt(.departed), .summary:
            routes = [.status]
        }
        return routes
    }

    private func menuTitle(for route: PetTravelRoute) -> String {
        switch route {
        case .status:
            return "查看状态"
        case .postcard:
            return "查看明信片"
        case .album:
            return "查看旅行册"
        }
    }

    @objc private func executeMenuAction(_ sender: NSMenuItem) {
        guard let action = menuActionHandlers[sender.tag] else { return }
        action()
    }

    private func signalReplacementOnce(_ expectedSession: Session) {
        guard session === expectedSession, !expectedSession.replacementSignaled else { return }
        expectedSession.replacementSignaled = true
        expectedSession.onAvailableForReplacement()
    }

    private func startFollowing(_ expectedSession: Session) {
        followToken?.cancel()
        followToken = scheduler.after(Self.followDelay) { [weak self, weak expectedSession] in
            guard let self, let expectedSession else { return }
            self.follow(expectedSession)
        }
    }

    private func follow(_ expectedSession: Session) {
        guard session === expectedSession,
              presentation == .slip || presentation == .paw
        else {
            return
        }
        followToken = nil
        guard let selection = locate(),
              let newPlacement = Self.placement(
                for: selection,
                companionSize: currentCompanionSize
              )
        else {
            failClosed(expectedSession)
            return
        }

        let edgeChanged = placement?.edge != newPlacement.edge
        placement = newPlacement
        if edgeChanged {
            installRootView(for: expectedSession, placement: newPlacement)
        }
        updateFrame(to: newPlacement.frame, force: false)
        refreshMousePassthrough()
        startFollowing(expectedSession)
    }

    private func failClosed(_ expectedSession: Session) {
        guard session === expectedSession else { return }
        let shouldSignalReplacement = !expectedSession.replacementSignaled
        expectedSession.replacementSignaled = true
        let onAvailableForReplacement = expectedSession.onAvailableForReplacement
        hide(expectedSession)
        if shouldSignalReplacement {
            onAvailableForReplacement()
        }
    }

    private func hide(_ expectedSession: Session) {
        guard session === expectedSession else { return }
        cancelTimers()
        session = nil
        placement = nil
        presentation = .hidden
        window?.orderOut(nil)
    }

    private func cancelTimers() {
        collapseToken?.cancel()
        collapseToken = nil
        collapseAnimationToken?.cancel()
        collapseAnimationToken = nil
        followToken?.cancel()
        followToken = nil
    }

    private func updateFrame(to frame: NSRect, force: Bool) {
        guard let window, force || window.frame != frame else { return }
        window.setFrame(frame, display: true)
        frameUpdateCount += 1
    }

    private var currentCompanionSize: NSSize {
        presentation == .paw ? Self.pawSize : Self.slipSize
    }

    private func startMousePassthroughMonitoring(_ panel: PetTravelBubblePanel) {
        guard globalMouseMonitor == nil else { return }
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak panel] _ in
            Task { @MainActor in
                panel?.updateMousePassthrough(atScreenPoint: NSEvent.mouseLocation)
            }
        }
        globalMouseMonitor = monitor.map(BubbleEventMonitorToken.init)
    }

    private func refreshMousePassthrough() {
        guard let panel = window as? PetTravelBubblePanel else { return }
        if presentation == .paw {
            panel.updateMousePassthrough(atScreenPoint: NSEvent.mouseLocation)
        } else {
            panel.ignoresMouseEvents = false
        }
    }
}
