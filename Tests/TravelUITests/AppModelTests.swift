import Foundation
import XCTest
import TravelCore
@testable import TravelUI

@MainActor
final class AppModelTests: XCTestCase {
    private let tripID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let firstID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let secondID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    func testCharacterProfileDefaultsAndChangesEvenWhenSnapshotVersionDoesNot() {
        let snapshot = makeSnapshot(phase: .resting)
        let custom = CharacterProfile(
            id: "custom", displayName: "小橘", description: "", spriteVersionNumber: 2,
            sprite: .dataRootRelative("characters/custom/revision/assets/pet.webp"),
            referenceImages: [],
            source: .importedManifest("characters/custom/revision/source-manifest.json")
        )
        let model = AppModel(snapshot: snapshot, defaults: isolatedDefaults(), supplies: [])

        XCTAssertEqual(model.characterProfile, .defaultBlackCat)
        model.apply(next: snapshot, events: [], characterProfile: custom)
        XCTAssertEqual(model.characterProfile, custom)

        model.apply(next: snapshot, events: [])
        XCTAssertEqual(model.characterProfile, custom)
    }

    func testHistoryReplacementCanCarryRepositoryEffectiveCharacter() {
        let custom = CharacterProfile(
            id: "custom", displayName: "小橘", description: "", spriteVersionNumber: 2,
            sprite: .dataRootRelative("characters/custom/revision/assets/pet.webp"),
            referenceImages: [],
            source: .importedManifest("characters/custom/revision/source-manifest.json")
        )
        let model = AppModel(snapshot: makeSnapshot(phase: .resting), defaults: isolatedDefaults(), supplies: [])

        model.replaceAfterHistoryClear(next: makeSnapshot(version: 2, phase: .resting), events: [], characterProfile: custom)

        XCTAssertEqual(model.characterProfile, custom)
    }

    func testRestingInteractionFollowsStatusPostcardAlbumHierarchy() throws {
        let event = makeEvent(id: firstID, seconds: 10, status: .ready)
        let model = AppModel(snapshot: makeSnapshot(phase: .resting), events: [event], defaults: isolatedDefaults(), supplies: [])

        XCTAssertEqual(model.presentation, .pet)
        model.handle(.status)
        XCTAssertEqual(model.presentation, .status)
        model.handle(.postcard(firstID))
        XCTAssertEqual(model.presentation, .postcard(firstID))
        XCTAssertEqual(model.readPostcardIDs, [firstID])
        model.handle(.album(tripID))
        XCTAssertEqual(model.presentation, .album(tripID))
        model.handle(.postcard(firstID))
        XCTAssertEqual(model.presentation, .postcard(firstID))
        model.close()
        XCTAssertEqual(model.presentation, .album(tripID))
    }

    func testCrossTripAlbumOpensOlderMeaningfulPostcardAndReturnsToOriginalAlbum() {
        let olderTripID = UUID()
        let olderPostcard = makeEvent(
            id: firstID,
            tripID: olderTripID,
            seconds: 10,
            status: .ready
        )
        let latestPostcard = makeEvent(id: secondID, seconds: 20, status: .ready)
        let model = AppModel(
            snapshot: makeSnapshot(phase: .resting),
            events: [olderPostcard, latestPostcard],
            defaults: isolatedDefaults(),
            supplies: []
        )
        model.handle(.status)
        model.openLatestAlbumFromStatus()
        XCTAssertEqual(model.presentation, .album(tripID))

        model.handle(.postcard(firstID))

        XCTAssertEqual(model.presentation, .postcard(firstID))
        XCTAssertEqual(model.readPostcardIDs, [firstID])
        model.close()
        XCTAssertEqual(model.presentation, .album(tripID))
    }

