import Foundation
import UserNotifications
import XCTest
import TravelCore
@testable import TravelStorage
@testable import TravelCatApp

@MainActor
final class PetTravelPromptServiceTests: XCTestCase {
    private let noon = Date(timeIntervalSince1970: 1_787_122_800)

    func testBubbleSuccessCommitsDeliveryAndRoutesExactPostcard() throws {
        let harness = try makeHarness()
        let IDs = try prepareReadyPostcard(in: harness)
        var shown: [PetTravelPromptDelivery] = []
        var routes: [PetTravelRoute] = []
        var tap: (() -> Void)?
        let service = PetTravelPromptService(
            coordinator: harness.coordinator,
            showBubble: { delivery, onTap, _ in
                shown.append(delivery)
                tap = onTap
                return true
            },
            postNotification: { _ in XCTFail("must not fall back"); return false },
            route: { routes.append($0) }
        )

        service.ingestCurrent(settings: .init(), now: noon)

        XCTAssertEqual(shown.count, 1)
        XCTAssertEqual(try harness.coordinator.pendingCount, 0)
        tap?()
        XCTAssertEqual(routes, [.postcard(eventID: IDs.eventID, tripID: IDs.tripID)])
    }

    func testFailedChannelsPersistAcrossRelaunchThenNotificationSuccessCommits() async throws {
        let harness = try makeHarness()
        let departure = try publish(phase: .preparing, in: harness.repository)
        let firstAttempt = expectation(description: "first notification attempt")
        let firstService = PetTravelPromptService(
            coordinator: harness.coordinator,
            showBubble: { _, _, _ in false },
            postNotification: { _ in firstAttempt.fulfill(); return false },
            route: { _ in }
        )
        firstService.ingestCurrent(settings: .init(), now: noon)
        await fulfillment(of: [firstAttempt], timeout: 2)
        XCTAssertEqual(try harness.coordinator.pendingCount, 1)

        let relaunchedCoordinator = try PetTravelPromptCoordinator(repository: harness.repository)
        let secondAttempt = expectation(description: "relaunch notification attempt")
        var notified: [PetTravelPromptDelivery] = []
        let relaunched = PetTravelPromptService(
            coordinator: relaunchedCoordinator,
            showBubble: { _, _, _ in false },
            postNotification: {
                notified.append($0)
                secondAttempt.fulfill()
                return true
            },
            route: { _ in }
        )
        relaunched.retry(settings: .init(), now: noon)
        await fulfillment(of: [secondAttempt], timeout: 2)

        XCTAssertEqual(notified, [.prompt(.departed(
            eventID: departure.id,
            tripID: departure.tripID,
            location: departure.location,
            summary: departure.summary
        ))])
        XCTAssertEqual(try relaunchedCoordinator.pendingCount, 0)
    }

    func testRepositoryContentionStaysPendingAndExplicitRetryReingests() throws {
        let harness = try makeHarness()
        let departure = try publish(phase: .preparing, in: harness.repository)
        var shown: [PetTravelPromptDelivery] = []
        let service = PetTravelPromptService(
            coordinator: harness.coordinator,
            showBubble: { delivery, _, _ in
                shown.append(delivery)
                return true
            },
            postNotification: { _ in XCTFail("must not fall back"); return false },
            route: { _ in }
        )

        try harness.repository.withExclusiveLock {
            service.ingestCurrent(settings: .init(), now: noon)
            XCTAssertTrue(service.hasPendingOrStorageError)
            XCTAssertEqual(
                service.storageError,
                .repositoryUnavailable("repository lock is unavailable")
            )
            XCTAssertTrue(shown.isEmpty)
            XCTAssertEqual(try harness.coordinator.pendingCount, 0)

            service.retry(settings: .init(), now: noon)
            XCTAssertEqual(
                service.storageError,
                .repositoryUnavailable("repository lock is unavailable")
            )
            XCTAssertTrue(shown.isEmpty)
        }

        service.retry(settings: .init(), now: noon)

        XCTAssertEqual(shown, [.prompt(.departed(
            eventID: departure.id,
            tripID: departure.tripID,
            location: departure.location,
            summary: departure.summary
        ))])
        XCTAssertNil(service.storageError)
        XCTAssertEqual(try harness.coordinator.pendingCount, 0)
    }

