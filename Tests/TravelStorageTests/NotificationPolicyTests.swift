import Foundation
import XCTest
import TravelCore
@testable import TravelStorage

final class NotificationPolicyTests: XCTestCase {
    func testQuietHourSemantics() {
        XCTAssertTrue(NotificationPolicy(quietStart: 22, quietEnd: 8).isQuiet(hour: 23))
        XCTAssertTrue(NotificationPolicy(quietStart: 22, quietEnd: 8).isQuiet(hour: 7))
        XCTAssertFalse(NotificationPolicy(quietStart: 22, quietEnd: 8).isQuiet(hour: 12))
        XCTAssertTrue(NotificationPolicy(quietStart: 9, quietEnd: 17).isQuiet(hour: 12))
        XCTAssertFalse(NotificationPolicy(quietStart: 9, quietEnd: 17).isQuiet(hour: 18))
        XCTAssertFalse(NotificationPolicy(quietStart: 8, quietEnd: 8).isQuiet(hour: 8))
        XCTAssertEqual(NotificationPolicy(quietStart: -1, quietEnd: 25), NotificationPolicy(quietStart: 23, quietEnd: 1))
    }

    func testDetectorFindsTerminalPostcardsAndReturnOnlyOnce() {
        let id = UUID()
        let trip = UUID()
        let pending = TripEvent.fixture(id: id, tripID: trip, phase: .postcardReady, postcardStatus: .pendingImage)
        var ready = pending
        ready.postcardStatus = .ready
        ready.postcardRelativePath = "trip/card.webp"
        let prior = RepositoryContents(snapshot: .fixture(stateVersion: 1, tripID: trip, lastEventID: id, phase: .returning), events: [pending])
        let current = RepositoryContents(snapshot: .fixture(stateVersion: 2, tripID: trip, lastEventID: id, phase: .resting), events: [ready])

        XCTAssertEqual(NotificationDetector.detect(previous: prior, current: current), [
            .postcard(id: id, place: nil, mood: ready.mood.label),
            .returned(tripID: trip, mood: current.snapshot.mood.label),
        ])
        XCTAssertEqual(NotificationDetector.detect(previous: current, current: current), [])
    }

    func testUnavailableDetectorEmitsOnlyFirstTransitionToImageUnavailable() {
        let eventID = UUID()
        let tripID = UUID()
        let pending = TripEvent.fixture(
            id: eventID,
            tripID: tripID,
            phase: .postcardReady,
            postcardStatus: .pendingImage
        )
        var unavailable = pending
        unavailable.postcardStatus = .imageUnavailable
        let snapshot = TripSnapshot.fixture(
            stateVersion: 1,
            tripID: tripID,
            lastEventID: eventID,
            phase: .postcardReady
        )
        let previous = RepositoryContents(snapshot: snapshot, events: [pending])
        let current = RepositoryContents(snapshot: snapshot, events: [unavailable])

        XCTAssertEqual(NotificationDetector.detectUnavailable(previous: previous, current: current), [
            .postcard(id: eventID, place: unavailable.location?.place, mood: unavailable.mood.label),
        ])
        XCTAssertEqual(NotificationDetector.detectUnavailable(previous: current, current: current), [])

        var ready = unavailable
        ready.postcardStatus = .ready
        ready.postcardRelativePath = "trip/card.webp"
        XCTAssertEqual(
            NotificationDetector.detectUnavailable(previous: previous, current: .init(snapshot: snapshot, events: [ready])),
            [],
            "ready postcards belong only to the durable pet prompt channel"
        )
    }