    func testCrossTripAlbumRejectsTimelineOnlyAndRejectedEvents() {
        let otherTripID = UUID()
        let timelineOnly = makeEvent(
            id: firstID,
            tripID: otherTripID,
            seconds: 10,
            status: .none
        )
        let rejected = makeEvent(
            id: UUID(),
            tripID: otherTripID,
            seconds: 20,
            status: .rejected
        )
        let latestPostcard = makeEvent(id: secondID, seconds: 30, status: .ready)
        let model = AppModel(
            snapshot: makeSnapshot(phase: .resting),
            events: [timelineOnly, rejected, latestPostcard],
            defaults: isolatedDefaults(),
            supplies: []
        )
        model.handle(.status)
        model.openLatestAlbumFromStatus()

        model.handle(.postcard(firstID))
        model.handle(.postcard(rejected.id))

        XCTAssertEqual(model.presentation, .album(tripID))
        XCTAssertTrue(model.readPostcardIDs.isEmpty)
    }

    func testAwayInteractionFollowsSameHierarchyAndCannotJumpToAlbum() {
        let event = makeEvent(id: firstID, seconds: 10, status: .pendingImage)
        let model = AppModel(snapshot: makeSnapshot(phase: .transit), events: [event], defaults: isolatedDefaults(), supplies: [])

        XCTAssertEqual(model.presentation, .awayTag)
        model.handle(.album(tripID))
        XCTAssertEqual(model.presentation, .awayTag)
        model.handle(.status)
        XCTAssertEqual(model.presentation, .status)
        model.handle(.album(tripID))
        XCTAssertEqual(model.presentation, .status)
        model.openNextPostcardOrBase()
        XCTAssertEqual(model.presentation, .postcard(firstID))
        model.openAlbumForCurrentPostcard()
        XCTAssertEqual(model.presentation, .album(tripID))
    }

    func testUnreadPostcardsAreMeaningfulDeterministicAndPersistedWhenOpened() throws {
        let suite = "AppModelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let rejected = makeEvent(id: UUID(), seconds: 0, status: .rejected)
        let laterInJournal = makeEvent(id: secondID, seconds: 10, status: .imageUnavailable)
        let earlierInJournal = makeEvent(id: firstID, seconds: 10, status: .ready)
        let none = makeEvent(id: UUID(), seconds: 20, status: .none)
        let model = AppModel(
            snapshot: makeSnapshot(phase: .resting),
            events: [rejected, laterInJournal, earlierInJournal, none],
            defaults: defaults,
            supplies: []
        )

        XCTAssertEqual(model.unreadPostcardIDs, [secondID, firstID])
        model.handle(.status)
        model.openNextPostcardOrBase()
        XCTAssertEqual(model.presentation, .postcard(secondID))
        XCTAssertEqual(model.unreadPostcardIDs, [firstID])

        let reloaded = AppModel(
            snapshot: makeSnapshot(phase: .resting),
            events: [laterInJournal, earlierInJournal],
            defaults: defaults,
            supplies: []
        )
        XCTAssertEqual(reloaded.unreadPostcardIDs, [firstID])
    }

    func testStatusCannotSkipAheadToALaterUnreadPostcard() {
        let first = makeEvent(id: firstID, seconds: 10, status: .ready)
        let second = makeEvent(id: secondID, seconds: 20, status: .ready)
        let model = AppModel(
            snapshot: makeSnapshot(phase: .resting),
            events: [first, second],
            defaults: isolatedDefaults(),
            supplies: []
        )

        model.handle(.status)
        model.handle(.postcard(secondID))

        XCTAssertEqual(model.presentation, .status)
        XCTAssertTrue(model.readPostcardIDs.isEmpty)
    }

    func testApplyIgnoresStaleVersionsAndRebasesOnNewerState() {
        let event = makeEvent(id: firstID, seconds: 10, status: .ready)
        let model = AppModel(snapshot: makeSnapshot(version: 2, phase: .resting), events: [event], defaults: isolatedDefaults(), supplies: [])
        model.handle(.status)

        model.apply(next: makeSnapshot(version: 2, phase: .transit), events: [])
        XCTAssertEqual(model.snapshot.phase, .resting)
        XCTAssertEqual(model.presentation, .status)

        model.apply(next: makeSnapshot(version: 3, phase: .transit), events: [event])
        XCTAssertEqual(model.snapshot.phase, .transit)
        XCTAssertEqual(model.presentation, .status)
        XCTAssertEqual(model.unreadPostcardIDs, [firstID])
    }