    func testRepositoryContentionDoesNotDropAnExistingDurablePrompt() throws {
        let harness = try makeHarness()
        let departure = try publish(phase: .preparing, in: harness.repository)
        try harness.coordinator.ingestCurrent(policy: openPolicy, hour: 12)
        let returned = try publish(
            phase: .resting,
            tripID: departure.tripID,
            in: harness.repository
        )
        var shown: [PetTravelPromptDelivery] = []
        var replacements: [() -> Void] = []
        let service = PetTravelPromptService(
            coordinator: harness.coordinator,
            showBubble: { delivery, _, onReplacement in
                shown.append(delivery)
                replacements.append(onReplacement)
                return true
            },
            postNotification: { _ in XCTFail("must not fall back"); return false },
            route: { _ in },
            clock: { self.noon }
        )

        try harness.repository.withExclusiveLock {
            service.ingestCurrent(settings: .init(), now: noon)
            XCTAssertEqual(try harness.coordinator.pendingCount, 1)
            XCTAssertTrue(shown.isEmpty)
        }

        service.retry(settings: .init(), now: noon)
        XCTAssertEqual(shown.first, .prompt(.departed(
            eventID: departure.id,
            tripID: departure.tripID,
            location: departure.location,
            summary: departure.summary
        )))
        let replaceDeparture = try XCTUnwrap(replacements.first)
        replaceDeparture()
        XCTAssertEqual(shown.last, .prompt(.returned(
            eventID: returned.id,
            tripID: returned.tripID,
            mood: returned.mood.label
        )))
        XCTAssertNil(service.storageError)
        XCTAssertEqual(try harness.coordinator.pendingCount, 0)
    }

    func testMalformedRepositoryFailsClosedAsStorageError() throws {
        let harness = try makeHarness()
        try Data("not-json\n".utf8).write(
            to: harness.repository.root.appendingPathComponent("journal/events.jsonl")
        )
        var deliveryAttempts = 0
        let service = PetTravelPromptService(
            coordinator: harness.coordinator,
            showBubble: { _, _, _ in deliveryAttempts += 1; return true },
            postNotification: { _ in deliveryAttempts += 1; return true },
            route: { _ in }
        )

        service.ingestCurrent(settings: .init(), now: noon)

        guard case let .repositoryInvalid(description) = service.storageError else {
            return XCTFail("expected repositoryInvalid, got \(String(describing: service.storageError))")
        }
        XCTAssertTrue(description.contains("malformed journal record at line 1"))
        XCTAssertTrue(service.hasPendingOrStorageError)
        XCTAssertEqual(deliveryAttempts, 0)
    }

    func testStrictSerialOrderKeepsOnlyOneActiveDisplayUntilReplacementSignal() throws {
        let harness = try makeHarness()
        let departed = try publish(phase: .preparing, in: harness.repository)
        let returned = try publish(phase: .resting, tripID: departed.tripID, in: harness.repository)
        var shown: [PetTravelPromptDelivery] = []
        var replacements: [() -> Void] = []
        let service = PetTravelPromptService(
            coordinator: harness.coordinator,
            showBubble: { delivery, _, onReplacement in
                shown.append(delivery)
                replacements.append(onReplacement)
                return true
            },
            postNotification: { _ in XCTFail("must not fall back"); return false },
            route: { _ in },
            clock: { self.noon }
        )

        service.ingestCurrent(settings: .init(), now: noon)
        service.retry(settings: .init(), now: noon)
        XCTAssertEqual(shown, [.prompt(.departed(
            eventID: departed.id,
            tripID: departed.tripID,
            location: departed.location,
            summary: departed.summary
        ))])
        XCTAssertEqual(try harness.coordinator.pendingCount, 1)

        replacements[0]()
        XCTAssertEqual(shown, [
            .prompt(.departed(
                eventID: departed.id,
                tripID: departed.tripID,
                location: departed.location,
                summary: departed.summary
            )),
            .prompt(.returned(eventID: returned.id, tripID: returned.tripID, mood: returned.mood.label)),
        ])
        XCTAssertEqual(replacements.count, 2)
        XCTAssertEqual(try harness.coordinator.pendingCount, 0)
    }

