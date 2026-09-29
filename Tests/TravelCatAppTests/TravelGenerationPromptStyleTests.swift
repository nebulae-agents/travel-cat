import Foundation
import XCTest
import TravelCore
@testable import TravelCatApp

final class TravelGenerationPromptStyleTests: XCTestCase {
    func testNewCardDirectionsAreSceneSpecificAndSharedByBothProviders() {
        var prompts = Set<String>()
        for place in ["西湖", "故宫", "夜市", "高山", "花园", "街头"] {
            let event = fixture(place: place, version: 1)
            let prompt = TravelGenerationPrompts.image(for: event)
            prompts.insert(prompt)
            XCTAssertTrue(prompt.contains("Landscape EXACTLY 3:2, 1536x1024"))
            XCTAssertTrue(prompt.contains("Preserve the attached cat identity."))
            XCTAssertTrue(prompt.contains("No text/logo/watermark/extra animals"))
            XCTAssertFalse(prompt.contains("Scenic travel selfie"))
            XCTAssertTrue(TravelGenerationPrompts.codexImage(for: event).contains(prompt))
            XCTAssertTrue(TravelGenerationPrompts.codexImage(for: event).contains("Do not change event.json"))
        }
        XCTAssertEqual(prompts.count, 6)
    }

    func testOldCardPromptsAndIdentityRemainUnchangedWhenRetrying() throws {
        let old = fixture(place: "西湖", version: nil)
        XCTAssertEqual(TravelGenerationPrompts.image(for: old), TravelGenerationPrompts.image)
        XCTAssertTrue(TravelGenerationPrompts.codexImage(for: old).contains("Scenic travel selfie"))
        var card = fixture(place: "西湖", version: 1)
        let before = TravelGenerationPrompts.image(for: card)
        card.postcardStatus = .imageUnavailable
        let restored = try JSONDecoder.travelCat.decode(TripEvent.self, from: JSONEncoder.travelCat.encode(card))
        XCTAssertEqual(TravelGenerationPrompts.image(for: restored), before)
    }

    private func fixture(place: String, version: Int?) -> TripEvent {
        TripEvent(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, tripID: UUID(),
            previousEventID: nil, occurredAt: Date(timeIntervalSince1970: 0), phase: .postcardReady,
            location: Location(country: "中国", city: "旅行城市", place: place), transport: nil,
            summary: "停下脚步仔细看了看。", mood: Mood(level: 0, label: "平静", quote: "慢慢走真好"),
            continuityReferences: [], openHook: nil, consumedItemID: nil,
            postcardStatus: .pendingImage, postcardRelativePath: nil, postcardStyleVersion: version)
    }
}