    func testEqualVersionEventRefreshUpdatesImageWithoutRegressingSnapshot() {
        let pending = makeEvent(id: firstID, seconds: 10, status: .pendingImage)
        var ready = pending
        ready.postcardStatus = .ready
        ready.postcardRelativePath = "card.png"
        let model = AppModel(snapshot: makeSnapshot(version: 2, phase: .exploring), events: [pending], defaults: isolatedDefaults(), supplies: [])

        model.apply(next: makeSnapshot(version: 2, phase: .resting), events: [ready])

        XCTAssertEqual(model.snapshot.phase, .exploring)
        XCTAssertEqual(model.events, [ready])
        XCTAssertEqual(model.unreadPostcardIDs, [firstID])
    }

    func testNewerStatePreservesValidOverlayRoutesAndOnlyRebasesBaseRoute() {
        let event = makeEvent(id: firstID, seconds: 10, status: .ready)
        let model = AppModel(snapshot: makeSnapshot(phase: .resting), events: [event], defaults: isolatedDefaults(), supplies: [])
        model.handle(.status)
        model.apply(next: makeSnapshot(version: 2, phase: .transit), events: [event])
        XCTAssertEqual(model.presentation, .status)
        model.handle(.postcard(firstID))
        model.apply(next: makeSnapshot(version: 3, phase: .exploring), events: [event])
        XCTAssertEqual(model.presentation, .postcard(firstID))
        model.handle(.album(tripID))
        model.apply(next: makeSnapshot(version: 4, phase: .returning), events: [event])
        XCTAssertEqual(model.presentation, .album(tripID))

        model.close()
        model.close()
        XCTAssertEqual(model.presentation, .awayTag)
    }

    func testInvalidActivePostcardFallsBackToStatusAndAwayClosesSupplies() {
        let event = makeEvent(id: firstID, seconds: 10, status: .ready)
        let model = AppModel(snapshot: makeSnapshot(phase: .resting), events: [event], defaults: isolatedDefaults(), supplies: [])
        model.handle(.status)
        model.handle(.postcard(firstID))
        var rejected = event
        rejected.postcardStatus = .rejected
        model.apply(next: makeSnapshot(version: 2, phase: .resting), events: [rejected])
        XCTAssertEqual(model.presentation, .status)

        model.close()
        model.handle(.supplies)
        model.apply(next: makeSnapshot(version: 3, phase: .transit), events: [rejected])
        XCTAssertEqual(model.presentation, .awayTag)
    }

    func testSupplyPersistenceCallbackControlsPublishedMutation() throws {
        enum Failure: Error { case denied }
        let supplies = [Supply(id: "camera", name: "小相机", influence: "风景")]
        var calls: [String?] = []
        let initial = makeSnapshot(phase: .resting)
        let model = AppModel(snapshot: initial, defaults: isolatedDefaults(), supplies: supplies) { id in
            calls.append(id)
            if id == nil { throw Failure.denied }
            var next = initial
            next.carriedItemID = id
            return next
        }

        try model.selectSupply("camera")
        XCTAssertEqual(calls, ["camera"])
        XCTAssertEqual(model.snapshot.carriedItemID, "camera")
        XCTAssertThrowsError(try model.selectSupply(nil))
        XCTAssertEqual(model.snapshot.carriedItemID, "camera")
    }

    func testStatusCanOpenLatestReadTripAlbumButBaseCannot() {
        let olderTrip = UUID()
        let older = makeEvent(id: firstID, tripID: olderTrip, seconds: 10, status: .ready)
        let latest = makeEvent(id: secondID, seconds: 20, status: .ready)
        let model = AppModel(snapshot: makeSnapshot(phase: .resting), events: [older, latest], defaults: isolatedDefaults(), supplies: [])
        model.handle(.album(tripID))
        XCTAssertEqual(model.presentation, .pet)
        model.handle(.status)
        model.openLatestAlbumFromStatus()
        XCTAssertEqual(model.presentation, .album(tripID))

        let empty = AppModel(snapshot: makeSnapshot(phase: .resting), events: [], defaults: isolatedDefaults(), supplies: [])
        empty.handle(.status)
        empty.openLatestAlbumFromStatus()
        XCTAssertEqual(empty.presentation, .status)

        let timelineOnly = makeEvent(id: UUID(), seconds: 30, status: .none)
        let timelineModel = AppModel(
            snapshot: makeSnapshot(phase: .resting),
            events: [timelineOnly],
            defaults: isolatedDefaults(),
            supplies: []
        )
        timelineModel.handle(.status)
        timelineModel.openLatestAlbumFromStatus()
        XCTAssertEqual(timelineModel.presentation, .status)
    }

