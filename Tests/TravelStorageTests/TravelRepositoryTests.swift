import Foundation
import XCTest
import TravelCore
@testable import TravelStorage

final class TravelRepositoryTests: XCTestCase {
    func testHistoricalJournalRetainsOriginal80ScalarMoodQuote() throws {
        let root = try temporaryDirectory()
        let repository = try TravelRepository(root: root)
        let fullQuote = String(repeating: "旅", count: 39) + "\n" + String(repeating: "途", count: 40)
        XCTAssertEqual(fullQuote.unicodeScalars.count, 80)
        let base = TripEvent.fixture(phase: .preparing)
        let event = TripEvent(
            id: base.id,
            tripID: base.tripID,
            previousEventID: base.previousEventID,
            occurredAt: base.occurredAt,
            phase: base.phase,
            location: base.location,
            transport: base.transport,
            summary: base.summary,
            mood: Mood(level: base.mood.level, label: base.mood.label, quote: fullQuote),
            continuityReferences: base.continuityReferences,
            openHook: base.openHook,
            consumedItemID: base.consumedItemID,
            postcardStatus: base.postcardStatus,
            postcardRelativePath: base.postcardRelativePath
        )
        let next = TripSnapshot.fixture(
            stateVersion: 1,
            tripID: event.tripID,
            lastEventID: event.id,
            phase: event.phase,
            mood: event.mood
        )

        try repository.publish(event: event, next: next)

        XCTAssertEqual(try TravelRepository(root: root).events().first?.mood.quote, fullQuote)
    }

    func testUpdateCarriedItemPersistsAndRejectsAwayWithoutMutation() throws {
        let root = try temporaryDirectory()
        let repository = try TravelRepository(root: root)

        let selected = try repository.updateCarriedItem("camera")
        XCTAssertEqual(selected.carriedItemID, "camera")
        XCTAssertEqual(try TravelRepository(root: root).loadSnapshot().carriedItemID, "camera")
        XCTAssertNil(try repository.updateCarriedItem(nil).carriedItemID)

        let event = TripEvent.fixture(phase: .preparing)
        try repository.publish(event: event, next: .fixture(stateVersion: 1, tripID: event.tripID, lastEventID: event.id, phase: .preparing))
        let transit = TripEvent.fixture(tripID: event.tripID, previousEventID: event.id, phase: .transit)
        try repository.publish(event: transit, next: .fixture(stateVersion: 2, tripID: event.tripID, lastEventID: transit.id, phase: .transit))
        XCTAssertThrowsError(try repository.updateCarriedItem("camera")) { error in
            guard case RepositoryError.catIsAway = error else { return XCTFail("Unexpected \(error)") }
        }
        XCTAssertNil(try repository.loadSnapshot().carriedItemID)
    }

