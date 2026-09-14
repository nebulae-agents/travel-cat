import Foundation
import XCTest
@testable import TravelCore

final class ContinuityValidatorTests: XCTestCase {
    func testViolationsAreReportedInDeterministicRequiredOrder() {
        let previousEventID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let previous = TripSnapshot.fixture(
            moodLevel: 0,
            usedItemIDs: ["matcha"],
            lastEventID: previousEventID,
            visitedPlaces: ["Great Buddha"]
        )
        let event = TripEvent.fixture(
            moodLevel: 2,
            consumedItemID: "matcha",
            references: [],
            place: "Great Buddha"
        )

        XCTAssertEqual(
            ContinuityValidator().violations(event: event, previous: previous),
            [.moodJump, .itemAlreadyConsumed("matcha"), .missingAnchorReference, .repeatedPlace]
        )
    }

    func testRepeatedPlaceIsReported() {
        let previous = TripSnapshot.fixture(visitedPlaces: ["Great Buddha"])
        let event = TripEvent.fixture(place: "Great Buddha")

        XCTAssertEqual(
            ContinuityValidator().violations(event: event, previous: previous),
            [.repeatedPlace]
        )
    }

    func testValidEventHasNoViolationsAndAllowsNilLocationAndItem() {
        let previous = TripSnapshot.fixture(moodLevel: 1, visitedPlaces: ["Hasedera"])
        let event = TripEvent.fixture(moodLevel: 2, consumedItemID: nil, place: nil)

        XCTAssertEqual(ContinuityValidator().violations(event: event, previous: previous), [])
    }

    func testMoodJumpDetectionDoesNotOverflowAtIntegerExtremes() {
        let previous = TripSnapshot.fixture(moodLevel: .min)
        let event = TripEvent.fixture(moodLevel: .max)

        XCTAssertEqual(
            ContinuityValidator().violations(event: event, previous: previous),
            [.moodJump]
        )
    }
}
