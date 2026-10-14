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

    func testVersionTwoAddsGroundedCompositionVarietyWithoutChangingVersionOne() throws {
        let earlier = TravelGenerationPrompts.image(for: fixture(place: "西湖", version: 1))
        var event = fixture(place: "西湖", version: 2)
        let improved = TravelGenerationPrompts.image(for: event)
        XCTAssertNotEqual(improved, earlier)
        XCTAssertTrue(improved.contains("Waterside documentary"))
        XCTAssertTrue(improved.contains("Choose focal length and framing"))
        XCTAssertTrue(improved.contains("Do not invent weather, season, architecture or actions"))
        XCTAssertFalse(earlier.contains("Choose focal length and framing"))
        XCTAssertTrue(TravelGenerationPrompts.codexImage(for: event).contains(improved))
        event.postcardStatus = .imageUnavailable
        let reopened = try JSONDecoder.travelCat.decode(TripEvent.self, from: JSONEncoder.travelCat.encode(event))
        XCTAssertEqual(TravelGenerationPrompts.image(for: reopened), improved)
    }

    func testVersionThreeSeparatesRegionalColorAndPhotographicApproach() {
        let water = TravelGenerationPrompts.image(for: fixture(place: "西湖", version: 3))
        let mountain = TravelGenerationPrompts.image(for: fixture(place: "高山", version: 3))
        XCTAssertTrue(water.contains("water's actual blue, green or silver"))
        XCTAssertTrue(mountain.contains("terrain's mineral colors"))
        XCTAssertTrue(water.contains("No universal amber/sepia grade"))
        XCTAssertNotEqual(water, mountain)
        XCTAssertTrue(TravelGenerationPrompts.codexImage(for: fixture(place: "西湖", version: 3)).contains(water))
    }

    func testNarrativeVarietyAvoidsRepeatedMotifsAndPreservesItinerary() {
        let prompt = TravelGenerationPrompts.narrative()
        XCTAssertTrue(prompt.contains("Do not repeatedly build every card around lamp shadows"))
        XCTAssertTrue(prompt.contains("landforms, water, architecture, local life"))
        XCTAssertTrue(prompt.contains("Do not teleport or fabricate daylight/weather for variety"))
    }

    func testVersionFourExtendsRegionalPhotographyAndFreezesLandmarkDirectionOnRetry() throws {
        let earlier = TravelGenerationPrompts.image(for: fixture(place: "西湖", version: 3))
        var event = fixture(place: "西湖", version: 4)
        let landmark = TravelGenerationPrompts.image(for: event)
        XCTAssertTrue(landmark.hasPrefix(earlier + "\n"))
        XCTAssertTrue(landmark.contains("Landmark fidelity:"))
        XCTAssertTrue(landmark.contains("city name alone is not evidence"))
        XCTAssertTrue(TravelGenerationPrompts.codexImage(for: event).contains(landmark))
        XCTAssertFalse(earlier.contains("Landmark fidelity:"))
        event.postcardStatus = .imageUnavailable
        let reopened = try JSONDecoder.travelCat.decode(TripEvent.self, from: JSONEncoder.travelCat.encode(event))
        XCTAssertEqual(TravelGenerationPrompts.image(for: reopened), landmark)
        XCTAssertEqual(TravelGenerationPrompts.image(for: fixture(place: "西湖", version: 3)), earlier)
    }

    func testBothNarrativeEntrypointsPreferGroundedLandmarksAndCatReflections() {
        for embedded in [false, true] {
            let prompt = TravelGenerationPrompts.narrative(embeddedRequest: embedded)
            XCTAssertTrue(prompt.contains("well-known local sights"))
            XCTAssertTrue(prompt.contains("do not invent a landmark"))
            XCTAssertTrue(prompt.contains("cat's first-person perspective"))
            XCTAssertTrue(prompt.contains("gentle philosophical insight"))
            XCTAssertTrue(prompt.contains("retrospective card must use only sights supported by its original journey"))
            XCTAssertTrue(prompt.contains("prefer its signature landscape or structure from a genuinely different nearby viewpoint"))
            XCTAssertTrue(prompt.contains("mood.quote: 4-32 Unicode scalars"))
        }
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
