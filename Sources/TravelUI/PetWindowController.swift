import AppKit
import CoreGraphics
import SwiftUI

@MainActor
public final class PetPanel: NSPanel {
    private var dragStartEvent: NSEvent?
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }

    public override func sendEvent(_ event: NSEvent) {
        if event.type == .mouseMoved {
            updateMousePassthrough(atScreenPoint: NSEvent.mouseLocation)
        }
        if event.type == .leftMouseDown {
            dragStartEvent = event
        } else if event.type == .leftMouseDragged, let dragStartEvent {
            performDrag(with: dragStartEvent)
            self.dragStartEvent = nil
            return
        } else if event.type == .leftMouseUp {
            dragStartEvent = nil
        }
        super.sendEvent(event)
    }

    public func updateMousePassthrough(atScreenPoint point: CGPoint) {
        guard let contentView else {
            ignoresMouseEvents = true
            return
        }
        let contentPoint = convertPoint(fromScreen: point)
        ignoresMouseEvents = contentView.hitTest(contentPoint) == nil
    }
}

@MainActor
public final class TransparentHostingView: NSHostingView<AnyView> {
    private var alphaCache: NSBitmapImageRep?
    private var cachedBounds = CGRect.null

    public override func layout() {
        super.layout()
        alphaCache = nil
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point), let target = super.hitTest(point) else { return nil }
        guard renderedAlpha(at: point) > 0.02 else { return nil }
        return target
    }

    private func renderedAlpha(at point: CGPoint) -> CGFloat {
        if needsDisplay { alphaCache = nil }
        if alphaCache == nil || cachedBounds != bounds {
            displayIfNeeded()
            guard let bitmap = bitmapImageRepForCachingDisplay(in: bounds) else { return 1 }
            cacheDisplay(in: bounds, to: bitmap)
            alphaCache = bitmap
            cachedBounds = bounds
        }
        guard let alphaCache else { return 1 }
        let scaleX = CGFloat(alphaCache.pixelsWide) / max(bounds.width, 1)
        let scaleY = CGFloat(alphaCache.pixelsHigh) / max(bounds.height, 1)
        let x = min(max(Int((point.x - bounds.minX) * scaleX), 0), alphaCache.pixelsWide - 1)
        let y = min(max(Int((point.y - bounds.minY) * scaleY), 0), alphaCache.pixelsHigh - 1)
        return alphaCache.colorAt(x: x, y: y)?.alphaComponent ?? 0
    }
}

private final class EventMonitorToken: @unchecked Sendable {
    private var raw: Any?

    init(_ raw: Any) { self.raw = raw }

    deinit {
        MainActor.assumeIsolated {
            if let raw { NSEvent.removeMonitor(raw) }
        }
    }
}

@MainActor
private final class NativePassthroughRootView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let target = super.hitTest(point), target !== self else { return nil }
        return target
    }
}

@MainActor
public final class WindowPositionStore {
    private let defaults: UserDefaults
    private let keyPrefix = "travel-cat.window-origin."
    private let lastDisplayKey = "travel-cat.window-last-display"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func save(origin: CGPoint, displayID: String) {
        defaults.set([Double(origin.x), Double(origin.y)], forKey: keyPrefix + displayID)
        defaults.set(displayID, forKey: lastDisplayKey)
    }

    public var lastDisplayIdentifier: String? {
        defaults.string(forKey: lastDisplayKey)
    }

    public func restoredFrame(
        size: CGSize,
        displayID: String,
        visibleFrames: [CGRect]
    ) -> CGRect? {
        guard let pair = defaults.array(forKey: keyPrefix + displayID) as? [Double],
              pair.count == 2,
              pair[0].isFinite,
              pair[1].isFinite,
              size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0 else { return nil }
        return Self.clamp(
            CGRect(x: pair[0], y: pair[1], width: size.width, height: size.height),
            to: visibleFrames
        )
    }

    public static func clamp(_ frame: CGRect, to visibleFrames: [CGRect]) -> CGRect {
        guard !visibleFrames.isEmpty else { return frame }
        let destination = visibleFrames.max { lhs, rhs in
            let lhsIntersection = lhs.intersection(frame)
            let rhsIntersection = rhs.intersection(frame)
            let lhsArea = lhsIntersection.isNull ? 0 : lhsIntersection.width * lhsIntersection.height
            let rhsArea = rhsIntersection.isNull ? 0 : rhsIntersection.width * rhsIntersection.height
            if lhsArea != rhsArea { return lhsArea < rhsArea }
            return squaredDistance(lhs.center, frame.center) > squaredDistance(rhs.center, frame.center)
        } ?? visibleFrames[0]

        var result = frame
        result.size.width = min(frame.width, destination.width)
        result.size.height = min(frame.height, destination.height)
        result.origin.x = min(max(frame.minX, destination.minX), destination.maxX - result.width)
        result.origin.y = min(max(frame.minY, destination.minY), destination.maxY - result.height)
        return result
    }

    private static func squaredDistance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

@MainActor
public final class PetWindowController: NSWindowController, NSWindowDelegate {
    public static let compactSize = CGSize(width: 240, height: 280)

    private let positionStore: WindowPositionStore
    private var globalMouseMonitor: EventMonitorToken?