    func testBootstrapCreatesLayoutAndDoesNotOverwriteExistingData() throws {
        let root = try temporaryDirectory()
        let state = root.appendingPathComponent("state", isDirectory: true)
        let journal = root.appendingPathComponent("journal", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
        let existingSnapshot = TripSnapshot.fixture(stateVersion: 7)
        let snapshotData = try JSONEncoder.travelCat.encode(existingSnapshot)
        let existingLog = Data("\n".utf8)
        try snapshotData.write(to: state.appendingPathComponent("current-trip.json"))
        try existingLog.write(to: journal.appendingPathComponent("events.jsonl"))

        let repository = try TravelRepository(root: root)

        XCTAssertEqual(try repository.loadSnapshot(), existingSnapshot)
        XCTAssertEqual(try Data(contentsOf: journal.appendingPathComponent("events.jsonl")), existingLog)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("postcards").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("inbox").path))
    }

    func testPublishingSameEventTwiceIsIdempotentWithoutAdvancingSnapshotTwice() throws {
        let repository = try TravelRepository(root: temporaryDirectory())
        let event = TripEvent.fixture()
        let next = TripSnapshot.fixture(stateVersion: 1, tripID: event.tripID, lastEventID: event.id)

        try repository.publish(event: event, next: next)
        let acknowledgedVersion = try repository.publish(
            event: event,
            next: .fixture(stateVersion: 999, tripID: event.tripID, lastEventID: UUID())
        )

        XCTAssertEqual(acknowledgedVersion, 1)
        XCTAssertEqual(try repository.events(), [event])
        XCTAssertEqual(try repository.loadSnapshot(), next)
        let nonblankLines = try String(
            contentsOf: repository.root.appendingPathComponent("journal/events.jsonl"),
            encoding: .utf8
        ).split(whereSeparator: \.isNewline)
        XCTAssertEqual(nonblankLines.count, 1)
    }

    func testDuplicatePublishRequiresRecoveryWhenJournalIsAheadOfSnapshot() throws {
        let repository = try TravelRepository(root: temporaryDirectory())
        let staleSnapshot = try repository.loadSnapshot()
        let event = TripEvent.fixture(place: "Enoshima", consumedItemID: "onigiri")
        let next = TripSnapshot.fixture(
            stateVersion: 1,
            tripID: event.tripID,
            lastEventID: event.id,
            phase: event.phase
        )
        try writeJournal([event], to: repository)

        XCTAssertThrowsError(try repository.publish(event: event, next: next)) { error in
            guard case RepositoryError.recoveryRequired = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try repository.loadSnapshot(), staleSnapshot)

        let recovered = try repository.recover()
        XCTAssertEqual(recovered.stateVersion, 1)
        XCTAssertEqual(recovered.lastEventID, event.id)
        XCTAssertNoThrow(try repository.publish(
            event: event,
            next: .fixture(stateVersion: 999, tripID: UUID(), lastEventID: UUID())
        ))
        XCTAssertEqual(try repository.loadSnapshot(), recovered)
    }

    func testNewPublishRequiresRecoveryWhenJournalIsAheadOfSnapshot() throws {
        let repository = try TravelRepository(root: temporaryDirectory())
        let staleSnapshot = try repository.loadSnapshot()
        let first = TripEvent.fixture(phase: .preparing)
        try writeJournal([first], to: repository)
        let second = TripEvent.fixture(
            tripID: first.tripID,
            previousEventID: first.id,
            phase: .transit
        )
        let next = TripSnapshot.fixture(
            stateVersion: 2,
            tripID: first.tripID,
            lastEventID: second.id,
            phase: .transit
        )

        XCTAssertThrowsError(try repository.publish(event: second, next: next)) { error in
            guard case RepositoryError.recoveryRequired = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try repository.events(), [first])
        XCTAssertEqual(try repository.loadSnapshot(), staleSnapshot)

        let recovered = try repository.recover()
        XCTAssertEqual(recovered.stateVersion, 1)
        XCTAssertEqual(try repository.publish(event: second, next: next), 2)
        XCTAssertEqual(try repository.events(), [first, second])
        XCTAssertEqual(try repository.loadSnapshot(), next)
    }

    func testDuplicateEventIDWithDifferentPayloadIsRejected() throws {
        let repository = try TravelRepository(root: temporaryDirectory())
        let event = TripEvent.fixture()
        let next = TripSnapshot.fixture(
            stateVersion: 1,
            tripID: event.tripID,
            lastEventID: event.id,
            phase: event.phase
        )
        try repository.publish(event: event, next: next)
        let conflicting = TripEvent.fixture(
            id: event.id,
            tripID: event.tripID,
            occurredAt: event.occurredAt.addingTimeInterval(1),
            phase: event.phase
        )

        XCTAssertThrowsError(try repository.publish(event: conflicting, next: next)) { error in
            guard case RepositoryError.eventConflict(event.id) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try repository.events(), [event])
        XCTAssertEqual(try repository.loadSnapshot(), next)
    }

    func testPublishRejectsVersionConflict() throws {
        let repository = try TravelRepository(root: temporaryDirectory())
        let event = TripEvent.fixture()

        XCTAssertThrowsError(try repository.publish(
            event: event,
            next: .fixture(stateVersion: 2, tripID: event.tripID, lastEventID: event.id)
        )) { error in
            guard case RepositoryError.versionConflict = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try repository.events(), [])
    }

    func testPublishRejectsPreviousEventAndSnapshotLinkConflicts() throws {
        let repository = try TravelRepository(root: temporaryDirectory())
        let event = TripEvent.fixture(previousEventID: UUID())

        XCTAssertThrowsError(try repository.publish(
            event: event,
            next: .fixture(stateVersion: 1, tripID: event.tripID, lastEventID: event.id)
        )) { error in
            guard case RepositoryError.continuityConflict = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let unlinked = TripEvent.fixture()
        XCTAssertThrowsError(try repository.publish(
            event: unlinked,
            next: .fixture(stateVersion: 1, tripID: unlinked.tripID, lastEventID: UUID())
        )) { error in
            guard case RepositoryError.continuityConflict = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testPublishRejectsEventsAndSnapshotsFromFuture() throws {
        let root = try temporaryDirectory()
        let clock = FixedClock(now: Date(timeIntervalSince1970: 120))
        let repository = try TravelRepository(root: root, clock: clock)
        let future = Date(timeIntervalSince1970: 180)

        let event = TripEvent.fixture(
            occurredAt: future,
            phase: .preparing
        )
        let futureByEvent = TripSnapshot.fixture(
            stateVersion: 1,
            tripID: event.tripID,
            lastEventID: event.id,
            phase: event.phase,
            lastUpdatedAt: Date(timeIntervalSince1970: 110)
        )
        XCTAssertThrowsError(try repository.publish(event: event, next: futureByEvent)) { error in
            guard case RepositoryError.eventInFuture = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try repository.events(), [])

        let inTimeEvent = TripEvent.fixture(
            id: UUID(),
            tripID: event.tripID,
            occurredAt: Date(timeIntervalSince1970: 100),
            phase: .preparing
        )
        let futureBySnapshot = TripSnapshot.fixture(
            stateVersion: 1,
            tripID: inTimeEvent.tripID,
            lastEventID: inTimeEvent.id,
            phase: inTimeEvent.phase,
            lastUpdatedAt: future
        )
        XCTAssertThrowsError(try repository.publish(event: inTimeEvent, next: futureBySnapshot)) { error in
            guard case RepositoryError.eventInFuture = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try repository.events(), [])
    }

    func testPublishAllowsNewTripOnlyFromRestingToPreparing() throws {
        let repository = try TravelRepository(root: temporaryDirectory())
        let oldTripID = UUID()
        let newTripID = UUID()
        let preparing = TripEvent.fixture(tripID: oldTripID, phase: .preparing)
        try repository.publish(
            event: preparing,
            next: .fixture(
                stateVersion: 1,
                tripID: oldTripID,
                lastEventID: preparing.id,
                phase: .preparing
            )
        )
        let transit = TripEvent.fixture(
            tripID: oldTripID,
            previousEventID: preparing.id,
            phase: .transit
        )
        try repository.publish(
            event: transit,
            next: .fixture(
                stateVersion: 2,
                tripID: oldTripID,
                lastEventID: transit.id,
                phase: .transit
            )
        )
        let returning = TripEvent.fixture(
            tripID: oldTripID,
            previousEventID: transit.id,
            phase: .returning
        )
        try repository.publish(
            event: returning,
            next: .fixture(
                stateVersion: 3,
                tripID: oldTripID,
                lastEventID: returning.id,
                phase: .returning
            )
        )
        let resting = TripEvent.fixture(
            tripID: oldTripID,
            previousEventID: returning.id,
            phase: .resting
        )
        try repository.publish(
            event: resting,
            next: .fixture(
                stateVersion: 4,
                tripID: oldTripID,
                lastEventID: resting.id,
                phase: .resting
            )
        )
        let departure = TripEvent.fixture(
            tripID: newTripID,
            previousEventID: resting.id,
            phase: .preparing
        )
        let next = TripSnapshot.fixture(
            stateVersion: 5,
            tripID: newTripID,
            lastEventID: departure.id,
            phase: .preparing
        )

        XCTAssertNoThrow(try repository.publish(event: departure, next: next))
        XCTAssertEqual(try repository.loadSnapshot(), next)
    }

    func testPublishRejectsInvalidFirstTripPhaseWhenCurrentTripIsNil() throws {
        let repository = try TravelRepository(root: temporaryDirectory())
        let event = TripEvent.fixture(phase: .exploring)

        XCTAssertThrowsError(try repository.publish(
            event: event,
            next: .fixture(
                stateVersion: 1,
                tripID: event.tripID,
                lastEventID: event.id,
                phase: event.phase
            )
        )) { error in
            guard case RepositoryError.continuityConflict = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testPublishRejectsTripChangeMidTripAndEventSnapshotPhaseMismatch() throws {
        let repository = try TravelRepository(root: temporaryDirectory())
        let oldTripID = UUID()
        let preparing = TripEvent.fixture(tripID: oldTripID, phase: .preparing)
        try repository.publish(
            event: preparing,
            next: .fixture(
                stateVersion: 1,
                tripID: oldTripID,
                lastEventID: preparing.id,
                phase: .preparing
            )
        )
        let transit = TripEvent.fixture(
            tripID: oldTripID,
            previousEventID: preparing.id,
            phase: .transit
        )
        try repository.publish(
            event: transit,
            next: .fixture(
                stateVersion: 2,
                tripID: oldTripID,
                lastEventID: transit.id,
                phase: .transit
            )
        )
        let exploring = TripEvent.fixture(
            tripID: oldTripID,
            previousEventID: transit.id,
            phase: .exploring
        )
        try repository.publish(
            event: exploring,
            next: .fixture(
                stateVersion: 3,
                tripID: oldTripID,
                lastEventID: exploring.id,
                phase: .exploring
            )
        )
        let otherTripEvent = TripEvent.fixture(
            tripID: UUID(),
            previousEventID: exploring.id,
            phase: .preparing
        )

        XCTAssertThrowsError(try repository.publish(
            event: otherTripEvent,
            next: .fixture(
                stateVersion: 4,
                tripID: otherTripEvent.tripID,
                lastEventID: otherTripEvent.id,
                phase: .preparing
            )
        )) { error in
            guard case RepositoryError.continuityConflict = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let sameTripEvent = TripEvent.fixture(
            tripID: oldTripID,
            previousEventID: exploring.id,
            phase: .returning
        )
        XCTAssertThrowsError(try repository.publish(
            event: sameTripEvent,
            next: .fixture(
                stateVersion: 4,
                tripID: oldTripID,
                lastEventID: sameTripEvent.id,
                phase: .transit
            )
        )) { error in
            guard case RepositoryError.continuityConflict = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testPublishRejectsIllegalSameTripTransitionAndAcceptsRecoverableTransition() throws {
        let repository = try TravelRepository(root: temporaryDirectory())
        let preparing = TripEvent.fixture(phase: .preparing)
        try repository.publish(
            event: preparing,
            next: .fixture(
                stateVersion: 1,
                tripID: preparing.tripID,
                lastEventID: preparing.id,
                phase: .preparing
            )
        )
        let illegalExploring = TripEvent.fixture(
            tripID: preparing.tripID,
            previousEventID: preparing.id,
            phase: .exploring
        )

        XCTAssertThrowsError(try repository.publish(
            event: illegalExploring,
            next: .fixture(
                stateVersion: 2,
                tripID: preparing.tripID,
                lastEventID: illegalExploring.id,
                phase: .exploring
            )
        )) { error in
            guard case RepositoryError.continuityConflict = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let transit = TripEvent.fixture(
            tripID: preparing.tripID,
            previousEventID: preparing.id,
            phase: .transit
        )
        let acknowledgedVersion = try repository.publish(
            event: transit,
            next: .fixture(
                stateVersion: 2,
                tripID: preparing.tripID,
                lastEventID: transit.id,
                phase: .transit
            )
        )

        XCTAssertEqual(acknowledgedVersion, 2)
        XCTAssertEqual(try repository.events(), [preparing, transit])
        XCTAssertNoThrow(try repository.recover())
    }

    func testEventsRoundTripJSONLWithBlankLinesAndMalformedRecordIsReported() throws {
        let repository = try TravelRepository(root: temporaryDirectory())
        let first = TripEvent.fixture()
        let second = TripEvent.fixture(
            tripID: first.tripID,
            previousEventID: first.id,
            phase: .transit
        )
        try repository.publish(
            event: first,
            next: .fixture(stateVersion: 1, tripID: first.tripID, lastEventID: first.id)
        )
        try repository.publish(
            event: second,
            next: .fixture(
                stateVersion: 2,
                tripID: first.tripID,
                lastEventID: second.id,
                phase: second.phase
            )
        )
        let journal = repository.root.appendingPathComponent("journal/events.jsonl")
        var data = try Data(contentsOf: journal)
        data.append(Data("\n  \n".utf8))
        try data.write(to: journal)
        XCTAssertEqual(try repository.events(), [first, second])

        data.append(Data("{broken}\n".utf8))
        try data.write(to: journal)
        XCTAssertThrowsError(try repository.events()) { error in
            guard case let RepositoryError.malformedJournal(line, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(line, 5)
        }
    }

    func testRecoverRepairsCorruptedSnapshotFromValidJournal() throws {
        let repository = try TravelRepository(root: temporaryDirectory())
        let first = TripEvent.fixture(place: "Hasedera", consumedItemID: "tea")
        let second = TripEvent.fixture(
            tripID: first.tripID,
            previousEventID: first.id,
            occurredAt: Date(timeIntervalSince1970: 200),
            phase: .transit,
            place: "Great Buddha",
            consumedItemID: "snack"
        )
        try repository.publish(
            event: first,
            next: .fixture(stateVersion: 1, tripID: first.tripID, lastEventID: first.id)
        )
        try repository.publish(
            event: second,
            next: .fixture(
                stateVersion: 2,
                tripID: first.tripID,
                lastEventID: second.id,
                phase: second.phase
            )
        )
        try Data("broken snapshot".utf8).write(to: repository.snapshotURL)

        let recovered = try repository.recover()

        XCTAssertEqual(recovered.stateVersion, 2)
        XCTAssertEqual(recovered.lastEventID, second.id)
        XCTAssertEqual(recovered.tripID, first.tripID)
        XCTAssertEqual(recovered.phase, second.phase)
        XCTAssertEqual(recovered.nextActionAt, second.occurredAt)
        XCTAssertEqual(recovered.usedItemIDs, ["tea", "snack"])
        XCTAssertEqual(recovered.visitedPlaces, ["Hasedera", "Great Buddha"])
        XCTAssertNil(recovered.carriedItemID)
        XCTAssertEqual(try repository.loadSnapshot(), recovered)
    }

    func testRecoverRepairsValidSnapshotThatIsOneEventBehindJournal() throws {
        let repository = try TravelRepository(root: temporaryDirectory())
        let staleSnapshot = try repository.loadSnapshot()
        let event = TripEvent.fixture(
            occurredAt: Date(timeIntervalSince1970: 300),
            phase: .preparing,
            place: "Enoshima",
            consumedItemID: "onigiri"
        )
        try writeJournal([event], to: repository)

        XCTAssertEqual(staleSnapshot.stateVersion, 0)
        XCTAssertNil(staleSnapshot.lastEventID)
        XCTAssertEqual(try repository.loadSnapshot(), staleSnapshot)

        let recovered = try repository.recover()

        XCTAssertEqual(recovered.stateVersion, 1)
        XCTAssertEqual(recovered.lastEventID, event.id)
        XCTAssertEqual(recovered.tripID, event.tripID)
        XCTAssertEqual(recovered.phase, event.phase)
        XCTAssertEqual(recovered.nextActionAt, event.occurredAt)
        XCTAssertEqual(recovered.lastUpdatedAt, event.occurredAt)
        XCTAssertEqual(recovered.mood, event.mood)
        XCTAssertEqual(recovered.openHook, event.openHook)
        XCTAssertEqual(recovered.usedItemIDs, ["onigiri"])
        XCTAssertEqual(recovered.visitedPlaces, ["Enoshima"])
        XCTAssertEqual(try repository.loadSnapshot(), recovered)
    }

    func testRecoverRejectsInvalidFirstPhaseTripBoundaryAndSameTripTransition() throws {
        let repository = try TravelRepository(root: temporaryDirectory())
        let invalidFirst = TripEvent.fixture(phase: .exploring)
        try writeJournal([invalidFirst], to: repository)
        assertContinuityConflict(try repository.recover())

        let first = TripEvent.fixture(phase: .preparing)
        let invalidTripChange = TripEvent.fixture(
            tripID: UUID(),
            previousEventID: first.id,
            phase: .exploring
        )
        try writeJournal([first, invalidTripChange], to: repository)
        assertContinuityConflict(try repository.recover())

        let illegalSameTrip = TripEvent.fixture(
            tripID: first.tripID,
            previousEventID: first.id,
            phase: .exploring
        )
        try writeJournal([first, illegalSameTrip], to: repository)
        assertContinuityConflict(try repository.recover())
    }

    func testRecoverValidMultipleTripsKeepsOnlyCurrentTripDerivedState() throws {
        let repository = try TravelRepository(root: temporaryDirectory())
        let firstTripID = UUID()
        let secondTripID = UUID()
        let first = TripEvent.fixture(
            tripID: firstTripID,
            phase: .preparing,
            place: "Old Start",
            consumedItemID: "old-map"
        )
        let transit = TripEvent.fixture(
            tripID: firstTripID,
            previousEventID: first.id,
            phase: .transit
        )
        let returning = TripEvent.fixture(
            tripID: firstTripID,
            previousEventID: transit.id,
            phase: .returning
        )
        let resting = TripEvent.fixture(
            tripID: firstTripID,
            previousEventID: returning.id,
            phase: .resting,
            place: "Old Home",
            consumedItemID: "old-snack"
        )
        let newPreparing = TripEvent.fixture(
            tripID: secondTripID,
            previousEventID: resting.id,
            phase: .preparing,
            place: "New Start",
            consumedItemID: "new-map"
        )
        let newTransit = TripEvent.fixture(
            tripID: secondTripID,
            previousEventID: newPreparing.id,
            phase: .transit
        )
        let newExploring = TripEvent.fixture(
            tripID: secondTripID,
            previousEventID: newTransit.id,
            phase: .exploring,
            place: "New Place",
            consumedItemID: "new-snack"
        )
        let events = [first, transit, returning, resting, newPreparing, newTransit, newExploring]
        try writeJournal(events, to: repository)

        let recovered = try repository.recover()

        XCTAssertEqual(recovered.stateVersion, events.count)
        XCTAssertEqual(recovered.tripID, secondTripID)
        XCTAssertEqual(recovered.lastEventID, newExploring.id)
        XCTAssertEqual(recovered.phase, .exploring)
        XCTAssertEqual(recovered.usedItemIDs, ["new-map", "new-snack"])
        XCTAssertEqual(recovered.visitedPlaces, ["New Start", "New Place"])
        XCTAssertEqual(try repository.loadSnapshot(), recovered)
    }

    func testRecoverEmptyJournalPersistsDeterministicEmptySnapshot() throws {
        let repository = try TravelRepository(root: temporaryDirectory())
        try Data("broken snapshot".utf8).write(to: repository.snapshotURL)

        let recovered = try repository.recover()

        XCTAssertEqual(recovered, .empty(now: Date(timeIntervalSince1970: 0)))
        XCTAssertEqual(try repository.loadSnapshot(), recovered)
    }

    func testRecoverRejectsBrokenChainAndDuplicateIDs() throws {
        let repository = try TravelRepository(root: temporaryDirectory())
        let first = TripEvent.fixture()
        let broken = TripEvent.fixture(tripID: first.tripID, previousEventID: UUID())
        try writeJournal([first, broken], to: repository)
        XCTAssertThrowsError(try repository.recover()) { error in
            guard case RepositoryError.brokenJournalChain = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let duplicate = TripEvent.fixture(id: first.id, tripID: first.tripID, previousEventID: first.id)
        try writeJournal([first, duplicate], to: repository)
        XCTAssertThrowsError(try repository.recover()) { error in
            guard case RepositoryError.duplicateEventID = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testLockContentionFailsAndThrownBodyReleasesLock() throws {
        let repository = try TravelRepository(root: temporaryDirectory())
        try repository.withExclusiveLock {
            XCTAssertThrowsError(try repository.withExclusiveLock {}) { error in
                guard case RepositoryError.lockUnavailable = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
            XCTAssertThrowsError(try repository.events()) { error in
                guard case RepositoryError.lockUnavailable = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }

        XCTAssertThrowsError(try repository.withExclusiveLock { throw ProbeError.expected })
        XCTAssertNoThrow(try repository.withExclusiveLock {})
    }

    func testClaimDueReadsSnapshotAndPreviousEvent() throws {
        let repository = try TravelRepository(root: temporaryDirectory())
        let event = TripEvent.fixture()
        let snapshot = TripSnapshot.fixture(
            stateVersion: 1,
            tripID: event.tripID,
            lastEventID: event.id,
            nextActionAt: Date(timeIntervalSince1970: 600)
        )
        try repository.publish(event: event, next: snapshot)

        let claim = try repository.claimDue(mode: .daily, now: Date(timeIntervalSince1970: 600))

        XCTAssertTrue(claim.due)
        XCTAssertEqual(claim.snapshot, snapshot)
        XCTAssertEqual(claim.previousEvent, event)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TravelRepositoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func writeJournal(_ events: [TripEvent], to repository: TravelRepository) throws {
        let encoder = JSONEncoder.travelCat
        encoder.outputFormatting = [.sortedKeys]
        let data = try events.reduce(into: Data()) { result, event in
            result.append(try encoder.encode(event))
            result.append(0x0A)
        }
        try data.write(to: repository.root.appendingPathComponent("journal/events.jsonl"))
    }

    private func assertContinuityConflict<T>(
        _ expression: @autoclosure () throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            guard case RepositoryError.continuityConflict = error else {
                return XCTFail("Unexpected error: \(error)", file: file, line: line)
            }
        }
    }
}

private enum ProbeError: Error {
    case expected
}