    func testQuietEndTimerRetriesWithoutRepositoryObservationAndRoutesSummaryToStatus() throws {
        let harness = try makeHarness()
        let departure = try publish(phase: .preparing, in: harness.repository)
        let expectedPromptID = PetTravelPrompt.departed(
            eventID: departure.id,
            tripID: departure.tripID,
            location: departure.location,
            summary: departure.summary
        ).identifier
        let scheduler = ManualPromptScheduler()
        var shown: [PetTravelPromptDelivery] = []
        var routes: [PetTravelRoute] = []
        var tap: (() -> Void)?
        let journalURL = harness.repository.root.appendingPathComponent("journal/events.jsonl")
        let snapshotURL = harness.repository.snapshotURL
        let beforeJournal = try Data(contentsOf: journalURL)
        let beforeSnapshot = try Data(contentsOf: snapshotURL)
        let calendar = utcCalendar()
        var currentNow = date(hour: 23, calendar: calendar)
        let service = PetTravelPromptService(
            coordinator: harness.coordinator,
            showBubble: { delivery, onTap, _ in
                shown.append(delivery)
                tap = onTap
                return true
            },
            postNotification: { _ in XCTFail("must not fall back"); return false },
            route: { routes.append($0) },
            calendar: calendar,
            scheduler: scheduler,
            clock: { currentNow }
        )

        service.ingestCurrent(
            settings: .init(quietStart: 22, quietEnd: 8),
            now: currentNow
        )
        XCTAssertTrue(shown.isEmpty)
        XCTAssertEqual(scheduler.activeCount, 1)

        currentNow = date(day: 24, hour: 8, calendar: calendar)
        scheduler.fireNext()
        XCTAssertEqual(shown, [.summary(
            promptIDs: [expectedPromptID],
            count: 1
        )])
        tap?()
        XCTAssertEqual(routes, [.status])
        XCTAssertEqual(try Data(contentsOf: journalURL), beforeJournal)
        XCTAssertEqual(try Data(contentsOf: snapshotURL), beforeSnapshot)
    }

    func testCancelledQuietEndCallbackCannotOverrideNewScheduleOrRetryEarly() throws {
        let harness = try makeHarness()
        let scheduler = ManualPromptScheduler()
        let calendar = utcCalendar()
        var currentNow = date(hour: 23, calendar: calendar)
        var stateChangeCount = 0
        let service = PetTravelPromptService(
            coordinator: harness.coordinator,
            showBubble: { _, _, _ in XCTFail("empty repository has nothing to show"); return false },
            postNotification: { _ in XCTFail("empty repository has nothing to notify"); return false },
            route: { _ in },
            stateChanged: { stateChangeCount += 1 },
            calendar: calendar,
            scheduler: scheduler,
            clock: { currentNow }
        )

        service.ingestCurrent(
            settings: .init(quietStart: 22, quietEnd: 8),
            now: currentNow
        )
        currentNow = date(hour: 22, calendar: calendar)
        service.retry(
            settings: .init(quietStart: 21, quietEnd: 7),
            now: currentNow
        )
        XCTAssertEqual(scheduler.totalCount, 2)
        XCTAssertEqual(scheduler.activeCount, 1)
        let beforeStaleCallback = stateChangeCount

        scheduler.forceFire(at: 0)

        XCTAssertEqual(stateChangeCount, beforeStaleCallback)
        XCTAssertEqual(scheduler.activeCount, 1, "stale callback must not cancel the current quiet-end token")

        currentNow = date(day: 24, hour: 6, calendar: calendar)
        scheduler.forceFire(at: 1)
        XCTAssertEqual(stateChangeCount, beforeStaleCallback + 1)
        XCTAssertEqual(
            scheduler.activeCount,
            1,
            "current callback must retry using the injected current clock and schedule the still-quiet 07:00 end"
        )
    }

