import Foundation
import XCTest
import TravelCore
@testable import TravelStorage

final class PostcardBacklogStoreTests: XCTestCase {
    func testExpiredFirstSupplementLeaseRecordsFailureWithoutInventingResultHash() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = BacklogTestClock()
        let store = try PostcardBacklogStore(root: root, clock: clock)
        let trip = UUID()
        try seedTrip(root: root, trip: trip)
        let slot = try XCTUnwrap(store.reconcile(events: [.fixture(tripID: trip)]).first?.slots.first)
        try store.publishSupplement(.fixture(id: slot.id, tripID: trip, phase: .postcardReady, postcardStatus: .pendingImage), slotID: slot.id)
        let first = try XCTUnwrap(store.pendingImages(mode: .fast).first)
        clock.now = first.leaseExpiresAt.addingTimeInterval(1)
        XCTAssertTrue(try store.pendingImages(mode: .fast).isEmpty)
        let expired = try XCTUnwrap(store.imageRetry(for: slot.id))
        XCTAssertEqual(expired.attemptCount, 1)
        XCTAssertNotNil(expired.lastFailureAt)
        XCTAssertNil(expired.lastResultHash)
        clock.now = try XCTUnwrap(expired.retryAt)
        let reopened = try PostcardBacklogStore(root: root, clock: clock)
        let next = try XCTUnwrap(reopened.pendingImages(mode: .fast).first)
        XCTAssertEqual(next.imageAttemptCount, 1)
        XCTAssertNotEqual(next.attemptToken, first.attemptToken)
    }


    func testCustomTripIsRejectedBeforeSupplementLeaseAndMatchingCallback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source) }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["id": "backlog-custom", "displayName": "Custom", "description": "A cat", "spriteVersionNumber": 2, "spritesheetPath": "sprite.webp"]
        try JSONSerialization.data(withJSONObject: manifest).write(to: source.appendingPathComponent("pet.json"))
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.copyItem(at: project.appendingPathComponent("Sources/TravelUI/Resources/cute-black-cat-spritesheet.webp"), to: source.appendingPathComponent("sprite.webp"))
        let repository = try TravelRepository(root: root)
        _ = try repository.configureCharacter(.import(directory: source))
        let trip = UUID()
        try seedTrip(root: root, trip: trip)
        _ = try repository.configureCharacter(.default)
        let store = try PostcardBacklogStore(root: root)
        let slot = try XCTUnwrap(store.reconcile(events: repository.events()).first?.slots.first)
        try store.publishSupplement(.fixture(id: slot.id, tripID: trip, phase: .postcardReady, postcardStatus: .pendingImage), slotID: slot.id)
        let before = try store.imageRetry(for: slot.id)
        var callbackCalled = false
        XCTAssertTrue(try store.pendingImages(mode: .fast, matching: { _ in callbackCalled = true; return true }).isEmpty)
        XCTAssertFalse(callbackCalled)
        XCTAssertNil(try store.pendingManualImage(eventID: slot.id, mode: .fast))
        XCTAssertEqual(try store.imageRetry(for: slot.id), before)
    }

    private func seedTrip(root: URL, trip: UUID) throws {
        let repository = try TravelRepository(root: root)
        let event = TripEvent.fixture(tripID: trip)
        try repository.publish(event: event, next: .fixture(stateVersion: 1, tripID: trip, lastEventID: event.id))
    }

    func testReconstructsEveryTripAndPreservesBindingsAcrossRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let trip = UUID(uuidString: "02000000-0000-4000-8000-000000000000")!
        let card = TripEvent.fixture(tripID: trip, phase: .postcardReady, postcardStatus: .pendingImage)
        let events = [card, TripEvent.fixture(tripID: trip, phase: .returning), TripEvent.fixture()]
        let first = try PostcardBacklogStore(root: root).reconcile(events: events)
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(first.first?.slots.count, 3)
        XCTAssertEqual(first.first?.slots.first?.eventID, card.id)
        let backlogURL = root.appendingPathComponent("state/postcard-backlog.json")
        let before = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: backlogURL.path)[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(try PostcardBacklogStore(root: root).reconcile(events: events), first)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: backlogURL.path)[.systemFileNumber] as? NSNumber, before,
            "a read-only refresh must not atomically replace the file and trigger its watcher")
    }

    func testSupplementIsIdempotentAndDoesNotModifyJournal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PostcardBacklogStore(root: root)
        let trip = UUID()
        try seedTrip(root: root, trip: trip)
        let plans = try store.reconcile(events: [.fixture(tripID: trip, phase: .returning)])
        let slot = try XCTUnwrap(plans.first?.slots.first)
        let card = TripEvent.fixture(id: slot.id, tripID: trip, phase: .postcardReady, postcardStatus: .pendingImage)
        let journal = root.appendingPathComponent("journal/events.jsonl")
        let before = try Data(contentsOf: journal)
        try store.publishSupplement(card, slotID: slot.id)
        try store.publishSupplement(card, slotID: slot.id)
        XCTAssertEqual(try store.supplementalEvents().count, 1)
        XCTAssertEqual(try Data(contentsOf: journal), before)
        XCTAssertEqual(try store.pendingImages(mode: .fast).count, 1)
        XCTAssertTrue(try PostcardBacklogStore(root: root).pendingImages(mode: .fast).isEmpty)
    }
    func testExportAndClearIncludeIndependentBacklog() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let export = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: export) }
        let repository = try TravelRepository(root: root)
        let store = try PostcardBacklogStore(root: root)
        let trip = UUID()
        try seedTrip(root: root, trip: trip)
        let slot = try XCTUnwrap(store.reconcile(events: [.fixture(tripID: trip, phase: .returning)]).first?.slots.first)
        try store.publishSupplement(.fixture(id: slot.id, tripID: trip, phase: .postcardReady, postcardStatus: .pendingImage), slotID: slot.id)
        _ = try repository.export(to: export)
        XCTAssertEqual(try PostcardBacklogStore(root: export).supplementalEvents().count, 1)
        let backup = try repository.clearHistory()
        XCTAssertTrue(try store.supplementalEvents().isEmpty)
        XCTAssertEqual(try PostcardBacklogStore(root: backup).supplementalEvents().count, 1)
    }

    func testThreeFailuresThenExactlyOneManualAttemptSurvivesRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = BacklogTestClock()
        var store = try PostcardBacklogStore(root: root, clock: clock)
        let trip = UUID()
        try seedTrip(root: root, trip: trip)
        let slot = try XCTUnwrap(store.reconcile(events: [.fixture(tripID: trip, phase: .returning)]).first?.slots.first)
        try store.publishSupplement(.fixture(id: slot.id, tripID: trip, phase: .postcardReady, postcardStatus: .pendingImage), slotID: slot.id)
        var oldResult: ImageResultEnvelope?
        for attempt in 0..<3 {
            let work = try XCTUnwrap(store.pendingImages(mode: .fast).first)
            XCTAssertEqual(work.imageAttemptCount, attempt)
            let result = ImageResultEnvelope(eventId: slot.id, status: .failed, attemptedAt: clock.now,
                relativePath: nil, reason: "generation failed", attemptToken: work.attemptToken,
                attemptCount: work.imageAttemptCount, publishedNarrativeHash: work.publishedNarrativeHash)
            oldResult = result
            try store.markImage(result, mode: .fast)
            clock.now = clock.now.addingTimeInterval(300)
        }
        XCTAssertTrue(try store.pendingImages(mode: .fast).isEmpty)
        XCTAssertTrue(try store.requestManualImageRetry(eventID: slot.id, mode: .fast))
        XCTAssertFalse(try store.requestManualImageRetry(eventID: slot.id, mode: .fast))
        store = try PostcardBacklogStore(root: root, clock: clock)
        let work = try XCTUnwrap(store.pendingManualImage(eventID: slot.id, mode: .fast))
        XCTAssertEqual(work.imageAttemptCount, 2)
        XCTAssertThrowsError(try store.markImage(XCTUnwrap(oldResult), mode: .fast))
        let result = ImageResultEnvelope(eventId: slot.id, status: .failed, attemptedAt: clock.now,
            relativePath: nil, reason: "manual failed", attemptToken: work.attemptToken,
            attemptCount: work.imageAttemptCount, publishedNarrativeHash: work.publishedNarrativeHash)
        XCTAssertEqual(try store.markImage(result, mode: .fast).status, .imageUnavailable)
        XCTAssertTrue(try store.pendingImages(mode: .fast).isEmpty)
        XCTAssertEqual(try store.imageRetry(for: slot.id)?.manualRequests.count, 1)
    }

}

private final class BacklogTestClock: TravelClock, @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_000)
}
