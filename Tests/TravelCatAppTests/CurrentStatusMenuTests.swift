import XCTest
@testable import TravelCatApp

final class CurrentStatusMenuTests: XCTestCase {
    func testExistingJourneyActionNowOpensCurrentStatus() {
        XCTAssertEqual(TravelCatPetMenuController.title(for: .currentJourney), "当前状态")
    }

    func testMenuBarAndStatusRouteUseCurrentStatusPage() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/TravelCatApp/TravelCatApp.swift"))
        XCTAssertTrue(source.contains("Button(\"当前状态\")"))
        XCTAssertTrue(source.contains("CurrentPetStatusView("))
    }
}
