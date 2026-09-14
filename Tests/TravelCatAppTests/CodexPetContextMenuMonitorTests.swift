import CoreGraphics
import XCTest
@testable import TravelCatApp

@MainActor
final class CodexPetContextMenuMonitorTests: XCTestCase {
    func testTemporaryTestItemExistsOnlyInFastTestMode() {
        let formal = TravelCatPetMenuState(
            hasLatestPostcard: true,
            hasLatestAlbum: true,
            isFastTestEnabled: false
        )
        let fast = TravelCatPetMenuState(
            hasLatestPostcard: true,
            hasLatestAlbum: true,
            isFastTestEnabled: true
        )

        XCTAssertFalse(formal.items.contains(.action(.temporaryTest, enabled: true)))
        XCTAssertTrue(fast.items.contains(.action(.temporaryTest, enabled: true)))
    }

    func testAsyncPermissionGrantAutomaticallyStartsListenerWithoutSecondClick() {
        let backend = StubCodexPetEventTapBackend(status: .missingBoth)
        let scheduler = ManualPermissionScheduler()
        var reportedStates: [CodexPetMenuPermissionState] = []
        let monitor = CodexPetContextMenuMonitor(
            backend: backend,
            permissionScheduler: scheduler,
            selection: { nil },
            onRightClick: { _, _ in },
            permissionStateChanged: { reportedStates.append($0) }
        )

        monitor.requestPermissionAndStart()

        XCTAssertEqual(backend.requestedStatuses.count, 1)
        XCTAssertEqual(backend.startCount, 0)
        XCTAssertEqual(monitor.permissionState, CodexPetMenuPermissionState.needsBothPermissions)
        XCTAssertEqual(scheduler.pendingCount, 1)

        backend.permissionsGranted = true
        scheduler.fireNext()

        XCTAssertEqual(backend.startCount, 1)
        XCTAssertEqual(monitor.permissionState, CodexPetMenuPermissionState.ready)
        XCTAssertEqual(scheduler.pendingCount, 0)
        XCTAssertEqual(
            reportedStates,
            [CodexPetMenuPermissionState.needsBothPermissions, CodexPetMenuPermissionState.ready]
        )
    }

    func testBothMissingRequestsBothPermissionsIndependently() {
        let backend = StubCodexPetEventTapBackend(status: .missingBoth)
        let monitor = makeMonitor(backend: backend)

        monitor.requestPermissionAndStart()

        XCTAssertEqual(backend.requestedStatuses, [.missingBoth])
        XCTAssertEqual(backend.startCount, 0)
    }

    func testOnlyInputMonitoringMissingDoesNotRequestAccessibility() {
        let backend = StubCodexPetEventTapBackend(status: .missingInputMonitoring)
        let monitor = makeMonitor(backend: backend)

        monitor.requestPermissionAndStart()

        XCTAssertEqual(backend.requestedStatuses, [.missingInputMonitoring])
        XCTAssertEqual(backend.startCount, 0)
    }

    func testOnlyAccessibilityMissingDoesNotRequestInputMonitoring() {
        let backend = StubCodexPetEventTapBackend(status: .missingAccessibility)
        let monitor = makeMonitor(backend: backend)

        monitor.requestPermissionAndStart()

        XCTAssertEqual(backend.requestedStatuses, [.missingAccessibility])
        XCTAssertEqual(backend.startCount, 0)
    }

    func testMacBackendRequestsOnlyMissingPermissionsWithoutShortCircuit() {
        var inputGranted = false
        var accessibilityGranted = false
        var requests: [String] = []
        let backend = MacCodexPetContextMenuEventTapBackend(
            inputMonitoringCheck: { inputGranted },
            accessibilityCheck: { accessibilityGranted },
            requestInputMonitoring: {
                requests.append("input")
            },
            requestAccessibility: {
                requests.append("accessibility")
                accessibilityGranted = true
                return true
            }
        )

        XCTAssertFalse(backend.requestPermissions(for: .missingBoth))
        XCTAssertEqual(requests, ["input", "accessibility"])
        XCTAssertEqual(backend.permissionStatus, .missingInputMonitoring)
        requests.removeAll()
        _ = backend.requestPermissions(for: .granted)
        XCTAssertTrue(requests.isEmpty)
    }

