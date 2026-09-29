import Foundation
import XCTest
import TravelCore
@testable import TravelStorage
@testable import TravelUI

final class PostcardWorkItemTests: XCTestCase {
    func testProjectionKeepsUnpublishedSlotsAndOnlyLiveLeaseIsGenerating() {
        let trip = UUID(), slot = UUID()
        let plan = PostcardBacklogPlan(tripID: trip, slots: [.init(id: slot, event: nil, isSupplement: false)])
        let now = Date(timeIntervalSince1970: 100)
        let retry = ImageRetry(attemptCount: 0, retryAt: nil, publishedNarrativeHash: "hash",
                               activeAttemptToken: "token", leaseExpiresAt: now.addingTimeInterval(10))
        let active = PostcardWorkProjection.items(plans: [plan], retries: [slot: retry], now: now)
        XCTAssertEqual(active.first?.id, slot)
        XCTAssertNil(active.first?.eventID)
        XCTAssertNil(active.first?.generatedAt)
        XCTAssertEqual(active.first?.status, .generating)
        let expired = PostcardWorkProjection.items(plans: [plan], retries: [slot: retry], now: now.addingTimeInterval(10))
        XCTAssertEqual(expired.first?.status, .pending)
        XCTAssertEqual(PostcardWorkProjection.items(plans: [plan], retries: [:], now: now).first?.status, .pending)
    }

    func testTerminalAndSupplementReadyProjection() {
        let trip = UUID(), slot = UUID(), eventID = UUID()
        var event = TripEvent(id: eventID, tripID: trip, previousEventID: nil,
            occurredAt: Date(timeIntervalSince1970: 70), phase: .postcardReady, location: nil,
            transport: nil, summary: "实际记录", mood: Mood(level: 2, label: "平静", quote: ""),
            continuityReferences: [], openHook: nil, consumedItemID: nil,
            postcardStatus: .imageUnavailable, postcardRelativePath: nil)
        var plan = PostcardBacklogPlan(tripID: trip, slots: [.init(id: slot, event: event, isSupplement: true)])
        let now = Date(timeIntervalSince1970: 100)
        let terminal = PostcardWorkProjection.items(plans: [plan], retries: [:], now: now)[0]
        XCTAssertEqual(terminal.status, .manualRequired)
        XCTAssertEqual(terminal.eventID, eventID)
        XCTAssertTrue(terminal.status.label.contains("3 次"))
        event.postcardStatus = .ready
        plan.slots[0].event = event
        let ready = PostcardWorkProjection.items(plans: [plan], retries: [:], now: now)[0]
        XCTAssertEqual(ready.status, .ready)
        XCTAssertTrue(ready.isSupplement)
        XCTAssertEqual(ready.generatedAt, event.occurredAt)
    }
}
