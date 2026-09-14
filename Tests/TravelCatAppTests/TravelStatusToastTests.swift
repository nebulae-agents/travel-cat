import XCTest
import TravelCore
import TravelStorage
@testable import TravelCatApp

final class TravelStatusToastTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let settings = TravelSettings(quietStart: 0, quietEnd: 0)

    func testTransitExploringAndReturningGetStatusChangesWithoutPostcards() {
        for (phase, title) in [(TravelPhase.transit, "正在途中"), (.exploring, "正在探索"), (.returning, "正在返程")] {
            let old = contents(phase: .preparing, version: 1)
            let next = contents(phase: phase, version: 2, tripID: old.snapshot.tripID!)
            let result = TravelStatusToastPolicy.content(previous: old, current: next, now: now, settings: settings)
            XCTAssertEqual(result?.title, title)
        }
    }

    func testStartupDuplicatesStaleAndFutureNeverPrompt() {
        let current = contents(phase: .transit, version: 2)
        XCTAssertNil(TravelStatusToastPolicy.content(previous: nil, current: current, now: now, settings: settings))
        XCTAssertNil(TravelStatusToastPolicy.content(previous: current, current: current, now: now, settings: settings))
        let older = contents(phase: .exploring, version: 1)
        XCTAssertNil(TravelStatusToastPolicy.content(previous: current, current: older, now: now, settings: settings))
        let future = contents(phase: .exploring, version: 3, date: now.addingTimeInterval(1))
        XCTAssertNil(TravelStatusToastPolicy.content(previous: current, current: future, now: now, settings: settings))
    }

    func testExistingPreparationReturnAndPostcardPromptsAreNotDuplicated() {
        let old = contents(phase: .transit, version: 1)
        for phase in [TravelPhase.preparing, .resting, .postcardReady] {
            let next = contents(phase: phase, version: 2)
            XCTAssertNil(TravelStatusToastPolicy.content(previous: old, current: next, now: now, settings: settings))
        }
        for status in [PostcardStatus.ready, .imageUnavailable] {
            let next = contents(phase: .exploring, version: 2, postcard: status)
            XCTAssertNil(TravelStatusToastPolicy.content(previous: old, current: next, now: now, settings: settings))
        }
    }

    func testDisabledAndQuietSettingsSuppressPrompt() {
        let old = contents(phase: .preparing, version: 1)
        let next = contents(phase: .transit, version: 2)
        XCTAssertNil(TravelStatusToastPolicy.content(previous: old, current: next, now: now,
            settings: TravelSettings(quietStart: 0, quietEnd: 0, followCodexPet: false)))
        let hour = Calendar.current.component(.hour, from: now)
        XCTAssertNil(TravelStatusToastPolicy.content(previous: old, current: next, now: now,
            settings: TravelSettings(quietStart: hour, quietEnd: (hour + 1) % 24)))
    }

    func testDuplicateOrUnboundEventIsNotAStatusChange() {
        let old = contents(phase: .preparing, version: 1)
        let next = contents(phase: .transit, version: 2)
        let duplicates = RepositoryContents(snapshot: next.snapshot, events: next.events + next.events)
        let unbound = RepositoryContents(snapshot: next.snapshot, events: [])
        for invalid in [duplicates, unbound] {
            XCTAssertNil(TravelStatusToastPolicy.content(previous: old, current: invalid, now: now, settings: settings))
        }
    }

    private func contents(phase: TravelPhase, version: Int, tripID: UUID = UUID(), date: Date? = nil,
                          postcard: PostcardStatus = .none) -> RepositoryContents {
        let event = TripEvent(id: UUID(), tripID: tripID, previousEventID: nil, occurredAt: date ?? now,
            phase: phase, location: Location(country: "中国", city: "杭州", place: "西湖"),
            transport: "火车", summary: "沿着湖边走一走", mood: Mood(level: 1, label: "平静", quote: "湖风很轻"),
            continuityReferences: [], openHook: nil, consumedItemID: nil, postcardStatus: postcard, postcardRelativePath: nil)
        let snapshot = TripSnapshot(stateVersion: version, tripID: tripID, lastEventID: event.id,
            phase: phase, nextActionAt: now.addingTimeInterval(600), lastUpdatedAt: date ?? now,
            usedItemIDs: [], visitedPlaces: [], mood: event.mood)
        return RepositoryContents(snapshot: snapshot, events: [event])
    }
}

@MainActor
final class TravelStatusToastControllerTests: XCTestCase {
    func testExpiresWithoutLeavingAPermanentIndicator() {
        let clock = StatusToastTestScheduler()
        let controller = TravelStatusToastController(scheduler: clock)
        controller.show(.init(title: "正在途中", message: "前往西湖"), onTap: {})
        XCTAssertNotNil(controller.content)
        clock.advance(by: 3)
        XCTAssertNotNil(controller.content)
        clock.advance(by: 1)
        XCTAssertNil(controller.content)
        XCTAssertFalse(controller.window?.isVisible ?? false)
    }

    func testReplacementCancelsOldExpiryAndClickRoutesOnce() {
        let clock = StatusToastTestScheduler()
        let controller = TravelStatusToastController(scheduler: clock)
        var taps = 0
        controller.show(.init(title: "旧状态", message: ""), onTap: { taps += 100 })
        clock.advance(by: 2)
        controller.show(.init(title: "新状态", message: ""), onTap: { taps += 1 })
        clock.advance(by: 2)
        XCTAssertEqual(controller.content?.title, "新状态")
        controller.activate()
        controller.activate()
        XCTAssertEqual(taps, 1)
        XCTAssertNil(controller.content)
        clock.advance(by: 10)
        XCTAssertNil(controller.content)
    }

    func testDismissCancelsTimerAndAction() {
        let clock = StatusToastTestScheduler()
        let controller = TravelStatusToastController(scheduler: clock)
        var taps = 0
        controller.show(.init(title: "状态", message: ""), onTap: { taps += 1 })
        controller.dismiss()
        controller.activate()
        clock.advance(by: 10)
        XCTAssertNil(controller.content)
        XCTAssertEqual(taps, 0)
    }

    func testAlreadyQueuedOldExpiryCannotDismissReplacement() {
        let clock = StatusToastTestScheduler()
        let controller = TravelStatusToastController(scheduler: clock)
        controller.show(.init(title: "旧状态", message: ""), onTap: {})
        clock.advance(by: 2)
        controller.show(.init(title: "新状态", message: ""), onTap: {})
        clock.advance(by: 2, includeCancelled: true)
        XCTAssertEqual(controller.content?.title, "新状态")
        controller.dismiss()
    }
}

@MainActor
private final class StatusToastTestScheduler: BubbleScheduling {
    private final class Token: BubbleCancellation {
        var cancelled = false
        func cancel() { cancelled = true }
    }
    private var time: TimeInterval = 0
    private var jobs: [(TimeInterval, Token, @MainActor () -> Void)] = []

    func after(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> BubbleCancellation {
        let token = Token()
        jobs.append((time + delay, token, action))
        return token
    }

    func advance(by delta: TimeInterval, includeCancelled: Bool = false) {
        time += delta
        let due = jobs.filter { $0.0 <= time }
        jobs.removeAll { $0.0 <= time }
        for (_, token, action) in due where includeCancelled || !token.cancelled { action() }
    }
}