    func testMenuStatusRouteBypassesPetOnlyNavigationRestrictions() {
        let event = makeEvent(id: firstID, seconds: 10, status: .ready)
        let model = AppModel(
            snapshot: makeSnapshot(phase: .resting),
            events: [event],
            defaults: isolatedDefaults(),
            supplies: []
        )
        model.handle(.status)
        model.handle(.postcard(firstID))

        model.openStatusFromMenu()

        XCTAssertEqual(model.presentation, .status)
    }

    func testMenuPostcardRouteOpensNewestMeaningfulJournalEntryAndReturnsToStatus() {
        let older = makeEvent(id: UUID(), seconds: 5, status: .ready)
        let earlierAtTie = makeEvent(id: firstID, seconds: 10, status: .pendingImage)
        let newestAtTie = makeEvent(id: secondID, seconds: 10, status: .imageUnavailable)
        let ignoredNewer = makeEvent(id: UUID(), seconds: 20, status: .none)
        let ignoredRejected = makeEvent(id: UUID(), seconds: 30, status: .rejected)
        let model = AppModel(
            snapshot: makeSnapshot(phase: .transit),
            events: [older, earlierAtTie, newestAtTie, ignoredNewer, ignoredRejected],
            defaults: isolatedDefaults(),
            supplies: []
        )

        model.openLatestPostcardFromMenu()

        XCTAssertEqual(model.presentation, .postcard(secondID))
        XCTAssertTrue(model.readPostcardIDs.contains(secondID))
        model.close()
        XCTAssertEqual(model.presentation, .status)
    }

    func testMenuAlbumRouteLeavesTimelineOnlyAndEmptyModelsOnStatus() {
        let timelineOnly = makeEvent(id: secondID, seconds: 20, status: .none)
        let timelineModel = AppModel(
            snapshot: makeSnapshot(phase: .resting),
            events: [timelineOnly],
            defaults: isolatedDefaults(),
            supplies: []
        )

        timelineModel.openLatestAlbumFromMenu()

        XCTAssertEqual(timelineModel.presentation, .status)

        let empty = AppModel(
            snapshot: makeSnapshot(phase: .transit),
            events: [],
            defaults: isolatedDefaults(),
            supplies: []
        )
        empty.openLatestPostcardFromMenu()
        XCTAssertEqual(empty.presentation, .status)
        empty.openLatestAlbumFromMenu()
        XCTAssertEqual(empty.presentation, .status)
    }

    func testMenuAlbumRouteIgnoresNewerTimelineTripAndOpensOlderRealPostcardTrip() {
        let postcardTripID = UUID()
        let olderPostcard = makeEvent(
            id: firstID,
            tripID: postcardTripID,
            seconds: 10,
            status: .ready
        )
        let newerTimelineOnly = makeEvent(id: secondID, seconds: 20, status: .none)
        let model = AppModel(
            snapshot: makeSnapshot(phase: .resting),
            events: [olderPostcard, newerTimelineOnly],
            defaults: isolatedDefaults(),
            supplies: []
        )

        model.openLatestAlbumFromMenu()

        XCTAssertEqual(model.presentation, .album(postcardTripID))
    }

    func testMenuAlbumRouteFiltersOutFuturePostcards() {
        var now = Date(timeIntervalSince1970: 20)
        let pastPostcard = makeEvent(
            id: firstID,
            tripID: tripID,
            seconds: 10,
            status: .ready
        )
        let futurePostcard = makeEvent(
            id: secondID,
            tripID: tripID,
            seconds: 30,
            status: .ready
        )
        let model = AppModel(
            snapshot: makeSnapshot(phase: .resting),
            events: [pastPostcard, futurePostcard],
            defaults: isolatedDefaults(),
            supplies: [],
            clock: { now }
        )

        model.openLatestAlbumFromMenu()

        XCTAssertEqual(model.presentation, .album(tripID))
        model.handle(.postcard(secondID))
        XCTAssertEqual(model.presentation, .album(tripID))

        now = Date(timeIntervalSince1970: 40)
        model.apply(next: model.snapshot, events: [pastPostcard, futurePostcard])
        XCTAssertTrue(model.unreadPostcardIDs.contains(secondID))
    }

