import AppKit
import XCTest
@testable import TravelCatApp

final class CodexPetCloseForwarderTests: XCTestCase {
    func testPersistedAnchorForwardsOnlyValidatedPointAndAllowlistedCloseItem() {
        let driver = CloseDriver()
        var bypasses = 0
        var waits = 0
        var checkedPIDs: [pid_t] = []
        let forwarder = CodexPetCloseForwarder(
            bypass: { bypasses += 1 }, driver: driver,
            bundleIdentifierForOwnerPID: { checkedPIDs.append($0); return "com.openai.codex" },
            waitForNativeMenu: { waits += 1 }
        )
        let point = CGPoint(x: 1351, y: 198)
        XCTAssertTrue(forwarder.close(selection: selection(), clickPoint: point))
        XCTAssertEqual(checkedPIDs, [1129])
        XCTAssertEqual(driver.points, [point])
        XCTAssertEqual(driver.pids, [1129])
        XCTAssertEqual(driver.titles, CodexPetCloseForwarder.allowedCloseTitles)
        XCTAssertEqual(bypasses, 1)
        XCTAssertEqual(waits, 1)
    }

    func testUntrustedPIDOrOutOfBoundsPointCannotPostAnyClick() {
        for bundle in [nil, "com.example.spoof", "com.openai.codex"] as [String?] {
            let driver = CloseDriver()
            var bypasses = 0
            let forwarder = CodexPetCloseForwarder(
                bypass: { bypasses += 1 }, driver: driver,
                bundleIdentifierForOwnerPID: { _ in bundle }, waitForNativeMenu: {}
            )
            let point = bundle == "com.openai.codex" ? CGPoint.zero : CGPoint(x: 1351, y: 198)
            XCTAssertFalse(forwarder.close(selection: selection(), clickPoint: point))
            XCTAssertEqual(bypasses, 0)
            XCTAssertTrue(driver.points.isEmpty)
            XCTAssertTrue(driver.pids.isEmpty)
        }
    }

    func testNativeMenuFailureIsReturnedWithoutAnotherClick() {
        let driver = CloseDriver()
        driver.success = false
        let forwarder = CodexPetCloseForwarder(bypass: {}, driver: driver,
                                               bundleIdentifierForOwnerPID: { _ in "com.openai.codex" },
                                               waitForNativeMenu: {})
        XCTAssertFalse(forwarder.close(selection: selection(), clickPoint: CGPoint(x: 1351, y: 198)))
        XCTAssertEqual(driver.points.count, 1)
    }

    private func selection() -> CodexPetSelection {
        CodexPetSelection(ownerPID: 1129, inputBounds: CGRect(x: 1301, y: 148, width: 100, height: 109),
                          appKitBounds: CGRect(x: 1301, y: 725, width: 100, height: 109),
                          screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), source: .persistedOverlay)
    }
}

private final class CloseDriver: CodexPetNativeMenuDriving {
    var points: [CGPoint] = []
    var pids: [pid_t] = []
    var titles: Set<String> = []
    var success = true
    func postRightClick(at point: CGPoint) { points.append(point) }
    func pressCloseItem(ownerPID: pid_t, allowedTitles: Set<String>) -> Bool {
        pids.append(ownerPID)
        titles = allowedTitles
        return success
    }
}
