import Darwin
import Foundation
import ImageIO
import TravelCore
import UniformTypeIdentifiers
import XCTest
@testable import TravelStorage

final class PostcardRetrySecurityTests: XCTestCase {
    private let tripID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private let eventID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
    private let eventTime = Date(timeIntervalSince1970: 1_786_435_200)

    func testLeaseTokenAllowsExactlyOneResultFromOneDiscovery() throws {
        let clock = MutableTravelClock(now: eventTime.addingTimeInterval(10))
        let repository = try TravelRepository(root: temporaryDirectory(), clock: clock)
        try publishPending(in: repository)
        let work = try XCTUnwrap(repository.pendingImages(mode: .fast).first)
        let first = result(for: work, status: .failed, attemptedAt: clock.now, reason: "network")
        let conflicting = result(for: work, status: .rejectedIdentity, attemptedAt: clock.now, reason: "identity")

        XCTAssertEqual(try repository.markImage(first, mode: .fast).status, .pendingImage)
        XCTAssertThrowsError(try repository.markImage(conflicting, mode: .fast))
        XCTAssertEqual(try repository.imageRetry(for: eventID)?.attemptCount, 1)
    }

    func testLeaseExpiresAndCanBeClaimedAgainAfterCrash() throws {
        let clock = MutableTravelClock(now: eventTime.addingTimeInterval(10))
        let repository = try TravelRepository(root: temporaryDirectory(), clock: clock)
        try publishPending(in: repository)
        let first = try XCTUnwrap(repository.pendingImages(mode: .fast).first)
        for minute in 1..<30 {
            clock.now = eventTime.addingTimeInterval(10 + Double(minute * 60))
            XCTAssertTrue(try repository.pendingImages(mode: .fast).isEmpty, "minute \(minute)")
        }

        clock.now = first.leaseExpiresAt.addingTimeInterval(1)
        let reclaimed = try XCTUnwrap(repository.pendingImages(mode: .fast).first)
        XCTAssertNotEqual(reclaimed.attemptToken, first.attemptToken)
        XCTAssertEqual(reclaimed.imageAttemptCount, first.imageAttemptCount)
    }