    func testCoordinatorDefersAndSummarizesWithPersistedDedup() throws {
        let suite = "NotificationPolicyTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var delivered: [NotificationDelivery] = []
        let coordinator = NotificationCoordinator(defaults: defaults) { delivered.append($0) }
        let event = NotificationEvent.returned(tripID: UUID(), mood: "安心")

        XCTAssertEqual(coordinator.process([event], policy: .init(quietStart: 22, quietEnd: 8), hour: 23), .defer)
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertEqual(coordinator.process([], policy: .init(quietStart: 22, quietEnd: 8), hour: 8), .deliverSummary)
        XCTAssertEqual(delivered, [.summary(count: 1)])
        coordinator.deliverySucceeded(.summary(count: 1))
        XCTAssertEqual(coordinator.process([event], policy: .init(quietStart: 22, quietEnd: 8), hour: 9), .deliver)
        XCTAssertEqual(delivered, [.summary(count: 1)])
    }

    func testSummaryIncludesFreshEventsArrivingAtQuietEnd() throws {
        let suite = "NotificationPolicyTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var delivered: [NotificationDelivery] = []
        let coordinator = NotificationCoordinator(defaults: defaults) { delivered.append($0) }
        let first = NotificationEvent.returned(tripID: UUID(), mood: "安心")
        let second = NotificationEvent.returned(tripID: UUID(), mood: "开心")
        _ = coordinator.process([first], policy: .init(quietStart: 22, quietEnd: 8), hour: 23)

        XCTAssertEqual(
            coordinator.process([second], policy: .init(quietStart: 22, quietEnd: 8), hour: 8),
            .deliverSummary
        )
        XCTAssertEqual(delivered, [.summary(count: 2)])
        coordinator.deliverySucceeded(.summary(count: 2))
        XCTAssertEqual(coordinator.process([second], policy: .init(quietStart: 22, quietEnd: 8), hour: 9), .deliver)
        XCTAssertEqual(delivered, [.summary(count: 2)])
    }

    func testFailedDeliveryBecomesRetryableButSuccessfulDeliveryStaysDeduplicated() throws {
        let suite = "NotificationPolicyTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var delivered: [NotificationDelivery] = []
        let coordinator = NotificationCoordinator(defaults: defaults) { delivered.append($0) }
        let event = NotificationEvent.returned(tripID: UUID(), mood: "安心")
        _ = coordinator.process([event], policy: .init(quietStart: 8, quietEnd: 8), hour: 12)
        coordinator.deliveryFailed(.event(event))
        _ = coordinator.process([event], policy: .init(quietStart: 8, quietEnd: 8), hour: 12)
        coordinator.deliverySucceeded(.event(event))
        _ = coordinator.process([event], policy: .init(quietStart: 8, quietEnd: 8), hour: 12)
        XCTAssertEqual(delivered, [.event(event), .event(event)])
    }

    func testPendingSummaryRetriesAfterRelaunchAndSuccessCommitsConstituentIDs() throws {
        let suite = "NotificationPolicyTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let postcard = NotificationEvent.postcard(id: UUID(), place: "镰仓", mood: "开心")
        let returned = NotificationEvent.returned(tripID: UUID(), mood: "安心")
        var firstDeliveries: [NotificationDelivery] = []
        let first = NotificationCoordinator(defaults: defaults) { firstDeliveries.append($0) }
        _ = first.process([postcard, returned], policy: .init(quietStart: 22, quietEnd: 8), hour: 23)
        XCTAssertEqual(first.process([], policy: .init(quietStart: 22, quietEnd: 8), hour: 8), .deliverSummary)
        XCTAssertEqual(firstDeliveries, [.summary(count: 2)])

        _ = first.process([], policy: .init(quietStart: 22, quietEnd: 8), hour: 9)
        XCTAssertEqual(firstDeliveries, [.summary(count: 2)], "one live coordinator must not resend in-flight summary")

        var relaunchedDeliveries: [NotificationDelivery] = []
        let relaunched = NotificationCoordinator(defaults: defaults) { relaunchedDeliveries.append($0) }
        XCTAssertEqual(relaunched.process([], policy: .init(quietStart: 22, quietEnd: 8), hour: 9), .deliverSummary)
        XCTAssertEqual(relaunchedDeliveries, [.summary(count: 2)])
        relaunched.deliverySucceeded(.summary(count: 2))

        var afterSuccess: [NotificationDelivery] = []
        let completed = NotificationCoordinator(defaults: defaults) { afterSuccess.append($0) }
        XCTAssertEqual(completed.process([postcard, returned], policy: .init(quietStart: 22, quietEnd: 8), hour: 9), .deliver)
        XCTAssertTrue(afterSuccess.isEmpty)
    }

