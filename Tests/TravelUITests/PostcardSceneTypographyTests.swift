import Foundation
import CoreGraphics
import CoreText
import XCTest
import TravelCore
@testable import TravelUI

final class PostcardSceneTypographyTests: XCTestCase {
    func testNewSceneCardsUseDistinctChineseFontDesignsEvenBeforeAnalysisLoads() throws {
        var families = Set<String>()
        for place in ["西湖湖岸", "故宫", "阿尔卑斯山"] {
            let event = try fixture(place: place, version: 1)
            let layout = PostcardArtworkLayoutResolver.resolve(metadata: .init(event: event), analysis: nil,
                profile: .detail, containerSize: CGSize(width: 600, height: 400))
            let font = layout.messageFont
            families.insert(font.familyName ?? font.fontName)
            XCTAssertGreaterThan(layout.messageFontSize, 0)
        }
        XCTAssertEqual(families.count, 3, "Water, heritage and mountain cards need handwriting, serif and sans designs")
    }

    func testLegacyCardKeepsSereneFallbackAndUnknownVersionsDoNotOptIn() throws {
        let expected = PostcardMoodTypographyResolver().resolve(mood: Mood(level: 0, label: "serene", quote: "今天看到了山"))
        for version in [nil, 99] as [Int?] {
            let layout = PostcardArtworkLayoutResolver.resolve(metadata: .init(event: try fixture(place: "雪山", version: version)),
                analysis: nil, profile: .detail, containerSize: CGSize(width: 600, height: 400))
            XCTAssertEqual(layout.handwritingStyle, expected)
        }
    }

    func testNewStyleFallbackAndMeasuredLayoutStayReadable() throws {
        let event = try fixture(place: "故宫", version: 1)
        let resolver = PostcardMoodTypographyResolver(fontLookup: { _, _ in nil })
        let fallback = resolver.resolve(mood: event.mood, sceneStyle: PostcardSceneStyle.resolve(event: event))
        XCTAssertTrue(fallback.usesSystemFont)
        for profile in [PostcardOverlayProfile.detail, .compact] {
            let layout = PostcardArtworkLayoutResolver.resolve(metadata: .init(event: event),
                analysis: PostcardVisualAnalysis(salientRegions: [], samples: .uniform(luminance: 0.5, red: 0.5, green: 0.5, blue: 0.5)),
                profile: profile, containerSize: CGSize(width: 600, height: 400))
            XCTAssertGreaterThan(layout.messageFontSize, 0)
            XCTAssertTrue(layout.messageFontSize.isFinite)
            XCTAssertEqual(layout.handwritingStyle,
                PostcardMoodTypographyResolver().resolve(mood: event.mood, sceneStyle: PostcardSceneStyle.resolve(event: event)))
        }
    }

    private func fixture(place: String, version: Int?) throws -> TripEvent {
        let event = TripEvent(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            tripID: UUID(), previousEventID: nil, occurredAt: Date(timeIntervalSince1970: 0),
            phase: .postcardReady, location: Location(country: "中国", city: "旅行城市", place: place),
            transport: nil, summary: "眼前的风景让人停下脚步。", mood: Mood(level: 0, label: "平静", quote: "今天看到了山"),
            continuityReferences: [], openHook: nil, consumedItemID: nil, postcardStatus: .ready, postcardRelativePath: "photo.png")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.travelCat.encode(event)) as? [String: Any])
        object["postcardStyleVersion"] = version
        return try JSONDecoder.travelCat.decode(TripEvent.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
