import XCTest
@testable import TravelCore

final class ClockTests: XCTestCase {
    func testFixedClockReturnsInjectedDate() {
        let expected = Date(timeIntervalSince1970: 1_786_339_200)

        XCTAssertEqual(FixedClock(now: expected).now, expected)
    }
}
