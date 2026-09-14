import Foundation
import XCTest
import TravelCore
@testable import TravelUI

@MainActor
final class AppModelIntegrationTests: XCTestCase {
    func testApplyReflectsSameVersionCarriedItemWithoutAcceptingOtherRegression() {
        var initial = TripSnapshot.empty(now: Date(timeIntervalSince1970: 1))
        let model = AppModel(snapshot: initial, defaults: isolatedDefaults(), supplies: [])
        initial.carriedItemID = "camera"
        model.apply(next: initial, events: [])
        XCTAssertEqual(model.snapshot.carriedItemID, "camera")

        var invalid = initial
        invalid.phase = .transit
        model.apply(next: invalid, events: [])
        XCTAssertEqual(model.snapshot.phase, .resting)
    }

    func testReplaceAfterConfirmedHistoryClearAcceptsResetVersion() {
        var away = TripSnapshot.empty(now: Date(timeIntervalSince1970: 1))
        away.stateVersion = 5
        away.phase = .returning
        let model = AppModel(snapshot: away, defaults: isolatedDefaults(), supplies: [])
        let empty = TripSnapshot.empty(now: Date(timeIntervalSince1970: 2))

        model.replaceAfterHistoryClear(next: empty, events: [])

        XCTAssertEqual(model.snapshot, empty)
        XCTAssertEqual(model.presentation, .pet)
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "AppModelIntegrationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
}