    func testFailedSummaryRemainsPersistedAndRetriesAfterRelaunch() throws {
        let suite = "NotificationPolicyTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let event = NotificationEvent.returned(tripID: UUID(), mood: "安心")
        var firstDeliveries: [NotificationDelivery] = []
        let first = NotificationCoordinator(defaults: defaults) { firstDeliveries.append($0) }
        _ = first.process([event], policy: .init(quietStart: 22, quietEnd: 8), hour: 23)
        _ = first.process([], policy: .init(quietStart: 22, quietEnd: 8), hour: 8)
        first.deliveryFailed(.summary(count: 1))

        var relaunchedDeliveries: [NotificationDelivery] = []
        let relaunched = NotificationCoordinator(defaults: defaults) { relaunchedDeliveries.append($0) }
        XCTAssertEqual(relaunched.process([], policy: .init(quietStart: 22, quietEnd: 8), hour: 9), .deliverSummary)
        XCTAssertEqual(relaunchedDeliveries, [.summary(count: 1)])
    }

    func testPendingOrdinaryPostcardRetriesAfterCrashThenSuccessDeduplicates() throws {
        try assertOrdinaryCrashRetry(
            .postcard(id: UUID(), place: "海边 车站", mood: "开心")
        )
    }

    func testPendingOrdinaryReturnRetriesAfterFailureAndRepeatedProcessSendsOnce() throws {
        let suite = "NotificationPolicyTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let event = NotificationEvent.returned(tripID: UUID(), mood: "安心")
        var firstDeliveries: [NotificationDelivery] = []
        let first = NotificationCoordinator(defaults: defaults) { firstDeliveries.append($0) }
        _ = first.process([event], policy: .init(quietStart: 8, quietEnd: 8), hour: 12)
        _ = first.process([event], policy: .init(quietStart: 8, quietEnd: 8), hour: 12)
        XCTAssertEqual(firstDeliveries, [.event(event)])
        first.deliveryFailed(.event(event))

        var relaunchedDeliveries: [NotificationDelivery] = []
        let relaunched = NotificationCoordinator(defaults: defaults) { relaunchedDeliveries.append($0) }
        _ = relaunched.process([], policy: .init(quietStart: 8, quietEnd: 8), hour: 12)
        XCTAssertEqual(relaunchedDeliveries, [.event(event)])
    }

    private func assertOrdinaryCrashRetry(_ event: NotificationEvent) throws {
        let suite = "NotificationPolicyTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var firstDeliveries: [NotificationDelivery] = []
        let first = NotificationCoordinator(defaults: defaults) { firstDeliveries.append($0) }
        _ = first.process([event], policy: .init(quietStart: 8, quietEnd: 8), hour: 12)
        XCTAssertEqual(firstDeliveries, [.event(event)])

        var relaunchedDeliveries: [NotificationDelivery] = []
        let relaunched = NotificationCoordinator(defaults: defaults) { relaunchedDeliveries.append($0) }
        _ = relaunched.process([], policy: .init(quietStart: 8, quietEnd: 8), hour: 12)
        XCTAssertEqual(relaunchedDeliveries, [.event(event)])
        relaunched.deliverySucceeded(.event(event))

        var completedDeliveries: [NotificationDelivery] = []
        let completed = NotificationCoordinator(defaults: defaults) { completedDeliveries.append($0) }
        _ = completed.process([event], policy: .init(quietStart: 8, quietEnd: 8), hour: 12)
        XCTAssertTrue(completedDeliveries.isEmpty)
    }
}
