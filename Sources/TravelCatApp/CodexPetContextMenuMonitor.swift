import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct CodexPetPermissionStatus: Equatable {
    let inputMonitoringGranted: Bool
    let accessibilityGranted: Bool

    static let missingBoth = Self(inputMonitoringGranted: false, accessibilityGranted: false)
    static let missingInputMonitoring = Self(inputMonitoringGranted: false, accessibilityGranted: true)
    static let missingAccessibility = Self(inputMonitoringGranted: true, accessibilityGranted: false)
    static let granted = Self(inputMonitoringGranted: true, accessibilityGranted: true)

    var isGranted: Bool { inputMonitoringGranted && accessibilityGranted }

    var message: String {
        switch (inputMonitoringGranted, accessibilityGranted) {
        case (false, false): return "需要开启输入监控和辅助功能权限"
        case (false, true): return "需要开启输入监控权限"
        case (true, false): return "需要开启辅助功能权限"
        case (true, true): return ""
        }
    }
}

enum CodexPetMenuPermissionState: Equatable {
    case ready
    case needsPermission
    case needsInputMonitoring
    case needsAccessibility
    case needsBothPermissions
    case unavailable(String)

    init(status: CodexPetPermissionStatus) {
        switch (status.inputMonitoringGranted, status.accessibilityGranted) {
        case (true, true): self = .ready
        case (false, true): self = .needsInputMonitoring
        case (true, false): self = .needsAccessibility
        case (false, false): self = .needsBothPermissions
        }
    }

    var message: String? {
        switch self {
        case .ready: return nil
        case .needsPermission, .needsBothPermissions: return CodexPetPermissionStatus.missingBoth.message
        case .needsInputMonitoring: return CodexPetPermissionStatus.missingInputMonitoring.message
        case .needsAccessibility: return CodexPetPermissionStatus.missingAccessibility.message
        case .unavailable(let message): return message
        }
    }
}

protocol CodexPetEventTapBackend: AnyObject {
    var permissionsGranted: Bool { get }
    var permissionStatus: CodexPetPermissionStatus { get }
    func requestPermissions() -> Bool
    func requestPermissions(for status: CodexPetPermissionStatus) -> Bool
    func start(_ handler: @escaping (CGPoint) -> Bool) -> Bool
    func stop()
    func bypassNextRightClick()
}

extension CodexPetEventTapBackend {
    var permissionStatus: CodexPetPermissionStatus {
        permissionsGranted ? .granted : .missingBoth
    }

    func requestPermissions(for _: CodexPetPermissionStatus) -> Bool {
        requestPermissions()
    }
}

@MainActor
final class CodexPetContextMenuMonitor {
    static let permissionRefreshInterval: TimeInterval = 0.5
    static let maximumPermissionRefreshAttempts = 240

    private let backend: CodexPetEventTapBackend
    private let permissionScheduler: BubbleScheduling
    private let selection: () -> CodexPetSelection?
    private let onRightClick: (CodexPetSelection, CGPoint) -> Void
    private let permissionStateChanged: (CodexPetMenuPermissionState) -> Void
    private let bundleIdentifierForOwnerPID: (pid_t) -> String?
    private var permissionRefreshCancellation: BubbleCancellation?
    private var remainingPermissionRefreshAttempts = 0
    private(set) var permissionState: CodexPetMenuPermissionState = .needsPermission

    init(
        backend: CodexPetEventTapBackend,
        permissionScheduler: BubbleScheduling = TimerBubbleScheduler(),
        selection: @escaping () -> CodexPetSelection?,
        onRightClick: @escaping (CodexPetSelection, CGPoint) -> Void,
        permissionStateChanged: @escaping (CodexPetMenuPermissionState) -> Void = { _ in },
        bundleIdentifierForOwnerPID: @escaping (pid_t) -> String? = CodexPetLocator.currentBundleIdentifier(forOwnerPID:)
    ) {
        self.backend = backend
        self.permissionScheduler = permissionScheduler
        self.selection = selection
        self.onRightClick = onRightClick
        self.permissionStateChanged = permissionStateChanged
        self.bundleIdentifierForOwnerPID = bundleIdentifierForOwnerPID
    }

    convenience init(
        locator: @escaping () -> CodexPetSelection?,
        onRightClick: @escaping (CodexPetSelection, CGPoint) -> Void,
        permissionStateChanged: @escaping (CodexPetMenuPermissionState) -> Void = { _ in }
    ) {
        self.init(
            backend: MacCodexPetContextMenuEventTapBackend(),
            selection: locator,
            onRightClick: onRightClick,
            permissionStateChanged: permissionStateChanged
        )
    }

    func start(requestPermission: Bool) {
        var permissionStatus = backend.permissionStatus
        if requestPermission && !permissionStatus.isGranted {
            _ = backend.requestPermissions(for: permissionStatus)
            permissionStatus = backend.permissionStatus
        }
        guard permissionStatus.isGranted else {
            backend.stop()
            setPermissionState(CodexPetMenuPermissionState(status: permissionStatus))
            return
        }
        guard backend.start(handleRightClick(at:)) else {
            cancelPermissionRefresh()
            setPermissionState(.unavailable("无法启动黑猫右键监听"))
            return
        }
        cancelPermissionRefresh()
        setPermissionState(.ready)
    }

    func stop() {
        cancelPermissionRefresh()
        backend.stop()
        setPermissionState(.needsPermission)
    }