    func testFuturePostcardsStayOutOfUnreadLatestAndPromptRoutesUntilTheirTimeArrives() {
        var now = Date(timeIntervalSince1970: 100)
        let past = makeEvent(id: firstID, seconds: 90, status: .ready)
        let future = makeEvent(id: secondID, seconds: 110, status: .ready)
        let model = AppModel(
            snapshot: makeSnapshot(phase: .resting),
            events: [past, future],
            defaults: isolatedDefaults(),
            supplies: [],
            clock: { now }
        )

        XCTAssertEqual(model.unreadPostcardIDs, [firstID])
        model.openLatestPostcardFromMenu()
        XCTAssertEqual(model.presentation, .postcard(firstID))
        XCTAssertFalse(model.openPostcardFromPrompt(eventID: secondID, tripID: tripID))

        now = Date(timeIntervalSince1970: 120)
        model.apply(next: model.snapshot, events: [past, future])
        XCTAssertTrue(model.unreadPostcardIDs.contains(secondID))
    }

    func testTripAlbumViewOrderedEventsFiltersByTripAndTime() {
        let now = Date(timeIntervalSince1970: 20)
        let otherTripID = UUID()
        let first = makeEvent(id: firstID, tripID: tripID, seconds: 10, status: .ready)
        let future = makeEvent(id: secondID, tripID: tripID, seconds: 30, status: .ready)
        let otherTrip = makeEvent(id: UUID(), tripID: otherTripID, seconds: 5, status: .ready)
        let timelineOnly = makeEvent(id: UUID(), tripID: tripID, seconds: 8, status: .none)

        let ordered = TripAlbumView.orderedEvents(
            tripID: tripID,
            events: [otherTrip, future, first, timelineOnly],
            now: now
        )

        XCTAssertEqual(ordered.map(\.id), [firstID])
    }

    func testPromptPostcardOpensExactOlderReadyEventInsteadOfNewerPostcard() {
        let olderTripID = UUID()
        let olderPostcard = makeEvent(
            id: firstID,
            tripID: olderTripID,
            seconds: 10,
            status: .ready
        )
        let newerPostcard = makeEvent(id: secondID, seconds: 20, status: .ready)
        let model = AppModel(
            snapshot: makeSnapshot(phase: .resting),
            events: [olderPostcard, newerPostcard],
            defaults: isolatedDefaults(),
            supplies: []
        )
        model.openLatestAlbumFromMenu()
        model.handle(.postcard(secondID))

        XCTAssertTrue(model.openPostcardFromPrompt(eventID: firstID, tripID: olderTripID))
        XCTAssertEqual(model.presentation, .postcard(firstID))
        XCTAssertEqual(model.readPostcardIDs, [secondID, firstID])
        XCTAssertEqual(model.unreadPostcardIDs, [])
        model.close()
        XCTAssertEqual(model.presentation, .status)
    }