    func testNotificationSuccessUsesTypedPayloadAndDefaultActionRoute() async throws {
        let harness = try makeHarness()
        let departure = try publish(phase: .preparing, in: harness.repository)
        let attempted = expectation(description: "fallback notification")
        var payload: PetTravelNotificationPayload?
        let service = PetTravelPromptService(
            coordinator: harness.coordinator,
            showBubble: { _, _, _ in false },
            postNotification: { delivery in
                payload = try? PetTravelNotificationPayload(delivery: delivery)
                attempted.fulfill()
                return payload != nil
            },
            route: { _ in }
        )

        service.ingestCurrent(settings: .init(), now: noon)
        await fulfillment(of: [attempted], timeout: 2)

        let typed = try XCTUnwrap(payload)
        XCTAssertEqual(typed.route, .status)
        XCTAssertEqual(PetTravelNotificationPayload.route(userInfo: typed.userInfo), .status)
        XCTAssertEqual(try harness.coordinator.pendingCount, 0)
        XCTAssertTrue(typed.identifier.contains("-event-"))
        XCTAssertFalse(typed.identifier.contains(departure.id.uuidString.lowercased()))
    }

    func testNotificationPayloadRoundTripsAllRoutesAndRejectsUnknownOrNoncanonicalInput() throws {
        let eventID = UUID(uuidString: "abcdefab-2222-4333-8444-555555555555")!
        let tripID = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
        let deliveries: [(PetTravelPromptDelivery, PetTravelRoute)] = [
            (.prompt(.departed(eventID: eventID, tripID: tripID, location: nil, summary: "出发")), .status),
            (.prompt(.postcardReady(eventID: eventID, tripID: tripID, location: nil, mood: "开心", quote: "海风")), .postcard(eventID: eventID, tripID: tripID)),
            (.prompt(.returned(eventID: eventID, tripID: tripID, mood: "安心")), .album(tripID)),
            (.summary(promptIDs: ["one"], count: 1), .status),
        ]
        for (delivery, route) in deliveries {
            let payload = try PetTravelNotificationPayload(delivery: delivery)
            XCTAssertEqual(payload.route, route)
            XCTAssertEqual(PetTravelNotificationPayload.route(userInfo: payload.userInfo), route)
        }

        let canonicalEvent = eventID.uuidString.lowercased()
        let canonicalTrip = tripID.uuidString.lowercased()
        XCTAssertNil(PetTravelNotificationPayload.route(userInfo: [
            "route": "postcard", "eventID": canonicalEvent, "tripID": canonicalTrip, "extra": "no",
        ]))
        XCTAssertNil(PetTravelNotificationPayload.route(userInfo: [
            "route": "postcard", "eventID": eventID.uuidString, "tripID": canonicalTrip,
        ]))
        XCTAssertNil(PetTravelNotificationPayload.route(userInfo: [
            "route": "unknown",
        ]))
        XCTAssertNil(PetTravelNotificationPayload.route(userInfo: [
            "route": "album", "tripID": "not-a-uuid",
        ]))
        XCTAssertNil(PetTravelNotificationPayload.route(userInfo: [
            "route": "status", "tripID": canonicalTrip,
        ]))
    }

    func testNotificationIdentifiersAreFixedLengthDomainSeparatedAndDeterministic() throws {
        let eventID = UUID(uuidString: "abcdefab-2222-4333-8444-555555555555")!
        let tripID = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
        let event = PetTravelPromptDelivery.prompt(
            .postcardReady(
                eventID: eventID,
                tripID: tripID,
                location: nil,
                mood: "开心",
                quote: "海风"
            )
        )
        let longIDs = (0..<2_000).map { "pet-prompt-\($0)-" + String(repeating: "x", count: 80) }
        let summary = PetTravelPromptDelivery.summary(promptIDs: longIDs, count: longIDs.count)

        let eventIdentifier = try PetTravelNotificationPayload(delivery: event).identifier
        let repeatedEventIdentifier = try PetTravelNotificationPayload(delivery: event).identifier
        let summaryIdentifier = try PetTravelNotificationPayload(delivery: summary).identifier

        XCTAssertEqual(eventIdentifier, repeatedEventIdentifier)
        XCTAssertEqual(eventIdentifier.count, summaryIdentifier.count)
        XCTAssertLessThanOrEqual(summaryIdentifier.utf8.count, 128)
        XCTAssertTrue(eventIdentifier.contains("-event-"))
        XCTAssertTrue(summaryIdentifier.contains("-batch-"))
        XCTAssertNotEqual(eventIdentifier, summaryIdentifier)
    }

