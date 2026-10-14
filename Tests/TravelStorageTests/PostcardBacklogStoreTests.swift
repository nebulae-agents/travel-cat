import Foundation
import Darwin
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
import TravelCore
@testable import TravelStorage

final class PostcardBacklogStoreTests: XCTestCase {
    private func installLegacySlots(root: URL, trip: UUID) throws -> [PostcardBacklogPlan.Slot] {
        let store = try PostcardBacklogStore(root: root)
        _ = try store.reconcile(events: [.fixture(tripID: trip)])
        let slots = (0..<3).map { PostcardBacklogPlan.Slot(id: PostcardBacklogPlan.slotID(tripID: trip, index: $0), event: nil, isSupplement: false) }
        let url = root.appendingPathComponent("state/postcard-backlog.json")
        var state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        state["plans"] = try JSONSerialization.jsonObject(with: JSONEncoder.travelCat.encode([PostcardBacklogPlan(tripID: trip, slots: slots)]))
        try JSONSerialization.data(withJSONObject: state).write(to: url)
        return slots
    }

    func testOnePostcardDefaultRetiresEmptyLegacySlotsAndPreservesPublishedCards() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let trip = UUID(uuidString: "02000000-0000-4000-8000-000000000000")!
        let store = try PostcardBacklogStore(root: root)
        XCTAssertEqual(PostcardBacklogPlan.target(for: trip), 1)
        let slots = try installLegacySlots(root: root, trip: trip)
        XCTAssertEqual(try store.reconcile(events: [.fixture(tripID: trip)]).first?.slots.map(\.id), [slots[0].id])
        let cards = slots.map { TripEvent.fixture(id: $0.id, tripID: trip, phase: .postcardReady, postcardStatus: .pendingImage) }
        XCTAssertEqual(try store.reconcile(events: cards).first?.slots.compactMap(\.eventID), cards.map(\.id))
        XCTAssertEqual(try store.reconcile(events: [cards[0]]).first?.slots.compactMap(\.eventID), [cards[0].id])
        XCTAssertEqual(try store.reconcile(events: [cards[0]]).first?.slots.count, 1)
    }

    func testSparseLegacySupplementKeepsIdentityRetryAndNoEmptyDebtAcrossRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let trip = UUID(uuidString: "02000000-0000-4000-8000-000000000000")!
        try seedTrip(root: root, trip: trip)
        let store = try PostcardBacklogStore(root: root)
        let slots = try installLegacySlots(root: root, trip: trip)
        let card = TripEvent.fixture(id: slots[2].id, tripID: trip, phase: .postcardReady, postcardStatus: .pendingImage)
        try store.publishSupplement(card, slotID: slots[2].id)
        let before = try store.imageRetry(for: card.id)
        let reopened = try PostcardBacklogStore(root: root)
        let plan = try XCTUnwrap(reopened.reconcile(events: [.fixture(tripID: trip)]).first)
        XCTAssertEqual(plan.slots.map(\.id), [slots[2].id])
        XCTAssertEqual(plan.slots.compactMap(\.event), [card])
        XCTAssertTrue(plan.slots.allSatisfy(\.isSupplement))
        XCTAssertEqual(try reopened.imageRetry(for: card.id), before)
        XCTAssertEqual(try reopened.pendingImages(mode: .fast).first?.event.id, card.id)
    }


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

    func testNonregularBacklogAndImageDoNotBlockOnFIFO() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try TravelRepository(root: root)
        let store = try PostcardBacklogStore(root: root)
        let trip = UUID()
        let relative = "postcards/\(trip.uuidString.lowercased())/card.png"
        for path in [relative, "state/postcard-backlog.json"] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            XCTAssertEqual(mkfifo(url.path, 0o600), 0)
            // A delayed writer bounds the old blocking implementation so a failing
            // regression cannot hang the suite. It never writes any source data.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                let descriptor = open(url.path, O_WRONLY | O_NONBLOCK | O_NOFOLLOW)
                if descriptor >= 0 { close(descriptor) }
            }
            let started = ProcessInfo.processInfo.systemUptime
            if path == relative {
                XCTAssertThrowsError(try repository.validateReadyImage(relative, tripID: trip))
            } else {
                XCTAssertThrowsError(try store.supplementalEvents())
            }
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1)
        }
    }

    func testDamagedReadyImageDoesNotBlockUnrelatedPendingWork() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PostcardBacklogStore(root: root)
        let trip = UUID(uuidString: "02000000-0000-4000-8000-000000000000")!
        try seedTrip(root: root, trip: trip)
        let slots = try installLegacySlots(root: root, trip: trip)
        for slot in slots.prefix(2) {
            try store.publishSupplement(.fixture(id: slot.id, tripID: trip, phase: .postcardReady, postcardStatus: .pendingImage), slotID: slot.id)
        }
        let work = try XCTUnwrap(store.pendingImages(mode: .fast).first)
        let path = "postcards/\(trip.uuidString.lowercased())/card.png"
        let imageURL = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: imageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let context = try XCTUnwrap(CGContext(data: nil, width: 1200, height: 800, bitsPerComponent: 8, bytesPerRow: 4800, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(imageURL as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        try store.markImage(ImageResultEnvelope(eventId: work.event.id, status: .ready, attemptedAt: Date(), relativePath: path, reason: nil, attemptToken: work.attemptToken, attemptCount: work.imageAttemptCount, publishedNarrativeHash: work.publishedNarrativeHash), mode: .fast)
        let stateURL = root.appendingPathComponent("state/postcard-backlog.json")
        let validState = try Data(contentsOf: stateURL)
        for invalidPath in ["../../outside.png", "postcards/\(UUID().uuidString.lowercased())/card.png"] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: validState) as? [String: Any])
            var events = try XCTUnwrap(object["supplements"] as? [[String: Any]])
            events[0]["postcardRelativePath"] = invalidPath
            object["supplements"] = events
            var retries = try XCTUnwrap(object["retries"] as? [String: Any])
            var entries = try XCTUnwrap(retries["entries"] as? [String: [String: Any]])
            entries[slots[0].id.uuidString.lowercased()]?["terminalRelativePath"] = invalidPath
            retries["entries"] = entries
            object["retries"] = retries
            try JSONSerialization.data(withJSONObject: object).write(to: stateURL)
            XCTAssertThrowsError(try store.supplementalEvents(), "Malformed metadata must fail closed, not become asset damage")
        }
        try validState.write(to: stateURL)
        try Data("damaged bytes".utf8).write(to: imageURL)
        XCTAssertEqual(try store.supplementalEvents().count, 2)
        XCTAssertEqual(try store.pendingImages(mode: .fast).first?.event.id, slots[1].id)
        XCTAssertEqual(try store.damagedReadyImageIDs(), [slots[0].id])
        XCTAssertTrue(try store.requestManualImageRetry(eventID: slots[0].id, mode: .fast))
        XCTAssertEqual(try Data(contentsOf: imageURL), Data("damaged bytes".utf8))
        XCTAssertEqual(try store.imageRetry(for: slots[0].id)?.manualPriorResultHashes.count, 1)
        let manual = try XCTUnwrap(store.pendingManualImage(eventID: slots[0].id, mode: .fast))
        XCTAssertEqual(manual.imageAttemptCount, 2)
        XCTAssertThrowsError(try store.markImage(ImageResultEnvelope(eventId: manual.event.id, status: .ready, attemptedAt: Date(), relativePath: path, reason: nil, attemptToken: manual.attemptToken, attemptCount: manual.imageAttemptCount, publishedNarrativeHash: manual.publishedNarrativeHash), mode: .fast))
    }

    func testExplicitRecoveryPreservesCorruptSourceAndFencesPendingWork() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PostcardBacklogStore(root: root)
        let trip = UUID()
        try seedTrip(root: root, trip: trip)
        let slot = try XCTUnwrap(store.reconcile(events: [.fixture(tripID: trip)]).first?.slots.first)
        try store.publishSupplement(.fixture(id: slot.id, tripID: trip, phase: .postcardReady, postcardStatus: .pendingImage), slotID: slot.id)
        let stale = try XCTUnwrap(store.pendingImages(mode: .fast).first)
        let corrupt = Data("{broken".utf8)
        try corrupt.write(to: root.appendingPathComponent("state/postcard-backlog.json"))
        XCTAssertThrowsError(try store.supplementalEvents())
        let preserved = try store.recoverFromBackup()
        XCTAssertEqual(try Data(contentsOf: preserved), corrupt)
        XCTAssertEqual(try store.supplementalEvents().map(\.id), [slot.id])
        XCTAssertEqual(try store.supplementalEvents().first?.postcardStatus, .imageUnavailable)
        XCTAssertTrue(try store.pendingImages(mode: .fast).isEmpty)
        XCTAssertThrowsError(try store.markImage(ImageResultEnvelope(eventId: slot.id, status: .failed, attemptedAt: Date(), relativePath: nil, reason: "stale", attemptToken: stale.attemptToken, attemptCount: stale.imageAttemptCount, publishedNarrativeHash: stale.publishedNarrativeHash), mode: .fast))
        XCTAssertTrue(try store.requestManualImageRetry(eventID: slot.id, mode: .fast))
        XCTAssertEqual(try store.pendingManualImage(eventID: slot.id, mode: .fast)?.imageAttemptCount, 2)
    }

    func testRecoveryRefusesHealthyMainAndMissingMainDoesNotReset() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PostcardBacklogStore(root: root)
        _ = try store.reconcile(events: [.fixture()])
        let main = root.appendingPathComponent("state/postcard-backlog.json")
        let before = try Data(contentsOf: main)
        XCTAssertThrowsError(try store.recoverFromBackup())
        XCTAssertEqual(try Data(contentsOf: main), before)
        try FileManager.default.removeItem(at: main)
        XCTAssertThrowsError(try store.supplementalEvents())
        _ = try store.recoverFromBackup()
        XCTAssertTrue(try store.supplementalEvents().isEmpty)
    }

    func testRecoveryWithoutValidBackupNeverResetsUnknownRecords() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PostcardBacklogStore(root: root)
        let corrupt = Data("unknown supplements".utf8)
        let url = root.appendingPathComponent("state/postcard-backlog.json")
        try corrupt.write(to: url)
        XCTAssertThrowsError(try store.recoverFromBackup())
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        try Data("also malformed".utf8).write(to: root.appendingPathComponent("state/postcard-backlog.backup.json"))
        XCTAssertThrowsError(try store.recoverFromBackup())
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testReconstructsEveryTripAndPreservesBindingsAcrossRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let trip = UUID(uuidString: "02000000-0000-4000-8000-000000000000")!
        let card = TripEvent.fixture(tripID: trip, phase: .postcardReady, postcardStatus: .pendingImage)
        let events = [card, TripEvent.fixture(tripID: trip, phase: .returning), TripEvent.fixture()]
        let first = try PostcardBacklogStore(root: root).reconcile(events: events)
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(first.first?.slots.count, 1)
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
        let forensic = root.appendingPathComponent("state/postcard-backlog.recovery-test.json")
        try Data("preserved source".utf8).write(to: forensic)
        _ = try repository.export(to: export)
        XCTAssertEqual(try Data(contentsOf: export.appendingPathComponent("state/postcard-backlog.recovery-test.json")), Data("preserved source".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: export.appendingPathComponent("state/postcard-backlog.backup.json").path))
        XCTAssertEqual(try PostcardBacklogStore(root: export).supplementalEvents().count, 1)
        let backup = try repository.clearHistory()
        XCTAssertTrue(try store.supplementalEvents().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: forensic.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("state/postcard-backlog.backup.json").path))
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("state/postcard-backlog.recovery-test.json")), Data("preserved source".utf8))
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
