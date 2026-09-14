import CoreGraphics
import XCTest
@testable import TravelCatApp

final class PetCompanionLayoutTests: XCTestCase {
    func testPlacementSwitchesSidesWithPetAndStaysCenteredOnItsEdge() throws {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_000, height: 700)
        let companionSize = CGSize(width: 200, height: 100)

        let leftPet = CGRect(x: 100, y: 300, width: 120, height: 140)
        let leftResult = try XCTUnwrap(PetCompanionLayout.place(
            anchor: leftPet,
            companionSize: companionSize,
            visibleFrame: visibleFrame
        ))

        XCTAssertEqual(leftResult.edge, .leading)
        XCTAssertEqual(leftResult.frame, CGRect(x: 232, y: 320, width: 200, height: 100))
        XCTAssertEqual(leftResult.frame.minX - leftPet.maxX, PetCompanionLayout.gap)
        XCTAssertEqual(leftResult.frame.midY, leftPet.midY)

        let rightPet = CGRect(x: 780, y: 300, width: 120, height: 140)
        let rightResult = try XCTUnwrap(PetCompanionLayout.place(
            anchor: rightPet,
            companionSize: companionSize,
            visibleFrame: visibleFrame
        ))

        XCTAssertEqual(rightResult.edge, .trailing)
        XCTAssertEqual(rightResult.frame, CGRect(x: 568, y: 320, width: 200, height: 100))
        XCTAssertEqual(rightPet.minX - rightResult.frame.maxX, PetCompanionLayout.gap)
        XCTAssertEqual(rightResult.frame.midY, rightPet.midY)
    }

    func testPlacementUsesSideWithMoreAvailableSpace() throws {
        let anchor = CGRect(x: 300, y: 300, width: 120, height: 140)
        let result = try XCTUnwrap(PetCompanionLayout.place(
            anchor: anchor,
            companionSize: CGSize(width: 200, height: 100),
            visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 700)
        ))

        XCTAssertEqual(result.edge, .leading)
        XCTAssertEqual(result.frame, CGRect(x: 432, y: 320, width: 200, height: 100))
        XCTAssertEqual(result.frame.minX - anchor.maxX, PetCompanionLayout.gap)
        XCTAssertEqual(result.frame.midY, anchor.midY)
        XCTAssertFalse(result.frame.intersects(anchor))
    }

    func testPlacementCentersOnRightEdgeWhenPetIsNearLeftEdge() throws {
        let anchor = CGRect(x: 40, y: 300, width: 120, height: 140)
        let visibleFrame = CGRect(x: 0, y: 0, width: 800, height: 700)

        let result = try XCTUnwrap(PetCompanionLayout.place(
            anchor: anchor,
            companionSize: CGSize(width: 200, height: 100),
            visibleFrame: visibleFrame
        ))

        XCTAssertEqual(result.edge, .leading)
        XCTAssertEqual(result.frame, CGRect(x: 172, y: 320, width: 200, height: 100))
        XCTAssertTrue(visibleFrame.contains(result.frame))
        XCTAssertFalse(result.frame.intersects(anchor))
    }

    func testPlacementFallsBackToCenteredRightWhenBothTopCandidatesDoNotFit() throws {
        let anchor = CGRect(x: 20, y: 40, width: 40, height: 40)
        let visibleFrame = CGRect(x: 0, y: 0, width: 500, height: 500)

        let result = try XCTUnwrap(PetCompanionLayout.place(
            anchor: anchor,
            companionSize: CGSize(width: 100, height: 100),
            visibleFrame: visibleFrame
        ))

        XCTAssertEqual(result.edge, .leading)
        XCTAssertEqual(result.frame, CGRect(x: 72, y: 10, width: 100, height: 100))
        XCTAssertTrue(visibleFrame.contains(result.frame))
        XCTAssertFalse(result.frame.intersects(anchor))
    }

    func testPlacementFallsBackToCenteredLeftLast() throws {
        let anchor = CGRect(x: 440, y: 40, width: 40, height: 40)
        let visibleFrame = CGRect(x: 0, y: 0, width: 500, height: 500)

        let result = try XCTUnwrap(PetCompanionLayout.place(
            anchor: anchor,
            companionSize: CGSize(width: 100, height: 100),
            visibleFrame: visibleFrame
        ))

        XCTAssertEqual(result.edge, .trailing)
        XCTAssertEqual(result.frame, CGRect(x: 328, y: 10, width: 100, height: 100))
        XCTAssertTrue(visibleFrame.contains(result.frame))
        XCTAssertFalse(result.frame.intersects(anchor))
    }

    func testPlacementReturnsNilWhenNoCandidateFitsCompletely() {
        XCTAssertNil(PetCompanionLayout.place(
            anchor: CGRect(x: 40, y: 40, width: 40, height: 40),
            companionSize: CGSize(width: 480, height: 480),
            visibleFrame: CGRect(x: 0, y: 0, width: 500, height: 500)
        ))
    }

    func testPlacementSupportsNegativeVisibleFrameCoordinates() throws {
        let visibleFrame = CGRect(x: -1_000, y: -100, width: 1_000, height: 800)
        let anchor = CGRect(x: -300, y: 300, width: 100, height: 120)

        let result = try XCTUnwrap(PetCompanionLayout.place(
            anchor: anchor,
            companionSize: CGSize(width: 200, height: 100),
            visibleFrame: visibleFrame
        ))

        XCTAssertEqual(result.frame, CGRect(x: -512, y: 310, width: 200, height: 100))
        XCTAssertTrue(visibleFrame.contains(result.frame))
        XCTAssertFalse(result.frame.intersects(anchor))
    }

    func testPlacementRejectsNonfiniteAndNonpositiveAnchorComponents() {
        let invalidAnchors = [
            CGRect(x: CGFloat.nan, y: 10, width: 100, height: 100),
            CGRect(x: 10, y: CGFloat.infinity, width: 100, height: 100),
            CGRect(x: 10, y: 10, width: CGFloat.infinity, height: 100),
            CGRect(x: 10, y: 10, width: 100, height: CGFloat.nan),
            CGRect(x: 10, y: 10, width: 0, height: 100),
            CGRect(x: 10, y: 10, width: 100, height: 0),
            CGRect(x: 10, y: 10, width: -1, height: 100),
            CGRect(x: 10, y: 10, width: 100, height: -1),
        ]

        for anchor in invalidAnchors {
            XCTAssertNil(PetCompanionLayout.place(
                anchor: anchor,
                companionSize: CGSize(width: 80, height: 60),
                visibleFrame: CGRect(x: 0, y: 0, width: 500, height: 500)
            ))
        }
    }

    func testPlacementRejectsNonfiniteAndNonpositiveVisibleFrameComponents() {
        let invalidFrames = [
            CGRect(x: CGFloat.nan, y: 0, width: 500, height: 500),
            CGRect(x: 0, y: -CGFloat.infinity, width: 500, height: 500),
            CGRect(x: 0, y: 0, width: CGFloat.nan, height: 500),
            CGRect(x: 0, y: 0, width: 500, height: CGFloat.infinity),
            CGRect(x: 0, y: 0, width: 0, height: 500),
            CGRect(x: 0, y: 0, width: 500, height: 0),
            CGRect(x: 0, y: 0, width: -1, height: 500),
            CGRect(x: 0, y: 0, width: 500, height: -1),
        ]

        for visibleFrame in invalidFrames {
            XCTAssertNil(PetCompanionLayout.place(
                anchor: CGRect(x: 200, y: 200, width: 100, height: 100),
                companionSize: CGSize(width: 80, height: 60),
                visibleFrame: visibleFrame
            ))
        }
    }

    func testPlacementRejectsNonfiniteAndNonpositiveCompanionSize() {
        let invalidSizes = [
            CGSize(width: CGFloat.nan, height: 60),
            CGSize(width: 80, height: CGFloat.infinity),
            CGSize(width: 0, height: 60),
            CGSize(width: 80, height: 0),
            CGSize(width: -1, height: 60),
            CGSize(width: 80, height: -1),
        ]

        for size in invalidSizes {
            XCTAssertNil(PetCompanionLayout.place(
                anchor: CGRect(x: 200, y: 200, width: 100, height: 100),
                companionSize: size,
                visibleFrame: CGRect(x: 0, y: 0, width: 500, height: 500)
            ))
        }
    }
}
