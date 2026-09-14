import Foundation
import TravelCore
import XCTest
@testable import TravelStorage

final class PostcardRetryTests: XCTestCase {
    private let tripID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let eventID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private let firstAttempt = Date(timeIntervalSince1970: 1_786_435_200)

    func testPendingLeasePersistsRequiredRetryFieldsAndStableWireKeys() throws {
        let clock = RetryTestClock(now: firstAttempt)
        let root = try temporaryDirectory()
        let repository = try TravelRepository(root: root, clock: clock)
        let original = try publishPostcard(in: repository)
        let work = try XCTUnwrap(repository.pendingImages(mode: .fast).first)
        XCTAssertEqual(work.event, original)
        XCTAssertEqual(work.imageAttemptCount, 0)
        XCTAssertEqual(work.attemptToken.count, 36)
        XCTAssertEqual(work.publishedNarrativeHash.count, 64)
        XCTAssertEqual(work.leaseExpiresAt, firstAttempt.addingTimeInterval(1_800))

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("state/image-retries.json"))) as? [String: Any])
        let entries = try XCTUnwrap(object["entries"] as? [String: Any])
        let retry = try XCTUnwrap(entries[eventID.uuidString.lowercased()] as? [String: Any])
        XCTAssertTrue(Set(["imageAttemptCount", "imageRetryAt", "publishedNarrativeHash", "activeAttemptToken", "leaseExpiresAt"]).isSubset(of: Set(retry.keys)))
    }

    func testDailyAndFastFailureBackoffUsesTrustedClockAndPreservesNarrative() throws {
        for (mode, delay, lease) in [(TravelMode.daily, 600.0, 3_600.0), (.fast, 60.0, 1_800.0)] {
            let clock = RetryTestClock(now: firstAttempt)
            let repository = try TravelRepository(root: temporaryDirectory(), clock: clock)
            let original = try publishPostcard(in: repository)
            let work = try XCTUnwrap(repository.pendingImages(mode: mode).first)
            XCTAssertEqual(work.leaseExpiresAt, firstAttempt.addingTimeInterval(lease))
            let result = envelope(work, status: .failed, attemptedAt: firstAttempt.addingTimeInterval(86_400), reason: "network")
            XCTAssertEqual(try repository.markImage(result, mode: mode).status, .pendingImage)
            XCTAssertEqual(try repository.imageRetry(for: eventID)?.retryAt, firstAttempt.addingTimeInterval(delay))
            XCTAssertEqual(try repository.events().first?.narrativeProjection, original.narrativeProjection)
        }
    }

    func testThirdFailureBecomesUnavailableWithoutBlockingNextEvent() throws {
        let clock = RetryTestClock(now: firstAttempt)
        let repository = try TravelRepository(root: temporaryDirectory(), clock: clock)
        let original = try publishPostcard(in: repository, nextActionAt: firstAttempt)
        var last: ImageResultEnvelope?
        for expected in 0..<3 {
            let work = try XCTUnwrap(repository.pendingImages(mode: .fast).first)
            XCTAssertEqual(work.imageAttemptCount, expected)
            let result = envelope(work, status: .failed, attemptedAt: firstAttempt, reason: "network")
            last = result
            _ = try repository.markImage(result, mode: .fast)
            clock.now = clock.now.addingTimeInterval(expected == 0 ? 60 : 120)
        }
        XCTAssertEqual(try repository.events().first?.postcardStatus, .imageUnavailable)
        XCTAssertEqual(try repository.events().first?.narrativeProjection, original.narrativeProjection)
        XCTAssertTrue(try repository.pendingImages(mode: .fast).isEmpty)
        XCTAssertTrue(try repository.claimDue(mode: .fast, now: clock.now).due)
        XCTAssertEqual(try repository.markImage(try XCTUnwrap(last), mode: .fast).status, .imageUnavailable)
    }

    func testConcurrentSameAttemptCountsOnce() async throws {
        let clock = RetryTestClock(now: firstAttempt)
        let repository = try TravelRepository(root: temporaryDirectory(), clock: clock)
        _ = try publishPostcard(in: repository)
        let work = try XCTUnwrap(repository.pendingImages(mode: .fast).first)
        let result = envelope(work, status: .failed, attemptedAt: firstAttempt, reason: "network")
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 { group.addTask { _ = try? repository.markImage(result, mode: .fast) } }
        }
        XCTAssertEqual(try repository.imageRetry(for: eventID)?.attemptCount, 1)
    }

    func testMissingSidecarMigratesPendingAndMalformedOrSymlinkSidecarFailsClosed() throws {
        let clock = RetryTestClock(now: firstAttempt)
        let root = try temporaryDirectory()
        let repository = try TravelRepository(root: root, clock: clock)
        _ = try publishPostcard(in: repository)
        let sidecar = root.appendingPathComponent("state/image-retries.json")
        try FileManager.default.removeItem(at: sidecar)
        let reopened = try TravelRepository(root: root, clock: clock)
        XCTAssertEqual(try reopened.pendingImages(mode: .fast).first?.event.id, eventID)

        let corruptRoot = try temporaryDirectory()
        let corrupt = try TravelRepository(root: corruptRoot, clock: clock)
        _ = try publishPostcard(in: corrupt)
        try Data("{broken".utf8).write(to: corruptRoot.appendingPathComponent("state/image-retries.json"))
        XCTAssertThrowsError(try corrupt.pendingImages(mode: .fast))

        let linkedRoot = try temporaryDirectory()
        let linked = try TravelRepository(root: linkedRoot, clock: clock)
        _ = try publishPostcard(in: linked)
        let linkedSidecar = linkedRoot.appendingPathComponent("state/image-retries.json")
        let outside = linkedRoot.appendingPathComponent("outside.json")
        try Data("{}".utf8).write(to: outside)
        try FileManager.default.removeItem(at: linkedSidecar)
        try FileManager.default.createSymbolicLink(at: linkedSidecar, withDestinationURL: outside)
        XCTAssertThrowsError(try linked.pendingImages(mode: .fast))

        let orphanRoot = try temporaryDirectory()
        let orphan = try TravelRepository(root: orphanRoot, clock: clock)
        _ = try publishPostcard(in: orphan)
        let orphanSidecar = orphanRoot.appendingPathComponent("state/image-retries.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: orphanSidecar)) as? [String: Any])
        var entries = try XCTUnwrap(object["entries"] as? [String: Any])
        entries[UUID().uuidString.lowercased()] = try XCTUnwrap(entries[eventID.uuidString.lowercased()])
        object["entries"] = entries
        try JSONSerialization.data(withJSONObject: object).write(to: orphanSidecar, options: .atomic)
        XCTAssertThrowsError(try orphan.pendingImages(mode: .fast))
    }

    func testStrictImageEnvelopeRequiresAttemptBindingAndRejectsDuplicateUnknownBadDateAndOversize() throws {
        let token = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let hash = String(repeating: "a", count: 64)
        let valid = """
        {"eventId":"\(eventID.uuidString)","status":"failed","attemptedAt":"2026-08-11T12:00:00Z","relativePath":null,"reason":"network","attemptToken":"\(token)","attemptCount":0,"publishedNarrativeHash":"\(hash)"}
        """
        XCTAssertNoThrow(try ImageResultEnvelope.decode(Data(valid.utf8)))
        for invalid in [
            valid.replacingOccurrences(of: "\"status\":\"failed\"", with: "\"status\":\"failed\",\"status\":\"ready\""),
            valid.replacingOccurrences(of: "\"reason\":\"network\"", with: "\"reason\":\"network\",\"extra\":1"),
            valid.replacingOccurrences(of: "2026-08-11T12:00:00Z", with: "2026-08-11 12:00:00"),
            valid.replacingOccurrences(of: ",\"attemptToken\":\"\(token)\"", with: ""),
            valid.replacingOccurrences(of: token, with: "not-a-token"),
            valid.replacingOccurrences(of: "\"attemptCount\":0", with: "\"attemptCount\":3")
        ] { XCTAssertThrowsError(try ImageResultEnvelope.decode(Data(invalid.utf8))) }
        XCTAssertThrowsError(try ImageResultEnvelope.decode(Data(repeating: 0x20, count: 1_048_577)))
    }

    func testPublishedNarrativeMutationIsRejectedImmediately() throws {
        let clock = RetryTestClock(now: firstAttempt)
        let root = try temporaryDirectory()
        let repository = try TravelRepository(root: root, clock: clock)
        var event = try publishPostcard(in: repository)
        event = TripEvent(
            id: event.id, tripID: event.tripID, previousEventID: event.previousEventID,
            occurredAt: event.occurredAt, phase: event.phase, location: event.location,
            transport: event.transport, summary: "tampered", mood: event.mood,
            continuityReferences: event.continuityReferences, openHook: event.openHook,
            consumedItemID: event.consumedItemID, postcardStatus: event.postcardStatus,
            postcardRelativePath: event.postcardRelativePath
        )
        try writeJournal([event], root: root)
        XCTAssertThrowsError(try repository.pendingImages(mode: .fast)) { error in
            guard case RepositoryError.narrativeChanged(self.eventID) = error else { return XCTFail("Unexpected \(error)") }
        }
    }

    private func envelope(_ work: PendingImageWork, status: ImageResultStatus, attemptedAt: Date, reason: String?) -> ImageResultEnvelope {
        ImageResultEnvelope(
            eventId: work.event.id, status: status, attemptedAt: attemptedAt,
            relativePath: nil, reason: reason, attemptToken: work.attemptToken,
            attemptCount: work.imageAttemptCount, publishedNarrativeHash: work.publishedNarrativeHash
        )
    }

    @discardableResult
    private func publishPostcard(in repository: TravelRepository, nextActionAt: Date? = nil) throws -> TripEvent {
        let event = TripEvent.fixture(id: eventID, tripID: tripID, occurredAt: firstAttempt, phase: .preparing, postcardStatus: .pendingImage)
        try repository.publish(event: event, next: .fixture(
            stateVersion: 1, tripID: tripID, lastEventID: eventID, phase: .preparing,
            nextActionAt: nextActionAt ?? firstAttempt.addingTimeInterval(100), lastUpdatedAt: firstAttempt
        ))
        return event
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PostcardRetry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func writeJournal(_ events: [TripEvent], root: URL) throws {
        let encoder = JSONEncoder.travelCat
        encoder.outputFormatting = [.sortedKeys]
        var data = Data()
        for event in events { data.append(try encoder.encode(event)); data.append(0x0A) }
        try data.write(to: root.appendingPathComponent("journal/events.jsonl"), options: .atomic)
    }
}

private final class RetryTestClock: TravelClock, @unchecked Sendable {
    var now: Date
    init(now: Date) { self.now = now }
}

private struct RetryNarrativeProjection: Equatable {
    let summary: String
    let mood: Mood
    let location: Location?
    let openHook: String?
    let consumedItemID: String?
}

private extension TripEvent {
    var narrativeProjection: RetryNarrativeProjection {
        .init(summary: summary, mood: mood, location: location, openHook: openHook, consumedItemID: consumedItemID)
    }
}