    public static func makeWindow(content: AnyView) -> PetPanel {
        let panel = PetPanel(
            contentRect: CGRect(origin: .zero, size: compactSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [
            .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
        ]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        let hostingView = TransparentHostingView(rootView: content)
        hostingView.sizingOptions = []
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostingView
        return panel
    }

    public init(
        content: AnyView,
        positionStore: WindowPositionStore = WindowPositionStore()
    ) {
        self.positionStore = positionStore
        let panel = Self.makeWindow(content: content)
        super.init(window: panel)
        panel.delegate = self
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak panel] _ in
            Task { @MainActor in
                panel?.updateMousePassthrough(atScreenPoint: NSEvent.mouseLocation)
            }
        }
        globalMouseMonitor = monitor.map(EventMonitorToken.init)
        restorePosition()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    public func setContent(_ content: AnyView) {
        let hostingView = TransparentHostingView(rootView: content)
        hostingView.sizingOptions = []
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        window?.contentView = hostingView
    }

    public func setStartupErrorContent(message: String) {
        guard let window else { return }
        let size = window.contentLayoutRect.size
        let root = NativePassthroughRootView(frame: CGRect(origin: .zero, size: size))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor
        root.autoresizingMask = [.width, .height]
        root.setAccessibilityLabel("旅行数据暂时无法读取")
        root.setAccessibilityHelp(message)

        let card = NSVisualEffectView(frame: CGRect(x: 12, y: 12, width: size.width - 24, height: size.height - 24))
        card.material = .popover
        card.blendingMode = .withinWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 18
        card.autoresizingMask = [.width, .height]

        let icon = NSImageView(frame: CGRect(x: (card.bounds.width - 42) / 2, y: card.bounds.height - 78, width: 42, height: 42))
        icon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        icon.contentTintColor = .systemOrange
        icon.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        card.addSubview(icon)

        let title = NSTextField(labelWithString: "旅行数据暂时无法读取")
        title.font = .boldSystemFont(ofSize: 15)
        title.alignment = .center
        title.frame = CGRect(x: 20, y: card.bounds.height - 112, width: card.bounds.width - 40, height: 22)
        title.autoresizingMask = [.width, .minYMargin]
        card.addSubview(title)

        let detail = NSTextField(wrappingLabelWithString: message)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        detail.frame = CGRect(x: 20, y: 34, width: card.bounds.width - 40, height: card.bounds.height - 160)
        detail.autoresizingMask = [.width, .height]
        card.addSubview(detail)

        root.addSubview(card)
        window.contentView = root
    }

    public func showPet() {
        window?.orderFrontRegardless()
    }

    public func resize(for presentation: PetPresentation) {
        let size: CGSize
        switch presentation {
        case .pet, .awayTag:
            size = Self.compactSize
        case .status, .supplies:
            size = CGSize(width: 320, height: 360)
        case .postcard:
            size = CGSize(width: 420, height: 560)
        case .album:
            size = CGSize(width: 620, height: 620)
        }
        guard let window else { return }
        var frame = window.frame
        frame.origin.y += frame.height - size.height
        frame.size = size
        window.setFrame(WindowPositionStore.clamp(frame, to: NSScreen.screens.map(\.visibleFrame)), display: true)
    }

    public func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let screen = window.screen ?? nearestScreen(to: window.frame)
        positionStore.save(origin: window.frame.origin, displayID: Self.displayIdentifier(for: screen))
    }

    /// Reclaims a window after displays have been disconnected without interfering with live dragging.
    public func ensureWindowIsVisible() {
        guard let window else { return }
        let clamped = WindowPositionStore.clamp(window.frame, to: NSScreen.screens.map(\.visibleFrame))
        if clamped != window.frame {
            window.setFrame(clamped, display: true)
        }
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        ensureWindowIsVisible()
    }

    public static func displayIdentifier(for screen: NSScreen?) -> String {
        guard let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return "default"
        }
        let displayID = CGDirectDisplayID(number.uint32Value)
        let uuidString: String?
        if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() {
            uuidString = CFUUIDCreateString(nil, uuid) as String
        } else {
            uuidString = nil
        }
        return stableDisplayIdentifier(displayID: displayID, uuidString: uuidString)
    }

    nonisolated public static func stableDisplayIdentifier(
        displayID: CGDirectDisplayID,
        uuidString: String?
    ) -> String {
        if let uuidString, !uuidString.isEmpty {
            return "display-uuid.\(uuidString)"
        }
        return "display-id.\(displayID)"
    }

    private func restorePosition() {
        guard let window else { return }
        let screens = NSScreen.screens
        let preferred = window.screen ?? screens.first
        let identifier = positionStore.lastDisplayIdentifier ?? Self.displayIdentifier(for: preferred)
        if let restored = positionStore.restoredFrame(
            size: window.frame.size,
            displayID: identifier,
            visibleFrames: screens.map(\.visibleFrame)
        ) {
            window.setFrame(restored, display: false)
        } else if let visibleFrame = preferred?.visibleFrame {
            window.setFrameOrigin(CGPoint(x: visibleFrame.maxX - window.frame.width - 24, y: visibleFrame.minY + 24))
        }
    }

    private func nearestScreen(to frame: CGRect) -> NSScreen? {
        NSScreen.screens.min {
            let lhs = CGPoint(x: $0.visibleFrame.midX, y: $0.visibleFrame.midY)
            let rhs = CGPoint(x: $1.visibleFrame.midX, y: $1.visibleFrame.midY)
            return Self.distance(lhs, frame.center) < Self.distance(rhs, frame.center)
        }
    }

    private static func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }
}
