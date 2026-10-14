import CryptoKit
import Foundation
import XCTest
import TravelCore
@testable import TravelStorage

final class PostcardStylePersistenceTests: XCTestCase {
    // Frozen pre-style hash projection: old outstanding image leases must still match.
    private struct LegacyProjection: Codable {
        let id: UUID
        let tripID: UUID
        let previousEventID: UUID?
        let occurredAt: Date
        let phase: TravelPhase
        let location: Location?
        let transport: String?
        let summary: String
        let mood: Mood
        let continuityReferences: [String]
        let openHook: String?
        let consumedItemID: String?
    }

    func testLegacyNarrativeHashRetainsExactProjectionAndNewStyleIsFrozen() throws {
        let event = TripEvent.fixture(phase: .postcardReady, place: "海边", postcardStatus: .pendingImage)
        let encoded = try JSONEncoder.travelCat.encode(event)
        let legacy = try JSONDecoder.travelCat.decode(LegacyProjection.self, from: encoded)
        let expected = SHA256.hash(data: try JSONEncoder.travelCat.encode(legacy))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try NarrativeHasher.hash(event), expected)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["postcardStyleVersion"] = 1
        var styled = try JSONDecoder.travelCat.decode(TripEvent.self, from: JSONSerialization.data(withJSONObject: object))
        let styledHash = try NarrativeHasher.hash(styled)
        XCTAssertNotEqual(styledHash, expected)
        styled.postcardStatus = .ready
        styled.postcardRelativePath = "postcards/accepted.png"
        XCTAssertEqual(try NarrativeHasher.hash(styled), styledHash)
        let reopened = try JSONDecoder.travelCat.decode(TripEvent.self, from: JSONEncoder.travelCat.encode(styled))
        XCTAssertEqual(reopened.postcardStyleVersion, 1)
        XCTAssertEqual(try NarrativeHasher.hash(reopened), styledHash)
    }

    func testNewValidatedPostcardOptsInBeforeAnyImageAttempt() throws {
        let event = TripEvent.fixture(phase: .postcardReady, place: "湖岸", postcardStatus: .pendingImage)
        let previousID = UUID()
        let previous = TripSnapshot.fixture(stateVersion: 1, tripID: event.tripID,
            lastEventID: previousID, phase: .exploring, mood: event.mood)
        let candidate = AgentEventEnvelope(eventId: event.id, tripId: event.tripID,
            previousEventId: previousID, occurredAt: event.occurredAt, phase: event.phase,
            location: event.location, transport: event.transport, summary: event.summary,
            mood: event.mood, continuityReferences: event.continuityReferences,
            openHook: event.openHook, consumedItemId: nil,
            postcard: PostcardRequest(required: true, scenePrompt: "黑猫站在湖岸看着水面。"))
        let result = candidate.validationResult(previous: previous, mode: .fast,
            calendar: Calendar(identifier: .gregorian), now: event.occurredAt)
        XCTAssertTrue(result.valid, "\(result.violations)")
        XCTAssertEqual(try XCTUnwrap(result.publishEnvelope).event.postcardStyleVersion, 1)
    }
}
