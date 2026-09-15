import XCTest
@testable import TravelCatApp

final class PetCompanionOffsetStoreTests: XCTestCase {
    func testRoundTripAndInvalidRecords() throws {
        let suite = "CompanionOffset-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PetCompanionOffsetStore(defaults: defaults)
        XCTAssertNil(store.load())
        defaults.set(["version": true, "x": 1, "y": 2], forKey: PetCompanionOffsetStore.key)
        XCTAssertNil(store.load())
        store.save(CGPoint(x: -183, y: 82))
        XCTAssertEqual(PetCompanionOffsetStore(defaults: defaults).load(), CGPoint(x: -183, y: 82))
        store.save(CGPoint(x: CGFloat.nan, y: 2))
        XCTAssertEqual(store.load(), CGPoint(x: -183, y: 82))
        for record: Any in ["bad", ["version": 2, "x": 1, "y": 2], ["version": 1, "x": Double.infinity, "y": 2], ["version": 1, "x": "1", "y": 2], ["version": 1, "x": 2]] {
            defaults.set(record, forKey: PetCompanionOffsetStore.key)
            XCTAssertNil(store.load())
        }
    }
}