    func testPromptPostcardRejectsDuplicateEventIDsWithoutMarkingEitherRead() {
        let requestedTripID = UUID()
        let otherTripID = UUID()
        let cases: [(name: String, duplicates: [TripEvent])] = [
            (
                "same trip",
                [
                    makeEvent(id: firstID, tripID: requestedTripID, seconds: 10, status: .ready),
                    makeEvent(id: firstID, tripID: requestedTripID, seconds: 11, status: .ready),
                ]
            ),
            (
                "different trips",
                [
                    makeEvent(id: firstID, tripID: requestedTripID, seconds: 10, status: .ready),
                    makeEvent(id: firstID, tripID: otherTripID, seconds: 11, status: .ready),
                ]
            ),
            (
                "mixed statuses",
                [
                    makeEvent(id: firstID, tripID: requestedTripID, seconds: 10, status: .ready),
                    makeEvent(id: firstID, tripID: requestedTripID, seconds: 11, status: .rejected),
                ]
            ),
        ]

        for testCase in cases {
            let newerPostcard = makeEvent(id: secondID, seconds: 20, status: .ready)
            let model = AppModel(
                snapshot: makeSnapshot(phase: .resting),
                events: testCase.duplicates + [newerPostcard],
                defaults: isolatedDefaults(),
                supplies: []
            )
            model.openLatestAlbumFromMenu()

            XCTAssertFalse(
                model.openPostcardFromPrompt(eventID: firstID, tripID: requestedTripID),
                testCase.name
            )
            XCTAssertEqual(model.presentation, .status, testCase.name)
            XCTAssertTrue(model.readPostcardIDs.isEmpty, testCase.name)
        }
    }

    func testPromptPostcardRejectsInvalidTargetsWithoutFallingBackToNewerPostcard() {
        let actualTripID = UUID()
        let wrongTripID = UUID()
        let cases: [(name: String, event: TripEvent?, requestedTripID: UUID)] = [
            ("pending", makeEvent(id: firstID, tripID: actualTripID, seconds: 10, status: .pendingImage), actualTripID),
            ("unavailable", makeEvent(id: firstID, tripID: actualTripID, seconds: 10, status: .imageUnavailable), actualTripID),
            ("rejected", makeEvent(id: firstID, tripID: actualTripID, seconds: 10, status: .rejected), actualTripID),
            ("timeline", makeEvent(id: firstID, tripID: actualTripID, seconds: 10, status: .none), actualTripID),
            ("missing", nil, actualTripID),
            ("trip mismatch", makeEvent(id: firstID, tripID: actualTripID, seconds: 10, status: .ready), wrongTripID),
        ]

        for testCase in cases {
            let newerPostcard = makeEvent(id: secondID, seconds: 20, status: .ready)
            let model = AppModel(
                snapshot: makeSnapshot(phase: .resting),
                events: [testCase.event, newerPostcard].compactMap { $0 },
                defaults: isolatedDefaults(),
                supplies: []
            )
            model.openLatestAlbumFromMenu()

            XCTAssertFalse(
                model.openPostcardFromPrompt(eventID: firstID, tripID: testCase.requestedTripID),
                testCase.name
            )
            XCTAssertEqual(model.presentation, .status, testCase.name)
            XCTAssertTrue(model.readPostcardIDs.isEmpty, testCase.name)
            XCTAssertTrue(model.unreadPostcardIDs.contains(secondID), testCase.name)
        }
    }

    func testPromptAlbumOpensExactOlderMeaningfulTripInsteadOfNewerTrip() {
        for status in [PostcardStatus.ready, .imageUnavailable] {
            let olderTripID = UUID()
            let olderPostcard = makeEvent(
                id: firstID,
                tripID: olderTripID,
                seconds: 10,
                status: status
            )
            let newerPostcard = makeEvent(id: secondID, seconds: 20, status: .ready)
            let model = AppModel(
                snapshot: makeSnapshot(phase: .resting),
                events: [olderPostcard, newerPostcard],
                defaults: isolatedDefaults(),
                supplies: []
            )
            model.openLatestPostcardFromMenu()

            XCTAssertTrue(model.openAlbumFromPrompt(tripID: olderTripID), "\(status)")
            XCTAssertEqual(model.presentation, .album(olderTripID), "\(status)")
        }
    }

    func testPromptAlbumRejectsInvalidTripsWithoutFallingBackToNewerTrip() {
        let cases: [(name: String, status: PostcardStatus?)] = [
            ("pending", .pendingImage),
            ("rejected", .rejected),
            ("timeline", PostcardStatus.none),
            ("missing", nil),
        ]

        for testCase in cases {
            let requestedTripID = UUID()
            let invalidEvent = testCase.status.map {
                makeEvent(id: firstID, tripID: requestedTripID, seconds: 10, status: $0)
            }
            let newerPostcard = makeEvent(id: secondID, seconds: 20, status: .ready)
            let model = AppModel(
                snapshot: makeSnapshot(phase: .resting),
                events: [invalidEvent, newerPostcard].compactMap { $0 },
                defaults: isolatedDefaults(),
                supplies: []
            )
            model.openLatestPostcardFromMenu()

            XCTAssertFalse(model.openAlbumFromPrompt(tripID: requestedTripID), testCase.name)
            XCTAssertEqual(model.presentation, .status, testCase.name)
        }
    }

