import AppKit
import XCTest
@testable import TravelCatApp

@MainActor
final class CodexPetInputAnchorTests: XCTestCase {
    func testInputHitUsesSharedAnchorAndRechecksProcessAndPermissions() {
        let backend = AnchorEventBackend()
        var bundle: String? = "com.openai.codex"
        var selection: CodexPetSelection? = anchor()
        var clicks = 0
        let monitor = CodexPetContextMenuMonitor(
            backend: backend, selection: { selection }, onRightClick: { _, _ in clicks += 1 },
            bundleIdentifierForOwnerPID: { _ in bundle }
        )
        monitor.start(requestPermission: false)
        XCTAssertEqual(backend.handler?(CGPoint(x: 1351, y: 198)), true)
        XCTAssertEqual(clicks, 1)
        XCTAssertEqual(backend.handler?(CGPoint(x: 1351, y: 784)), false, "AppKit coordinates are not input coordinates")
        XCTAssertEqual(backend.handler?(CGPoint(x: 70, y: 800)), false, "Old left window must not intercept")
        bundle = "com.example.spoof"
        XCTAssertEqual(backend.handler?(CGPoint(x: 1351, y: 198)), false)
        bundle = "com.openai.codex"
        backend.permissionsGranted = false
        XCTAssertEqual(backend.handler?(CGPoint(x: 1351, y: 198)), false)
        backend.permissionsGranted = true
        selection = nil
        XCTAssertEqual(backend.handler?(CGPoint(x: 1351, y: 198)), false)
        XCTAssertEqual(clicks, 1)
        monitor.stop()
    }

    private func anchor() -> CodexPetSelection {
        CodexPetSelection(ownerPID: 1129, inputBounds: CGRect(x: 1301, y: 148, width: 100, height: 109),
                          appKitBounds: CGRect(x: 1301, y: 725, width: 100, height: 109),
                          screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), source: .persistedOverlay)
    }
}

private final class AnchorEventBackend: CodexPetEventTapBackend {
    var permissionsGranted = true
    var handler: ((CGPoint) -> Bool)?
    func requestPermissions() -> Bool { permissionsGranted }
    func start(_ handler: @escaping (CGPoint) -> Bool) -> Bool { self.handler = handler; return true }
    func stop() { handler = nil }
    func bypassNextRightClick() {}
}