    func testNotificationActionRouterAcceptsOnlyDefaultClick() throws {
        let tripID = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
        let payload = try PetTravelNotificationPayload(
            delivery: .prompt(.returned(eventID: UUID(), tripID: tripID, mood: "安心"))
        )

        XCTAssertEqual(
            PetTravelNotificationActionRouter.route(
                actionIdentifier: UNNotificationDefaultActionIdentifier,
                userInfo: payload.userInfo
            ),
            .album(tripID)
        )
        XCTAssertNil(PetTravelNotificationActionRouter.route(
            actionIdentifier: UNNotificationDismissActionIdentifier,
            userInfo: payload.userInfo
        ))
    }

    func testForegroundNotificationPolicyShowsOnlyPetPromptFallbacks() {
        let petOptions = PetTravelForegroundNotificationPolicy.options(
            categoryIdentifier: "travel-cat-pet-prompt"
        )
        XCTAssertTrue(petOptions.contains(.banner))
        XCTAssertTrue(petOptions.contains(.list))
        XCTAssertTrue(petOptions.contains(.sound))
        XCTAssertEqual(
            PetTravelForegroundNotificationPolicy.options(categoryIdentifier: "postcard"),
            []
        )
    }

    func testNotificationDelegateWiresForegroundPolicyAndDefaultSound() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/TravelCatApp/NotificationService.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("willPresent notification: UNNotification"))
        XCTAssertTrue(source.contains("PetTravelForegroundNotificationPolicy.options("))
        XCTAssertTrue(source.contains("content.sound = .default"))
    }

    func testDeniedOrFailedNotificationDoesNotAcknowledge() async throws {
        for result in [false, false] {
            let harness = try makeHarness()
            _ = try publish(phase: .preparing, in: harness.repository)
            let attempted = expectation(description: "notification rejected")
            let service = PetTravelPromptService(
                coordinator: harness.coordinator,
                showBubble: { _, _, _ in false },
                postNotification: { _ in attempted.fulfill(); return result },
                route: { _ in }
            )
            service.ingestCurrent(settings: .init(), now: noon)
            await fulfillment(of: [attempted], timeout: 2)
            XCTAssertEqual(try harness.coordinator.pendingCount, 1)
        }
    }

    func testFailedBubbleAndNotificationRetryUntilPetBecomesAvailable() async throws {
        let harness = try makeHarness()
        let departure = try publish(phase: .preparing, in: harness.repository)
        let scheduler = ManualPromptScheduler()
        let notificationAttempted = expectation(description: "notification fallback attempted")
        var petAvailable = false
        var shown: [PetTravelPromptDelivery] = []
        let service = PetTravelPromptService(
            coordinator: harness.coordinator,
            showBubble: { delivery, _, _ in
                shown.append(delivery)
                return petAvailable
            },
            postNotification: { _ in
                notificationAttempted.fulfill()
                return false
            },
            route: { _ in },
            scheduler: scheduler,
            clock: { self.noon }
        )

        service.ingestCurrent(settings: .init(), now: noon)
        await fulfillment(of: [notificationAttempted], timeout: 2)
        XCTAssertEqual(scheduler.activeCount, 1)
        XCTAssertEqual(try harness.coordinator.pendingCount, 1)

        petAvailable = true
        scheduler.fireNext()

        let expected = PetTravelPromptDelivery.prompt(.departed(
            eventID: departure.id,
            tripID: departure.tripID,
            location: departure.location,
            summary: departure.summary
        ))
        XCTAssertEqual(shown, [expected, expected])
        XCTAssertEqual(try harness.coordinator.pendingCount, 0)
        XCTAssertEqual(scheduler.activeCount, 0)
    }

    func testUnavailablePetRetryUsesBoundedExponentialBackoff() async throws {
        let harness = try makeHarness()
        _ = try publish(phase: .preparing, in: harness.repository)
        let scheduler = ManualPromptScheduler()
        var notificationCount = 0
        let service = PetTravelPromptService(
            coordinator: harness.coordinator,
            showBubble: { _, _, _ in false },
            postNotification: { _ in notificationCount += 1; return false },
            route: { _ in },
            scheduler: scheduler,
            clock: { self.noon }
        )

        service.ingestCurrent(settings: .init(), now: noon)
        await waitUntil { notificationCount == 1 && scheduler.activeCount == 1 }

        for (index, expectedDelay) in [1.0, 2.0, 4.0, 8.0, 16.0].enumerated() {
            XCTAssertEqual(scheduler.activeDelays, [expectedDelay])
            scheduler.fireNext()
            await waitUntil {
                notificationCount == index + 2
                    && (index == 4 || scheduler.activeCount == 1)
            }
        }

        XCTAssertEqual(notificationCount, 6)
        XCTAssertEqual(scheduler.activeCount, 0)
        XCTAssertEqual(try harness.coordinator.pendingCount, 1)
    }

    func testCancelledUnavailableRetryCannotClearNewerRetry() async throws {
        let harness = try makeHarness()
        _ = try publish(phase: .preparing, in: harness.repository)
        let scheduler = ManualPromptScheduler()
        var notificationCount = 0
        let service = PetTravelPromptService(
            coordinator: harness.coordinator,
            showBubble: { _, _, _ in false },
            postNotification: { _ in notificationCount += 1; return false },
            route: { _ in },
            scheduler: scheduler,
            clock: { self.noon },
            preferBubble: { $0.followCodexPet }
        )

        service.ingestCurrent(settings: .init(followCodexPet: true), now: noon)
        await waitUntil { notificationCount == 1 && scheduler.activeCount == 1 }

        service.settingsDidChange(settings: .init(followCodexPet: false), now: noon)
        await waitUntil { notificationCount == 2 && scheduler.activeCount == 0 }
        service.settingsDidChange(settings: .init(followCodexPet: true), now: noon)
        await waitUntil { notificationCount == 3 && scheduler.activeCount == 1 }

        scheduler.forceFire(at: 0)
        await Task.yield()

        XCTAssertEqual(notificationCount, 3)
        XCTAssertEqual(scheduler.activeCount, 1)
        XCTAssertEqual(scheduler.activeDelays, [1])
        XCTAssertEqual(try harness.coordinator.pendingCount, 1)
    }

    func testEnablingBubbleDuringFailedNotificationRetriesCurrentPromptImmediately() async throws {
        let harness = try makeHarness()
        let departure = try publish(phase: .preparing, in: harness.repository)
        let notificationStarted = expectation(description: "notification started")
        let bubbleShown = expectation(description: "bubble shown after notification failure")
        let deferredNotification = DeferredNotificationResult {
            notificationStarted.fulfill()
        }
        var shown: [PetTravelPromptDelivery] = []
        var preferences: [Bool] = []
        let service = PetTravelPromptService(
            coordinator: harness.coordinator,
            showBubble: { delivery, _, _ in
                shown.append(delivery)
                bubbleShown.fulfill()
                return true
            },
            postNotification: deferredNotification.post,
            route: { _ in },
            clock: { self.noon },
            preferBubble: { $0.followCodexPet },
            applyBubblePreference: { preferences.append($0) }
        )

        service.ingestCurrent(settings: .init(followCodexPet: false), now: noon)
        await fulfillment(of: [notificationStarted], timeout: 2)
        service.settingsDidChange(settings: .init(followCodexPet: true), now: noon)
        deferredNotification.complete(false)
        await fulfillment(of: [bubbleShown], timeout: 2)

        XCTAssertEqual(shown, [.prompt(.departed(
            eventID: departure.id,
            tripID: departure.tripID,
            location: departure.location,
            summary: departure.summary
        ))])
        XCTAssertEqual(preferences, [true])
        XCTAssertEqual(deferredNotification.deliveries.count, 1)
        XCTAssertEqual(try harness.coordinator.pendingCount, 0)
    }

    func testEnablingBubbleDuringSuccessfulNotificationAdvancesNextPromptImmediately() async throws {
        let harness = try makeHarness()
        let departed = try publish(phase: .preparing, in: harness.repository)
        let returned = try publish(phase: .resting, tripID: departed.tripID, in: harness.repository)
        let notificationStarted = expectation(description: "notification started")
        let bubbleShown = expectation(description: "next bubble shown after notification success")
        let deferredNotification = DeferredNotificationResult {
            notificationStarted.fulfill()
        }
        var shown: [PetTravelPromptDelivery] = []
        let service = PetTravelPromptService(
            coordinator: harness.coordinator,
            showBubble: { delivery, _, _ in
                shown.append(delivery)
                bubbleShown.fulfill()
                return true
            },
            postNotification: deferredNotification.post,
            route: { _ in },
            clock: { self.noon },
            preferBubble: { $0.followCodexPet },
            applyBubblePreference: { _ in }
        )

        service.ingestCurrent(settings: .init(followCodexPet: false), now: noon)
        await fulfillment(of: [notificationStarted], timeout: 2)
        service.settingsDidChange(settings: .init(followCodexPet: true), now: noon)
        deferredNotification.complete(true)
        await fulfillment(of: [bubbleShown], timeout: 2)

        XCTAssertEqual(shown, [
            .prompt(.returned(eventID: returned.id, tripID: returned.tripID, mood: returned.mood.label)),
        ])
        XCTAssertEqual(deferredNotification.deliveries.count, 1)
        XCTAssertEqual(try harness.coordinator.pendingCount, 0)
    }

    func testPostCommitAcknowledgementErrorKeepsFirstDiagnostic() throws {
        let harness = try makeHarness()
        _ = try publish(phase: .preparing, in: harness.repository)
        let firstError = PetTravelPromptCoordinatorError.persistenceFailed("post-commit-validation")
        let service = PetTravelPromptService(
            coordinator: harness.coordinator,
            showBubble: { _, _, _ in
                harness.coordinator.afterCommittingPromptTransaction = { _ in throw firstError }
                return true
            },
            postNotification: { _ in XCTFail("must not fall back"); return false },
            route: { _ in }
        )

        service.ingestCurrent(settings: .init(), now: noon)

        XCTAssertEqual(service.storageError, firstError)
        XCTAssertEqual(try harness.coordinator.pendingCount, 0, "the durable commit happened before validation failed")
    }

    private func makeHarness() throws -> PromptServiceHarness {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("PetTravelPromptServiceTests-\(UUID().uuidString)", isDirectory: true)
        let root = container.appendingPathComponent("repository", isDirectory: true)
        let repository = try TravelRepository(root: root)
        addTeardownBlock { try? FileManager.default.removeItem(at: container) }
        return PromptServiceHarness(
            repository: repository,
            coordinator: try PetTravelPromptCoordinator(repository: repository)
        )
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool,
        iterations: Int = 1_000
    ) async {
        for _ in 0..<iterations {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("condition was not reached")
    }

    @discardableResult
    private func publish(
        phase: TravelPhase,
        tripID suppliedTripID: UUID? = nil,
        postcardStatus: PostcardStatus = .none,
        in repository: TravelRepository
    ) throws -> TripEvent {
        let current = try repository.loadSnapshot()
        let tripID = suppliedTripID ?? UUID()
        let eventID = UUID()
        let occurredAt = current.lastUpdatedAt
        let location = phase == .resting ? nil : Location(country: "Japan", city: "Kamakura", place: "Kamakura Station")
        let event = TripEvent(
            id: eventID,
            tripID: tripID,
            previousEventID: current.lastEventID,
            occurredAt: occurredAt,
            phase: phase,
            location: location,
            transport: phase == .preparing ? nil : "步行",
            summary: phase == .resting ? "回到家，把照片收进旅行册。" : "黑猫背上小包出发。",
            mood: Mood(level: 1, label: phase == .resting ? "安心" : "期待", quote: "慢慢走。"),
            continuityReferences: ["旅行线索"],
            openHook: phase == .resting ? nil : "继续看看",
            consumedItemID: nil,
            postcardStatus: postcardStatus,
            postcardRelativePath: nil
        )
        let next = TripSnapshot(
            stateVersion: current.stateVersion + 1,
            tripID: tripID,
            lastEventID: eventID,
            phase: phase,
            nextActionAt: occurredAt.addingTimeInterval(60),
            lastUpdatedAt: occurredAt,
            carriedItemID: nil,
            usedItemIDs: current.usedItemIDs,
            visitedPlaces: current.visitedPlaces + (location.map { [$0.place] } ?? []),
            mood: event.mood,
            openHook: event.openHook
        )
        try repository.publish(event: event, next: next)
        return event
    }

    private func prepareReadyPostcard(in harness: PromptServiceHarness) throws -> (eventID: UUID, tripID: UUID) {
        let departed = try publish(phase: .preparing, in: harness.repository)
        try harness.coordinator.ingestCurrent(policy: openPolicy, hour: 12)
        let departedDelivery = try XCTUnwrap(harness.coordinator.nextDelivery(policy: openPolicy, hour: 12).first)
        try harness.coordinator.deliverySucceeded(departedDelivery)
        _ = try publish(phase: .transit, tripID: departed.tripID, in: harness.repository)
        _ = try publish(phase: .exploring, tripID: departed.tripID, in: harness.repository)
        let postcard = try publish(
            phase: .postcardReady,
            tripID: departed.tripID,
            postcardStatus: .pendingImage,
            in: harness.repository
        )
        try harness.coordinator.ingestCurrent(policy: openPolicy, hour: 12)
        try rewritePostcardReady(postcard.id, in: harness.repository)
        return (postcard.id, postcard.tripID)
    }

    private func rewritePostcardReady(_ eventID: UUID, in repository: TravelRepository) throws {
        var events = try repository.events()
        let index = try XCTUnwrap(events.firstIndex(where: { $0.id == eventID }))
        events[index].postcardStatus = .ready
        events[index].postcardRelativePath = "\(events[index].tripID.uuidString.lowercased())/card.webp"
        var journal = Data()
        let encoder = JSONEncoder.travelCat
        encoder.outputFormatting = [.sortedKeys]
        for event in events {
            journal.append(try encoder.encode(event))
            journal.append(0x0A)
        }
        try journal.write(to: repository.root.appendingPathComponent("journal/events.jsonl"), options: .atomic)
    }

    private var openPolicy: NotificationPolicy { .init(quietStart: 8, quietEnd: 8) }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(day: Int = 23, hour: Int, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: day, hour: hour))!
    }
}

