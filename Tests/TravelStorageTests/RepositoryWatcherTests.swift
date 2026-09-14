import Foundation
import Darwin
import XCTest
import TravelCore
@testable import TravelStorage

final class RepositoryWatcherTests: XCTestCase {
    func testExternalCharacterSelectionEmitsWhileActiveJourneyKeepsEffectiveProfileFrozen() async throws {
        let root = try temporaryDirectory()
        let repository = try TravelRepository(root: root, clock: FixedClock(now: Date(timeIntervalSince1970: 1_000)))
        let firstSource = try makeCharacterSource(id: "watcher-first", name: "第一只")
        let first = try repository.configureCharacter(.import(directory: firstSource)).selectedProfile
        _ = try repository.claimDue(mode: .fast, now: Date(timeIntervalSince1970: 1_000))
        let watcher = RepositoryWatcher(repository: repository, debounce: .milliseconds(20))
        let emitted = expectation(description: "initial and external selection")
        emitted.expectedFulfillmentCount = 2
        let task = Task {
            var values: [RepositoryContents] = []
            for await contents in watcher.contents() {
                values.append(contents)
                emitted.fulfill()
                if values.count == 2 { break }
            }
            return values
        }
        try await Task.sleep(for: .milliseconds(100))
        let secondSource = try makeCharacterSource(id: "watcher-second", name: "第二只")
        let second = try repository.configureCharacter(.import(directory: secondSource)).selectedProfile
        let lockedContents = try repository.withValidatedLockedContents { $0 }
        XCTAssertEqual(lockedContents.characterProfile, first)
        XCTAssertEqual(lockedContents.selectedCharacterProfile, second)

        await fulfillment(of: [emitted], timeout: 3)
        task.cancel()
        let values = await task.value
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(values.last?.characterProfile, first)
        XCTAssertEqual(values.last?.selectedCharacterProfile, second)
    }

    func testRetryBackoffIsBoundedAndResettable() {
        var backoff = RepositoryWatcherBackoff(baseDelay: 0.15, maximumDelay: 5)
        XCTAssertEqual((0..<8).map { _ in backoff.nextDelay() }, [0.15, 0.3, 0.6, 1.2, 2.4, 4.8, 5, 5])
        backoff.reset()
        XCTAssertEqual(backoff.nextDelay(), 0.15)
    }

    func testAtomicSnapshotReplacementEmitsExactlyOnceAfterInitialValue() async throws {
        let repository = try TravelRepository(root: temporaryDirectory())
        let watcher = RepositoryWatcher(repository: repository, debounce: .milliseconds(150))
        let expected = expectation(description: "initial and carried item")
        expected.expectedFulfillmentCount = 2
        let unexpected = expectation(description: "no extra snapshot emission")
        unexpected.isInverted = true
        let task = Task {
            var received: [RepositoryContents] = []
            for await contents in watcher.contents() {
                received.append(contents)
                if received.count <= 2 { expected.fulfill() }
                else { unexpected.fulfill() }
            }
            return received
        }
        try await Task.sleep(for: .milliseconds(100))
        _ = try repository.updateCarriedItem("camera")
        await fulfillment(of: [expected], timeout: 3)
        await fulfillment(of: [unexpected], timeout: 0.55)
        task.cancel()
        let values = await task.value
        XCTAssertEqual(values.map(\.snapshot.stateVersion), [0, 0])
        XCTAssertEqual(values.last?.snapshot.carriedItemID, "camera")
    }