    func testPendingPublishCrashReopensAlignedAndContinuesHeartbeatAndWatcher() async throws {
        let clock = MutableTravelClock(now: eventTime)
        let root = try temporaryDirectory()
        let repository = try TravelRepository(root: root, clock: clock)
        let preparing = TripEvent.fixture(
            id: UUID(), tripID: tripID, occurredAt: eventTime.addingTimeInterval(-180), phase: .preparing
        )
        try repository.publish(event: preparing, next: .fixture(
            stateVersion: 1, tripID: tripID, lastEventID: preparing.id, phase: .preparing,
            nextActionAt: eventTime.addingTimeInterval(-120), lastUpdatedAt: preparing.occurredAt
        ))
        let transit = TripEvent.fixture(
            id: UUID(), tripID: tripID, previousEventID: preparing.id,
            occurredAt: eventTime.addingTimeInterval(-120), phase: .transit
        )
        try repository.publish(event: transit, next: .fixture(
            stateVersion: 2, tripID: tripID, lastEventID: transit.id, phase: .transit,
            nextActionAt: eventTime.addingTimeInterval(-60), lastUpdatedAt: transit.occurredAt
        ))
        let exploring = TripEvent.fixture(
            id: UUID(), tripID: tripID, previousEventID: transit.id,
            occurredAt: eventTime.addingTimeInterval(-60), phase: .exploring, place: "Komachi Street"
        )
        try repository.publish(event: exploring, next: .fixture(
            stateVersion: 3, tripID: tripID, lastEventID: exploring.id, phase: .exploring,
            nextActionAt: eventTime, lastUpdatedAt: exploring.occurredAt,
            visitedPlaces: ["Komachi Street"]
        ))
        repository.publishAfterJournalHook = { throw SimulatedPublishCrash() }
        let event = TripEvent.fixture(
            id: eventID, tripID: tripID, previousEventID: exploring.id, occurredAt: eventTime,
            phase: .postcardReady, place: "Yuigahama Beach", postcardStatus: .pendingImage
        )
        let next = TripSnapshot.fixture(
            stateVersion: 4, tripID: tripID, lastEventID: eventID, phase: .postcardReady,
            nextActionAt: eventTime.addingTimeInterval(60), lastUpdatedAt: eventTime,
            visitedPlaces: ["Komachi Street", "Yuigahama Beach"]
        )

        XCTAssertThrowsError(try repository.publish(event: event, next: next))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("state/image-retries.json").path))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("journal/events.jsonl"), encoding: .utf8).split(separator: "\n").count, 4)

        let reopened = try TravelRepository(root: root, clock: clock)
        let contents = try reopened.loadContents()
        XCTAssertEqual(contents.snapshot.stateVersion, 4)
        XCTAssertEqual(contents.snapshot.lastEventID, eventID)
        XCTAssertEqual(contents.events.last, event)
        XCTAssertEqual(try reopened.imageRetry(for: eventID)?.attemptCount, 0)
        XCTAssertEqual(try reopened.pendingImages(mode: .fast).first?.event.id, eventID)

        let watcher = RepositoryWatcher(repository: reopened, debounce: .milliseconds(10))
        let watcherValue = expectation(description: "watcher reads recovered contents")
        let watcherTask = Task<RepositoryContents?, Never> {
            for await value in watcher.contents() {
                watcherValue.fulfill()
                return value
            }
            return nil
        }
        await fulfillment(of: [watcherValue], timeout: 2)
        watcherTask.cancel()
        let watchedContents = await watcherTask.value
        XCTAssertEqual(watchedContents, contents)

        let claim = try reopened.claimDue(mode: .fast, now: eventTime)
        XCTAssertTrue(claim.due)
        XCTAssertEqual(claim.snapshot, contents.snapshot)
        let candidate = AgentEventEnvelope(
            eventId: UUID(), tripId: tripID, previousEventId: eventID,
            occurredAt: eventTime.addingTimeInterval(60), phase: .returning,
            location: nil, transport: "train",
            summary: "黑猫收好海边明信片，搭上回程列车继续记住沿途的灯光。",
            mood: event.mood, continuityReferences: ["寻找慢一点的海边"],
            openHook: "回家后整理海风留下的故事", consumedItemId: nil,
            postcard: PostcardRequest(required: false, scenePrompt: nil)
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let validation = candidate.validationResult(
            previous: claim.snapshot, existingEventIDs: Set(contents.events.map(\.id)),
            mode: .fast, calendar: calendar
        )
        XCTAssertTrue(validation.valid, validation.violations.joined(separator: ","))
        let envelope = try XCTUnwrap(validation.publishEnvelope)
        clock.now = envelope.event.occurredAt
        XCTAssertEqual(try reopened.publish(event: envelope.event, next: envelope.next), 5)
        XCTAssertEqual(try reopened.loadContents().snapshot.stateVersion, 5)
    }

    func testReopenDoesNotAutoRecoverDiscontinuousJournal() throws {
        let root = try temporaryDirectory()
        _ = try TravelRepository(root: root)
        try writeJournal([
            TripEvent.fixture(id: eventID, tripID: tripID, occurredAt: eventTime, phase: .exploring, place: "Injected")
        ], root: root)

        XCTAssertThrowsError(try TravelRepository(root: root))
    }

    func testReopenDoesNotAutoRecoverCorruptSnapshotThatOnlyLooksOneBehind() throws {
        let root = try temporaryDirectory()
        let repository = try TravelRepository(root: root)
        let preparing = TripEvent.fixture(
            id: UUID(), tripID: tripID, occurredAt: eventTime.addingTimeInterval(-60), phase: .preparing
        )
        try repository.publish(event: preparing, next: .fixture(
            stateVersion: 1, tripID: tripID, lastEventID: preparing.id, phase: .preparing,
            nextActionAt: eventTime, lastUpdatedAt: preparing.occurredAt
        ))
        var corrupt = try repository.loadSnapshot()
        corrupt.usedItemIDs.insert("forged-item")
        try JSONEncoder.travelCat.encode(corrupt).write(to: repository.snapshotURL, options: .atomic)
        let transit = TripEvent.fixture(
            id: UUID(), tripID: tripID, previousEventID: preparing.id,
            occurredAt: eventTime, phase: .transit
        )
        try writeJournal([preparing, transit], root: root)

        XCTAssertThrowsError(try TravelRepository(root: root))
        XCTAssertEqual(try JSONDecoder.travelCat.decode(TripSnapshot.self, from: Data(contentsOf: repository.snapshotURL)), corrupt)
    }

    func testBaselineLegacyReadyFixtureMigratesAndRemainsFailClosedForReplay() throws {
        let root = try temporaryDirectory()
        let fixtureRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/migrations")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("state"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("journal"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("postcards/trip-1"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtureRoot.appendingPathComponent("baseline-ready-snapshot.json"), to: root.appendingPathComponent("state/current-trip.json"))
        try FileManager.default.copyItem(at: fixtureRoot.appendingPathComponent("baseline-ready-event.jsonl"), to: root.appendingPathComponent("journal/events.jsonl"))
        try writeImage(root.appendingPathComponent("postcards/trip-1/foo.png"), width: 768, height: 768)

        let repository = try TravelRepository(root: root, clock: MutableTravelClock(now: eventTime))
        let event = try XCTUnwrap(repository.events().first)
        XCTAssertEqual(event.postcardRelativePath, "trip-1/foo.png")
        XCTAssertEqual(try repository.imageRetry(for: event.id)?.imageContentHash?.count, 64)
        XCTAssertThrowsError(try repository.markImage(ImageResultEnvelope(
            eventId: event.id, status: .ready, attemptedAt: eventTime,
            relativePath: "trip-1/foo.png", reason: nil,
            attemptToken: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", attemptCount: 0,
            publishedNarrativeHash: try XCTUnwrap(repository.imageRetry(for: event.id)?.publishedNarrativeHash)
        ), mode: .fast))
    }

    func testNewReadyResultRejectsLegacyRelativePath() throws {
        let clock = MutableTravelClock(now: eventTime.addingTimeInterval(10))
        let root = try temporaryDirectory()
        let repository = try TravelRepository(root: root, clock: clock)
        try publishPending(in: repository)
        let work = try XCTUnwrap(repository.pendingImages(mode: .fast).first)
        try writeImage(root.appendingPathComponent("postcards/trip-1/foo.png"), width: 768, height: 768)

        XCTAssertThrowsError(try repository.markImage(
            result(for: work, status: .ready, attemptedAt: clock.now, path: "trip-1/foo.png"),
            mode: .fast
        ))
    }

    func testBaselineLegacyReadyMigrationRejectsHardlinkAndSymlink() throws {
        let fixtureRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/migrations")
        for kind in ["hardlink", "symlink"] {
            let root = try temporaryDirectory()
            try FileManager.default.createDirectory(at: root.appendingPathComponent("state"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("journal"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("postcards"), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: fixtureRoot.appendingPathComponent("baseline-ready-snapshot.json"), to: root.appendingPathComponent("state/current-trip.json"))
            try FileManager.default.copyItem(at: fixtureRoot.appendingPathComponent("baseline-ready-event.jsonl"), to: root.appendingPathComponent("journal/events.jsonl"))
            if kind == "hardlink" {
                let source = root.appendingPathComponent("source.png")
                try writeImage(source, width: 768, height: 768)
                try FileManager.default.createDirectory(at: root.appendingPathComponent("postcards/trip-1"), withIntermediateDirectories: true)
                XCTAssertEqual(link(source.path, root.appendingPathComponent("postcards/trip-1/foo.png").path), 0)
            } else {
                let outside = root.appendingPathComponent("outside")
                try writeImage(outside.appendingPathComponent("foo.png"), width: 768, height: 768)
                try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("postcards/trip-1"), withDestinationURL: outside)
            }

            XCTAssertThrowsError(try TravelRepository(root: root, clock: MutableTravelClock(now: eventTime)), kind)
        }
    }

    func testTrustedClockControlsBackoffWhileAttemptedAtIsAuditOnly() throws {
        let clock = MutableTravelClock(now: eventTime.addingTimeInterval(10))
        let repository = try TravelRepository(root: temporaryDirectory(), clock: clock)
        try publishPending(in: repository)
        let work = try XCTUnwrap(repository.pendingImages(mode: .fast).first)
        let future = result(for: work, status: .failed, attemptedAt: clock.now.addingTimeInterval(3_600), reason: "future")
        XCTAssertEqual(try repository.markImage(future, mode: .fast).status, .pendingImage)
        XCTAssertEqual(try repository.imageRetry(for: eventID)?.retryAt, clock.now.addingTimeInterval(60))
    }

    func testTerminalReadyOnlyAcceptsExactEnvelopeAndUnchangedContent() throws {
        let clock = MutableTravelClock(now: eventTime.addingTimeInterval(10))
        let root = try temporaryDirectory()
        let repository = try TravelRepository(root: root, clock: clock)
        try publishPending(in: repository)
        let work = try XCTUnwrap(repository.pendingImages(mode: .fast).first)
        let path = "postcards/\(tripID.uuidString.lowercased())/card.png"
        try writeImage(root.appendingPathComponent(path), width: 768, height: 768)
        let ready = result(for: work, status: .ready, attemptedAt: clock.now, path: path)
        XCTAssertEqual(try repository.markImage(ready, mode: .fast).status, .ready)
        XCTAssertEqual(try repository.markImage(ready, mode: .fast).status, .ready)

        var changed = ready
        changed = ImageResultEnvelope(
            eventId: changed.eventId, status: changed.status, attemptedAt: changed.attemptedAt,
            relativePath: changed.relativePath, reason: "different", attemptToken: changed.attemptToken,
            attemptCount: changed.attemptCount, publishedNarrativeHash: changed.publishedNarrativeHash
        )
        XCTAssertThrowsError(try repository.markImage(changed, mode: .fast))
        try writeImage(root.appendingPathComponent(path), width: 769, height: 768)
        XCTAssertThrowsError(try repository.markImage(ready, mode: .fast))
    }

    func testReadyRejectsHardlinkOversizeAndTopLevelPostcardsSymlink() throws {
        for kind in ["hardlink", "oversize", "top-symlink"] {
            let clock = MutableTravelClock(now: eventTime.addingTimeInterval(10))
            let root = try temporaryDirectory()
            let repository = try TravelRepository(root: root, clock: clock)
            try publishPending(in: repository)
            let work = try XCTUnwrap(repository.pendingImages(mode: .fast).first)
            let path = "postcards/\(tripID.uuidString.lowercased())/card.png"
            let url = root.appendingPathComponent(path)
            switch kind {
            case "hardlink":
                try writeImage(url, width: 768, height: 768)
                XCTAssertEqual(link(url.path, root.appendingPathComponent("alias.png").path), 0)
            case "oversize":
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(count: 15 * 1_024 * 1_024 + 1).write(to: url)
            default:
                let outside = root.appendingPathComponent("outside", isDirectory: true)
                try writeImage(outside.appendingPathComponent("\(tripID.uuidString.lowercased())/card.png"), width: 768, height: 768)
                try FileManager.default.removeItem(at: root.appendingPathComponent("postcards"))
                try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("postcards"), withDestinationURL: outside)
            }
            XCTAssertThrowsError(try repository.markImage(result(for: work, status: .ready, attemptedAt: clock.now, path: path), mode: .fast), kind)
        }
    }

    func testReadyRejectsPostcardsDirectorySwapBetweenValidationAndCommit() throws {
        let clock = MutableTravelClock(now: eventTime.addingTimeInterval(10))
        let root = try temporaryDirectory()
        let repository = try TravelRepository(root: root, clock: clock)
        try publishPending(in: repository)
        let work = try XCTUnwrap(repository.pendingImages(mode: .fast).first)
        let path = "postcards/\(tripID.uuidString.lowercased())/swap.png"
        try writeImage(root.appendingPathComponent(path), width: 768, height: 768)
        let replacement = root.appendingPathComponent("replacement-postcards")
        try writeImage(replacement.appendingPathComponent("\(tripID.uuidString.lowercased())/swap.png"), width: 768, height: 768)
        repository.imageValidationHook = {
            try! FileManager.default.moveItem(at: root.appendingPathComponent("postcards"), to: root.appendingPathComponent("old-postcards"))
            try! FileManager.default.moveItem(at: replacement, to: root.appendingPathComponent("postcards"))
        }

        XCTAssertThrowsError(try repository.markImage(result(for: work, status: .ready, attemptedAt: clock.now, path: path), mode: .fast))
        XCTAssertEqual(try repository.events().first?.postcardStatus, .pendingImage)
    }

    func testReopenFinishesReadyJournalFromPersistedSidecarIntent() throws {
        let clock = MutableTravelClock(now: eventTime.addingTimeInterval(10))
        let root = try temporaryDirectory()
        let repository = try TravelRepository(root: root, clock: clock)
        try publishPending(in: repository)
        let work = try XCTUnwrap(repository.pendingImages(mode: .fast).first)
        let path = "postcards/\(tripID.uuidString.lowercased())/intent.png"
        try writeImage(root.appendingPathComponent(path), width: 768, height: 768)
        let ready = result(for: work, status: .ready, attemptedAt: clock.now, path: path)
        _ = try repository.markImage(ready, mode: .fast)
        var event = try XCTUnwrap(repository.events().first)
        event.postcardStatus = .pendingImage
        event.postcardRelativePath = nil
        try writeJournal([event], root: root)

        let reopened = try TravelRepository(root: root, clock: clock)
        XCTAssertEqual(try reopened.events().first?.postcardStatus, .ready)
        XCTAssertEqual(try reopened.events().first?.postcardRelativePath, path)
        XCTAssertEqual(try reopened.markImage(ready, mode: .fast).status, .ready)
    }

    func testReopenRebuildsFailClosedSidecarFromTerminalJournal() throws {
        let clock = MutableTravelClock(now: eventTime.addingTimeInterval(10))
        let root = try temporaryDirectory()
        let repository = try TravelRepository(root: root, clock: clock)
        try publishPending(in: repository)
        let work = try XCTUnwrap(repository.pendingImages(mode: .fast).first)
        let path = "postcards/\(tripID.uuidString.lowercased())/journal.png"
        try writeImage(root.appendingPathComponent(path), width: 768, height: 768)
        let ready = result(for: work, status: .ready, attemptedAt: clock.now, path: path)
        _ = try repository.markImage(ready, mode: .fast)
        try FileManager.default.removeItem(at: root.appendingPathComponent("state/image-retries.json"))

        let reopened = try TravelRepository(root: root, clock: clock)
        XCTAssertEqual(try reopened.events().first?.postcardStatus, .ready)
        XCTAssertEqual(try reopened.imageRetry(for: eventID)?.imageContentHash?.count, 64)
        XCTAssertThrowsError(try reopened.markImage(ready, mode: .fast))
    }

    func testVersionOneTerminalSidecarMigratesFailClosed() throws {
        let clock = MutableTravelClock(now: eventTime.addingTimeInterval(10))
        let root = try temporaryDirectory()
        let repository = try TravelRepository(root: root, clock: clock)
        try publishPending(in: repository)
        let work = try XCTUnwrap(repository.pendingImages(mode: .fast).first)
        let path = "postcards/\(tripID.uuidString.lowercased())/legacy.png"
        try writeImage(root.appendingPathComponent(path), width: 768, height: 768)
        let ready = result(for: work, status: .ready, attemptedAt: clock.now, path: path)
        _ = try repository.markImage(ready, mode: .fast)

        let sidecar = root.appendingPathComponent("state/image-retries.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as? [String: Any])
        object["schemaVersion"] = 1
        var entries = try XCTUnwrap(object["entries"] as? [String: Any])
        var entry = try XCTUnwrap(entries[eventID.uuidString.lowercased()] as? [String: Any])
        for key in ["activeAttemptToken", "leaseExpiresAt", "terminalStatus", "terminalResultHash", "imageContentHash", "terminalRelativePath"] {
            entry.removeValue(forKey: key)
        }
        entries[eventID.uuidString.lowercased()] = entry
        object["entries"] = entries
        try JSONSerialization.data(withJSONObject: object).write(to: sidecar, options: .atomic)

        let reopened = try TravelRepository(root: root, clock: clock)
        XCTAssertEqual(try reopened.events().first?.postcardStatus, .ready)
        XCTAssertEqual(try reopened.imageRetry(for: eventID)?.imageContentHash?.count, 64)
        XCTAssertThrowsError(try reopened.markImage(ready, mode: .fast))
    }

    func testAdvisoryLockRecoversWhenHoldingProcessExits() throws {
        let root = try temporaryDirectory()
        let repository = try TravelRepository(root: root)
        let lockPath = root.appendingPathComponent(".repository.lock").path
        let child = Process()
        let output = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", "import fcntl,sys,time; f=open(sys.argv[1],'a'); fcntl.flock(f,fcntl.LOCK_EX); print('1',flush=True); time.sleep(30)", lockPath]
        child.standardOutput = output
        try child.run()
        XCTAssertEqual(try output.fileHandleForReading.read(upToCount: 2), Data("1\n".utf8))
        XCTAssertThrowsError(try repository.events())
        child.terminate()
        child.waitUntilExit()
        XCTAssertNoThrow(try repository.events())
    }

    private func publishPending(in repository: TravelRepository) throws {
        let event = TripEvent.fixture(id: eventID, tripID: tripID, occurredAt: eventTime, postcardStatus: .pendingImage)
        try repository.publish(event: event, next: .fixture(stateVersion: 1, tripID: tripID, lastEventID: eventID, lastUpdatedAt: eventTime))
    }

    private func result(
        for work: PendingImageWork, status: ImageResultStatus, attemptedAt: Date,
        path: String? = nil, reason: String? = nil
    ) -> ImageResultEnvelope {
        ImageResultEnvelope(
            eventId: work.event.id, status: status, attemptedAt: attemptedAt,
            relativePath: path, reason: reason, attemptToken: work.attemptToken,
            attemptCount: work.imageAttemptCount, publishedNarrativeHash: work.publishedNarrativeHash
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PostcardSecurity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func writeImage(_ url: URL, width: Int, height: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func writeJournal(_ events: [TripEvent], root: URL) throws {
        let encoder = JSONEncoder.travelCat
        encoder.outputFormatting = [.sortedKeys]
        var data = Data()
        for event in events {
            data.append(try encoder.encode(event))
            data.append(0x0A)
        }
        try data.write(to: root.appendingPathComponent("journal/events.jsonl"), options: .atomic)
    }
}

private final class MutableTravelClock: TravelClock, @unchecked Sendable {
    var now: Date
    init(now: Date) { self.now = now }
}

private struct SimulatedPublishCrash: Error {}