    func requestPermissionAndStart() {
        cancelPermissionRefresh()
        start(requestPermission: true)
        guard !backend.permissionStatus.isGranted else { return }
        remainingPermissionRefreshAttempts = Self.maximumPermissionRefreshAttempts
        schedulePermissionRefresh()
    }

    func bypassNextRightClick() {
        backend.bypassNextRightClick()
    }

    private func handleRightClick(at point: CGPoint) -> Bool {
        guard let selected = selection(), selected.ownerPID > 0,
              bundleIdentifierForOwnerPID(selected.ownerPID) == "com.openai.codex" else { return false }
        let input = CodexPetContextMenuInput(
            eventType: .rightMouseDown,
            point: point,
            petBounds: selected.inputBounds,
            permissionsGranted: backend.permissionStatus.isGranted,
            bypassNextRightClick: false
        )
        guard CodexPetContextMenuPolicy.decision(input) == .intercept else { return false }
        onRightClick(selected, point)
        return true
    }

    private func schedulePermissionRefresh() {
        guard remainingPermissionRefreshAttempts > 0 else { return }
        remainingPermissionRefreshAttempts -= 1
        permissionRefreshCancellation = permissionScheduler.after(
            Self.permissionRefreshInterval
        ) { [weak self] in
            guard let self else { return }
            self.permissionRefreshCancellation = nil
            let status = self.backend.permissionStatus
            if status.isGranted {
                self.start(requestPermission: false)
            } else {
                self.setPermissionState(CodexPetMenuPermissionState(status: status))
                self.schedulePermissionRefresh()
            }
        }
    }

    private func cancelPermissionRefresh() {
        permissionRefreshCancellation?.cancel()
        permissionRefreshCancellation = nil
        remainingPermissionRefreshAttempts = 0
    }

    private func setPermissionState(_ state: CodexPetMenuPermissionState) {
        guard permissionState != state else { return }
        permissionState = state
        permissionStateChanged(state)
    }
}

final class MacCodexPetContextMenuEventTapBackend: NSObject, CodexPetEventTapBackend {
    private var eventTap: CFMachPort?
    private var eventSource: CFRunLoopSource?
    private var rightClickHandler: ((CGPoint) -> Bool)?
    private var shouldBypassNextRightClick = false

    private let inputMonitoringCheck: () -> Bool
    private let accessibilityCheck: () -> Bool
    private let requestInputMonitoring: () -> Void
    private let requestAccessibility: () -> Bool

    init(
        inputMonitoringCheck: @escaping () -> Bool = CGPreflightListenEventAccess,
        accessibilityCheck: @escaping () -> Bool = AXIsProcessTrusted,
        requestInputMonitoring: @escaping () -> Void = { _ = CGRequestListenEventAccess() },
        requestAccessibility: @escaping () -> Bool = {
            let option = "AXTrustedCheckOptionPrompt"
            return AXIsProcessTrustedWithOptions([option: true] as CFDictionary)
        }
    ) {
        self.inputMonitoringCheck = inputMonitoringCheck
        self.accessibilityCheck = accessibilityCheck
        self.requestInputMonitoring = requestInputMonitoring
        self.requestAccessibility = requestAccessibility
    }

    var permissionStatus: CodexPetPermissionStatus {
        CodexPetPermissionStatus(
            inputMonitoringGranted: inputMonitoringCheck(),
            accessibilityGranted: accessibilityCheck()
        )
    }

    var permissionsGranted: Bool {
        permissionStatus.isGranted
    }

    func requestPermissions() -> Bool {
        requestPermissions(for: permissionStatus)
    }

    func requestPermissions(for status: CodexPetPermissionStatus) -> Bool {
        if !status.inputMonitoringGranted {
            requestInputMonitoring()
        }
        if !status.accessibilityGranted {
            _ = requestAccessibility()
        }
        return permissionStatus.isGranted
    }

    func start(_ handler: @escaping (CGPoint) -> Bool) -> Bool {
        stop()
        rightClickHandler = handler

        let eventMask = CGEventMask(1 << CGEventType.rightMouseDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: codexPetEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            rightClickHandler = nil
            return false
        }
        eventTap = tap
        CGEvent.tapEnable(tap: tap, enable: true)

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            stop()
            rightClickHandler = nil
            return false
        }
        eventSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        return true
    }

    func stop() {
        if let source = eventSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            eventSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
        shouldBypassNextRightClick = false
        rightClickHandler = nil
    }

    func bypassNextRightClick() {
        shouldBypassNextRightClick = true
    }

    fileprivate func shouldPassThrough(point: CGPoint, type: CGEventType) -> Bool {
        guard type == .rightMouseDown else { return true }
        if shouldBypassNextRightClick {
            shouldBypassNextRightClick = false
            return true
        }
        guard let rightClickHandler else { return true }
        let shouldIntercept = rightClickHandler(point)
        return !shouldIntercept
    }

    fileprivate func handleTapDisabled() {
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }
}

private func codexPetEventTapCallback(
    proxy _: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let backend = Unmanaged<MacCodexPetContextMenuEventTapBackend>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        backend.handleTapDisabled()
        return Unmanaged.passUnretained(event)
    }
    if type != .rightMouseDown {
        return Unmanaged.passUnretained(event)
    }
    if backend.shouldPassThrough(point: event.location, type: type) {
        return Unmanaged.passUnretained(event)
    }
    return nil
}
