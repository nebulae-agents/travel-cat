import Foundation
import XCTest
@testable import TravelCore

final class HomeCareTests: XCTestCase {
    func testCooldownRecoversFromClockRollbackAndExpiresAtBoundary() throws {
        let now = Date(timeIntervalSince1970: 1000)
        var care = HomeCareState()
        try care.perform(.snack, phase: .resting, now: now)
        XCTAssertTrue(care.isCoolingDown(at: now.addingTimeInterval(4.9)))
        XCTAssertFalse(care.isCoolingDown(at: now.addingTimeInterval(5)))
        XCTAssertFalse(care.isCoolingDown(at: now.addingTimeInterval(-3600)))
        try care.perform(.play, phase: .preparing, now: now.addingTimeInterval(-3600))
        XCTAssertEqual(care.latest?.action, .play)
    }
}
