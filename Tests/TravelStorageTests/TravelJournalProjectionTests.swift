import Foundation
import XCTest
import TravelCore
@testable import TravelStorage

final class TravelJournalProjectionTests: XCTestCase {
    func testProjectionSelectsCurrentAndLatestReadyPostcard() throws {
        let tripID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let preparing = TripEvent.fixture(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            tripID: tripID,
            occurredAt: Date(timeIntervalSince1970: 10),
            phase: .preparing
        )
        var unavailable = TripEvent.fixture(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            tripID: tripID,
            previousEventID: preparing.id,
            occurredAt: Date(timeIntervalSince1970: 20),
            phase: .postcardReady
        )
        unavailable.postcardStatus = PostcardStatus.imageUnavailable
        var ready = TripEvent.fixture(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000003")!,
            tripID: tripID,
            previousEventID: unavailable.id,
            occurredAt: Date(timeIntervalSince1970: 30),
            phase: .postcardReady
        )
        ready.postcardStatus = PostcardStatus.ready
        ready.postcardRelativePath = "postcards/\(tripID.uuidString.lowercased())/latest.png"

        let snapshot = TripSnapshot.fixture(
            stateVersion: 3,
            tripID: tripID,
            lastEventID: ready.id,
            phase: .postcardReady
        )

        let view = TravelJournalProjection.make(
            contents: RepositoryContents(snapshot: snapshot, events: [preparing, unavailable, ready]),
            now: .distantFuture
        )

        XCTAssertEqual(view.currentEvent?.id, ready.id)
        XCTAssertEqual(view.latestReadyPostcard?.eventID, ready.id)
        XCTAssertEqual(view.postcardCount, 2)
        XCTAssertEqual(view.album.map { $0.eventID }, [unavailable.id, ready.id])
    }

    func testProjectionKeepsOnlyNewestOneHundredAlbumEntries() {
        let events = (0..<105).map { index -> TripEvent in
            var event = TripEvent.fixture(
                id: uuid(index + 1),
                tripID: uuid(1_000 + index),
                occurredAt: Date(timeIntervalSince1970: TimeInterval(index)),
                phase: .postcardReady
            )
            event.postcardStatus = PostcardStatus.imageUnavailable
            return event
        }
        let snapshot = TripSnapshot.fixture(
            stateVersion: events.count,
            tripID: events.last!.tripID,
            lastEventID: events.last!.id,
            phase: .postcardReady
        )

        let view = TravelJournalProjection.make(
            contents: RepositoryContents(snapshot: snapshot, events: events),
            albumLimit: 100,
            now: .distantFuture
        )

        XCTAssertEqual(view.postcardCount, 105)
        XCTAssertEqual(view.album.count, 100)
        XCTAssertEqual(view.album.first?.eventID, events[5].id)
        XCTAssertEqual(view.album.last?.eventID, events[104].id)
    }

    func testProjectionSortsChronologicalAndStableByJournalIndex() {
        let tripID = UUID()
        let first = TripEvent.fixture(
            id: UUID(),
            tripID: tripID,
            occurredAt: Date(timeIntervalSince1970: 100),
            phase: .postcardReady
        )
        let second = TripEvent.fixture(
            id: UUID(),
            tripID: tripID,
            occurredAt: Date(timeIntervalSince1970: 100),
            phase: .postcardReady
        )
        let third = TripEvent.fixture(
            id: UUID(),
            tripID: tripID,
            occurredAt: Date(timeIntervalSince1970: 101),
            phase: .postcardReady
        )

        var firstReady = first
        var secondReady = second
        var thirdReady = third
        firstReady.postcardStatus = PostcardStatus.ready
        secondReady.postcardStatus = PostcardStatus.ready
        thirdReady.postcardStatus = PostcardStatus.ready

        let snapshot = TripSnapshot.fixture(
            stateVersion: 3,
            tripID: tripID,
            lastEventID: thirdReady.id,
            phase: .postcardReady
        )
        let view = TravelJournalProjection.make(
            contents: RepositoryContents(snapshot: snapshot, events: [firstReady, secondReady, thirdReady]),
            now: .distantFuture
        )

        XCTAssertEqual(view.album.map { $0.eventID }, [firstReady.id, secondReady.id, thirdReady.id])
    }

    func testProjectionExcludesFutureEventsFromEveryDerivedSurfaceAndIncludesBoundary() {
        let tripID = UUID()
        let past = readyEvent(tripID: tripID, time: 99)
        let boundary = readyEvent(tripID: tripID, time: 100)
        let future = readyEvent(tripID: tripID, time: 101)
        let snapshot = TripSnapshot.fixture(
            stateVersion: 3, tripID: tripID, lastEventID: future.id, phase: .postcardReady)

        let view = TravelJournalProjection.make(
            contents: RepositoryContents(snapshot: snapshot, events: [future, past, boundary]),
            now: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(view.snapshot, snapshot)
        XCTAssertNil(view.currentEvent)
        XCTAssertEqual(view.latestReadyPostcard?.eventID, boundary.id)
        XCTAssertEqual(view.postcardCount, 2)
        XCTAssertEqual(view.album.map(\.eventID), [past.id, boundary.id])
    }

    private func readyEvent(tripID: UUID, time: TimeInterval) -> TripEvent {
        var event = TripEvent.fixture(
            id: UUID(), tripID: tripID, occurredAt: Date(timeIntervalSince1970: time),
            phase: .postcardReady)
        event.postcardStatus = .ready
        event.postcardRelativePath = "postcards/\(tripID.uuidString.lowercased())/\(event.id.uuidString.lowercased()).png"
        return event
    }

    private func uuid(_ value: Int) -> UUID {
        let uuidString = String(format: "00000000-0000-0000-0000-%012d", value)
        return UUID(uuidString: uuidString)!
    }
}