    func testReadArchiveStateIsScopedByDataRoot() {
        let defaults = isolatedDefaults()
        let event = makeEvent(id: firstID, seconds: 10, status: .ready)
        let first = AppModel(snapshot: makeSnapshot(phase: .resting), events: [event], dataRoot: URL(fileURLWithPath: "/tmp/a"), defaults: defaults, supplies: [])
        first.handle(.status)
        first.openNextPostcardOrBase()
        let second = AppModel(snapshot: makeSnapshot(phase: .resting), events: [event], dataRoot: URL(fileURLWithPath: "/tmp/b"), defaults: defaults, supplies: [])
        XCTAssertEqual(second.unreadPostcardIDs, [firstID])
    }

    func testReadArchiveScopeCanonicalizesSymlinkAliases() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppModelScope-\(UUID().uuidString)", isDirectory: true)
        let alias = root.deletingLastPathComponent().appendingPathComponent("\(root.lastPathComponent)-alias")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        defer {
            try? FileManager.default.removeItem(at: alias)
            try? FileManager.default.removeItem(at: root)
        }

        XCTAssertEqual(
            AppModel.readDefaultsScopeKey(dataRoot: root),
            AppModel.readDefaultsScopeKey(dataRoot: alias)
        )
    }

    func testSupplySelectionReselectionClearAndAwayErrors() throws {
        let supplies = [
            Supply(id: "camera", name: "小相机", influence: "风景事件和自拍"),
            Supply(id: "blanket", name: "小毯子", influence: "安静、露营或夜晚场景"),
        ]
        let model = AppModel(snapshot: makeSnapshot(phase: .resting), events: [], defaults: isolatedDefaults(), supplies: supplies)

        try model.selectSupply("camera")
        XCTAssertEqual(model.snapshot.carriedItemID, "camera")
        try model.selectSupply("blanket")
        XCTAssertEqual(model.snapshot.carriedItemID, "blanket")
        try model.selectSupply(nil)
        XCTAssertNil(model.snapshot.carriedItemID)
        XCTAssertThrowsError(try model.selectSupply("unknown")) { error in
            XCTAssertEqual(error as? AppModelError, .unknownSupply("unknown"))
        }

        model.apply(next: makeSnapshot(version: 2, phase: .exploring), events: [])
        XCTAssertThrowsError(try model.selectSupply("camera")) { error in
            XCTAssertEqual(error as? AppModelError, .catIsAway)
        }
    }

    private func makeSnapshot(version: Int = 1, phase: TravelPhase) -> TripSnapshot {
        TripSnapshot(
            stateVersion: version,
            tripID: tripID,
            phase: phase,
            nextActionAt: Date(timeIntervalSince1970: 100),
            lastUpdatedAt: Date(timeIntervalSince1970: 50),
            usedItemIDs: [], visitedPlaces: [],
            mood: Mood(level: 2, label: "期待", quote: "出发吧。")
        )
    }

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "AppModelTests-isolated-\(UUID().uuidString)") ?? .standard
    }

    private func makeEvent(id: UUID, tripID: UUID? = nil, seconds: TimeInterval, status: PostcardStatus) -> TripEvent {
        TripEvent(
            id: id, tripID: tripID ?? self.tripID, previousEventID: nil,
            occurredAt: Date(timeIntervalSince1970: seconds), phase: .exploring,
            location: Location(country: "中国", city: "杭州", place: "西湖"),
            transport: nil, summary: "看见了风吹过湖面。",
            mood: Mood(level: 3, label: "开心", quote: "湖面亮晶晶。"),
            continuityReferences: [], openHook: nil, consumedItemID: nil,
            postcardStatus: status,
            postcardRelativePath: status == .ready ? "postcards/\(id).png" : nil
        )
    }
}