private struct PromptServiceHarness {
    let repository: TravelRepository
    let coordinator: PetTravelPromptCoordinator
}

@MainActor
private final class DeferredNotificationResult {
    private let started: () -> Void
    private var continuation: CheckedContinuation<Bool, Never>?
    private(set) var deliveries: [PetTravelPromptDelivery] = []

    init(started: @escaping () -> Void) {
        self.started = started
    }

    func post(_ delivery: PetTravelPromptDelivery) async -> Bool {
        deliveries.append(delivery)
        started()
        return await withCheckedContinuation { continuation = $0 }
    }

    func complete(_ result: Bool) {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: result)
    }
}

@MainActor
private final class ManualPromptScheduler: BubbleScheduling {
    private var entries: [ManualPromptCancellation] = []

    var activeCount: Int { entries.filter { !$0.isCancelled }.count }
    var totalCount: Int { entries.count }
    var activeDelays: [TimeInterval] {
        entries.filter { !$0.isCancelled }.map(\.delay)
    }

    func after(
        _ seconds: TimeInterval,
        _ action: @escaping @MainActor () -> Void
    ) -> BubbleCancellation {
        let token = ManualPromptCancellation(delay: seconds, action: action)
        entries.append(token)
        return token
    }

    func fireNext() {
        guard let token = entries.first(where: { !$0.isCancelled }) else { return }
        token.fire()
    }

    func forceFire(at index: Int) {
        entries[index].forceFire()
    }
}

@MainActor
private final class ManualPromptCancellation: BubbleCancellation {
    let delay: TimeInterval
    private var action: (() -> Void)?
    private(set) var isCancelled = false

    init(delay: TimeInterval, action: @escaping @MainActor () -> Void) {
        self.delay = delay
        self.action = action
    }

    func cancel() {
        isCancelled = true
    }

    func fire() {
        guard !isCancelled, let action else { return }
        isCancelled = true
        self.action = nil
        action()
    }

    func forceFire() {
        guard let action else { return }
        if !isCancelled {
            isCancelled = true
            self.action = nil
        }
        action()
    }
}