    func testMacBackendRequestsOnlyInputMonitoringWhenAccessibilityAlreadyGranted() {
        var requests: [String] = []
        let backend = MacCodexPetContextMenuEventTapBackend(
            inputMonitoringCheck: { false },
            accessibilityCheck: { true },
            requestInputMonitoring: { requests.append("input") },
            requestAccessibility: { requests.append("accessibility"); return false }
        )

        _ = backend.requestPermissions(for: .missingInputMonitoring)

        XCTAssertEqual(requests, ["input"])
    }

    func testMacBackendRequestsOnlyAccessibilityWhenInputMonitoringAlreadyGranted() {
        var requests: [String] = []
        let backend = MacCodexPetContextMenuEventTapBackend(
            inputMonitoringCheck: { true },
            accessibilityCheck: { false },
            requestInputMonitoring: { requests.append("input") },
            requestAccessibility: { requests.append("accessibility"); return false }
        )

        _ = backend.requestPermissions(for: .missingAccessibility)

        XCTAssertEqual(requests, ["accessibility"])
    }

    func testStaggeredPermissionGrantsStartAfterSecondPermission() {
        let backend = StubCodexPetEventTapBackend(status: .missingBoth)
        let scheduler = ManualPermissionScheduler()
        let monitor = makeMonitor(backend: backend, scheduler: scheduler)

        monitor.requestPermissionAndStart()
        backend.status = .missingAccessibility
        scheduler.fireNext()
        XCTAssertEqual(backend.startCount, 0)
        XCTAssertEqual(monitor.permissionState, .needsAccessibility)
        backend.status = .granted
        scheduler.fireNext()

        XCTAssertEqual(backend.startCount, 1)
        XCTAssertEqual(monitor.permissionState, .ready)
    }

    func testTapStartFailureIsExplicitAndRetryable() {
        let backend = StubCodexPetEventTapBackend(status: .granted)
        backend.startResult = false
        let monitor = makeMonitor(backend: backend)

        monitor.start(requestPermission: false)
        XCTAssertEqual(monitor.permissionState, .unavailable("无法启动黑猫右键监听"))

        backend.startResult = true
        monitor.stop()
        XCTAssertEqual(monitor.permissionState, .needsPermission)
        monitor.start(requestPermission: false)
        XCTAssertEqual(monitor.permissionState, .ready)
    }

    private func makeMonitor(
        backend: StubCodexPetEventTapBackend,
        scheduler: ManualPermissionScheduler = ManualPermissionScheduler()
    ) -> CodexPetContextMenuMonitor {
        CodexPetContextMenuMonitor(
            backend: backend,
            permissionScheduler: scheduler,
            selection: { nil },
            onRightClick: { _, _ in }
        )
    }
}

private final class StubCodexPetEventTapBackend: CodexPetEventTapBackend {
    var status: CodexPetPermissionStatus
    var startResult = true
    var requestedStatuses: [CodexPetPermissionStatus] = []
    var startCount = 0

    init(status: CodexPetPermissionStatus) { self.status = status }

    var permissionsGranted: Bool {
        get { status.isGranted }
        set { status = newValue ? .granted : .missingBoth }
    }
    var permissionStatus: CodexPetPermissionStatus { status }

    func requestPermissions() -> Bool {
        requestedStatuses.append(status)
        return status.isGranted
    }

    func requestPermissions(for status: CodexPetPermissionStatus) -> Bool {
        requestedStatuses.append(status)
        return self.status.isGranted
    }

    func start(_ handler: @escaping (CGPoint) -> Bool) -> Bool {
        startCount += 1
        return startResult
    }

    func stop() {}
    func bypassNextRightClick() {}
}

@MainActor
private final class ManualPermissionScheduler: BubbleScheduling {
    final class Token: BubbleCancellation {
        var action: (@MainActor () -> Void)?

        init(action: @escaping @MainActor () -> Void) {
            self.action = action
        }

        func cancel() {
            action = nil
        }
    }

    private var tokens: [Token] = []

    var pendingCount: Int {
        tokens.filter { $0.action != nil }.count
    }

    func after(
        _ seconds: TimeInterval,
        _ action: @escaping @MainActor () -> Void
    ) -> BubbleCancellation {
        let token = Token(action: action)
        tokens.append(token)
        return token
    }

    func fireNext() {
        guard let token = tokens.first(where: { $0.action != nil }),
              let action = token.action else { return }
        token.action = nil
        action()
    }
}
