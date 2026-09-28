import Foundation
import XCTest
import TravelCore
import TravelStorage
@testable import TravelCatApp

final class TravelSupplyContextTests: XCTestCase {
    func testSelectedSupplyMetadataReachesSerializedGeneratorRequest() throws {
        var snapshot = TripSnapshot.empty(now: Date(timeIntervalSince1970: 1_787_000_000))
        snapshot.carriedItemID = "camera"
        let request = TravelEventRequest(claim: DueClaim(due: true, snapshot: snapshot, previousEvent: nil), recentEvents: [], phase: .preparing)
        let encoded = try JSONEncoder().encode(request)
        let restored = try JSONDecoder().decode(TravelEventRequest.self, from: encoded)
        XCTAssertEqual(restored.carriedSupply?.id, "camera")
        XCTAssertEqual(restored.carriedSupply?.name, "小相机")
        XCTAssertFalse(try XCTUnwrap(restored.carriedSupply?.influence).isEmpty)
    }

    func testRepackedSupplyIsAvailableForANewTrip() {
        var snapshot = TripSnapshot.empty(now: Date())
        snapshot.carriedItemID = "camera"
        snapshot.usedItemIDs = ["camera"]
        let request = TravelEventRequest(claim: DueClaim(due: true, snapshot: snapshot, previousEvent: nil), recentEvents: [], phase: .preparing)
        XCTAssertEqual(request.carriedSupply?.id, "camera")
    }

    func testUsedUnknownAndAbsentSuppliesDoNotOfferAnotherUse() {
        var snapshot = TripSnapshot.empty(now: Date())
        for id in [nil, "missing", "camera"] as [String?] {
            snapshot.carriedItemID = id
            snapshot.usedItemIDs = ["camera"]
            let request = TravelEventRequest(claim: DueClaim(due: true, snapshot: snapshot, previousEvent: nil), recentEvents: [], phase: .exploring)
            XCTAssertNil(request.carriedSupply)
        }
    }
}
