import Foundation
import XCTest
@testable import TravelCore

final class PostcardSceneStyleTests: XCTestCase {
    func testOptedInStyleVersionSurvivesEventRoundTripAndLegacyRemainsAbsent() throws {
        let legacy = TripEvent.fixture()
        let legacyData = try JSONEncoder.travelCat.encode(legacy)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: legacyData) as? [String: Any])
        XCTAssertNil(object["postcardStyleVersion"])
        object["postcardStyleVersion"] = 1
        let restored = try JSONDecoder.travelCat.decode(TripEvent.self, from: JSONSerialization.data(withJSONObject: object))
        let roundTrip = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.travelCat.encode(restored)) as? [String: Any])
        XCTAssertEqual(roundTrip["postcardStyleVersion"] as? Int, 1)
    }
    func testSceneSelectionIsGeographicAndStableAcrossImageStatusAndRoundTrip() throws {
        let places: [(String, PostcardSceneCategory)] = [
            ("西湖湖岸", .waterside), ("清迈古城寺庙", .heritage), ("成都夜市", .market),
            ("阿尔卑斯山", .mountain), ("苏州园林", .garden), ("东京街头", .urban),
        ]
        for (place, category) in places {
            var event = try styledEvent(place: place)
            let initial = try XCTUnwrap(PostcardSceneStyle.resolve(event: event))
            XCTAssertEqual(initial.category, category)
            event.postcardStatus = .ready
            event.postcardRelativePath = "postcards/test.png"
            let restored = try JSONDecoder.travelCat.decode(TripEvent.self, from: JSONEncoder.travelCat.encode(event))
            XCTAssertEqual(PostcardSceneStyle.resolve(event: restored), initial)
        }
    }

    func testLegacyAndUnknownVersionsRemainOnLegacyPath() throws {
        XCTAssertNil(PostcardSceneStyle.resolve(event: TripEvent.fixture()))
        XCTAssertNil(PostcardSceneStyle.resolve(event: try styledEvent(place: "西湖", version: 99)))
    }

    func testUnknownPlaceStillHasStableVariedCompositionAcrossCards() throws {
        var variants = Set<Int>()
        for number in 1...24 {
            let id = String(format: "00000000-0000-0000-0000-%012d", number)
            let event = try styledEvent(place: "目的地", id: id)
            variants.insert(try XCTUnwrap(PostcardSceneStyle.resolve(event: event)).compositionVariant)
        }
        XCTAssertEqual(variants, [0, 1, 2])
    }

    private func styledEvent(place: String, version: Int = 1,
                             id: String = "00000000-0000-0000-0000-000000000003") throws -> TripEvent {
        let data = try JSONEncoder.travelCat.encode(TripEvent.fixture(place: place))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["postcardStyleVersion"] = version
        object["id"] = id
        return try JSONDecoder.travelCat.decode(TripEvent.self, from: JSONSerialization.data(withJSONObject: object))
    }

}