    func testMarkImageEventOnlyChangeEmitsAndBurstDeduplicates() async throws {
        let clock = WatcherTestClock(now: Date(timeIntervalSince1970: 1_000))
        let repository = try TravelRepository(root: temporaryDirectory(), clock: clock)
        let event = TripEvent.fixture(postcardStatus: .pendingImage)
        try repository.publish(event: event, next: .fixture(stateVersion: 1, tripID: event.tripID, lastEventID: event.id))
        let watcher = RepositoryWatcher(repository: repository)
        let expected = expectation(description: "initial and mark image")
        expected.expectedFulfillmentCount = 2
        let unexpected = expectation(description: "no extra burst emission")
        unexpected.isInverted = true
        let task = Task {
            var received: [RepositoryContents] = []
            for await contents in watcher.contents() {
                received.append(contents)
                if received.count <= 2 { expected.fulfill() }
                else { unexpected.fulfill() }
            }
            return received
        }
        try await Task.sleep(for: .milliseconds(100))
        for offset in [0.0, 60.0, 180.0] {
            clock.now = Date(timeIntervalSince1970: 1_000 + offset)
            let work = try XCTUnwrap(repository.pendingImages(mode: .fast).first)
            _ = try repository.markImage(.init(
                eventId: event.id,
                status: .failed,
                attemptedAt: Date(timeIntervalSince1970: 1_000 + offset),
                relativePath: nil,
                reason: "watcher fixture",
                attemptToken: work.attemptToken,
                attemptCount: work.imageAttemptCount,
                publishedNarrativeHash: work.publishedNarrativeHash
            ), mode: .fast)
        }
        for _ in 0..<4 { _ = try? repository.updateCarriedItem(nil) }
        await fulfillment(of: [expected], timeout: 3)
        await fulfillment(of: [unexpected], timeout: 0.55)
        task.cancel()
        let values = await task.value
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(values.last?.events.last?.postcardStatus, .imageUnavailable)
    }

    func testCancellationReleasesStream() async throws {
        let repository = try TravelRepository(root: temporaryDirectory())
        let watcher = RepositoryWatcher(repository: repository)
        let started = expectation(description: "started")
        let task = Task {
            for await _ in watcher.contents() {
                started.fulfill()
            }
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(watcher.activeStreamCount, 1)
        task.cancel()
        _ = await task.result
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(watcher.activeStreamCount, 0)
    }

    func testInitialLoadRetriesTransientLockContention() async throws {
        let root = try temporaryDirectory()
        let repository = try TravelRepository(root: root)
        let lock = root.appendingPathComponent(".repository.lock")
        let lockDescriptor = open(lock.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(lockDescriptor, 0)
        XCTAssertEqual(flock(lockDescriptor, LOCK_EX | LOCK_NB), 0)
        defer { _ = close(lockDescriptor) }
        let watcher = RepositoryWatcher(repository: repository)
        let emitted = expectation(description: "emitted after lock release")
        let task = Task {
            for await _ in watcher.contents() {
                emitted.fulfill()
                break
            }
        }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(flock(lockDescriptor, LOCK_UN), 0)
        await fulfillment(of: [emitted], timeout: 3)
        task.cancel()
    }

    func testWatcherReopensAfterStateDirectoryReplacement() async throws {
        let root = try temporaryDirectory()
        let repository = try TravelRepository(root: root)
        let watcher = RepositoryWatcher(repository: repository)
        let emitted = expectation(description: "initial and post replacement")
        emitted.expectedFulfillmentCount = 2
        let task = Task {
            var count = 0
            for await _ in watcher.contents() {
                count += 1
                emitted.fulfill()
                if count == 2 { break }
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        let state = root.appendingPathComponent("state")
        let old = root.appendingPathComponent("state-old")
        try FileManager.default.moveItem(at: state, to: old)
        try await Task.sleep(for: .milliseconds(40))
        let journal = root.appendingPathComponent("journal/events.jsonl")
        try AtomicFileWriter().write(Data(contentsOf: journal), to: journal)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false)
        try FileManager.default.copyItem(
            at: old.appendingPathComponent("current-trip.json"),
            to: state.appendingPathComponent("current-trip.json")
        )
        if FileManager.default.fileExists(atPath: old.appendingPathComponent("settings.json").path) {
            try FileManager.default.copyItem(
                at: old.appendingPathComponent("settings.json"),
                to: state.appendingPathComponent("settings.json")
            )
        }
        try await Task.sleep(for: .milliseconds(400))
        _ = try repository.updateCarriedItem("camera")
        await fulfillment(of: [emitted], timeout: 3)
        task.cancel()
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RepositoryWatcherTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeCharacterSource(id: String, name: String) throws -> URL {
        let source = try temporaryDirectory().appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "id": id, "displayName": name, "description": "A travelling pet.",
            "spriteVersionNumber": 2, "spritesheetPath": "sprite.webp",
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: source.appendingPathComponent("pet.json"))
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.copyItem(
            at: project.appendingPathComponent("Sources/TravelUI/Resources/cute-black-cat-spritesheet.webp"),
            to: source.appendingPathComponent("sprite.webp")
        )
        return source
    }
}

private final class WatcherTestClock: TravelClock, @unchecked Sendable {
    var now: Date
    init(now: Date) { self.now = now }
}
