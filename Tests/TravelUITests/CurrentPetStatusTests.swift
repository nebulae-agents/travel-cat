import XCTest
import TravelCore
@testable import TravelUI

final class CurrentPetStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @MainActor
    func testCommittedReturnHomeSnapshotChangesDesktopScene() throws {
        let suite = "CurrentPetStatusTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var returning = TripSnapshot.empty(now: now.addingTimeInterval(-60))
        returning.phase = .returning
        let model = AppModel(snapshot: returning, defaults: defaults, clock: { self.now })
        XCTAssertEqual(CurrentPetStatus(snapshot: model.snapshot, events: model.events, now: now).scene, .away)
        var home = returning
        home.stateVersion += 1
        home.phase = .resting
        home.lastUpdatedAt = now.addingTimeInterval(-1)
        model.apply(next: home, events: [])
        let status = CurrentPetStatus(snapshot: model.snapshot, events: model.events, now: now)
        XCTAssertEqual(status.scene, .home)
        XCTAssertEqual(status.desktopSpritePhase, .resting)
    }

    func testEveryPhaseHasAnHonestTitleAndScene() {
        let cases: [(TravelPhase, String, CurrentPetStatus.Scene)] = [
            (.resting, "在家", .home), (.preparing, "准备出游", .packing),
            (.transit, "正在途中", .away), (.exploring, "正在探索", .away),
            (.postcardReady, "旅行中 · 明信片时刻", .away), (.returning, "正在返程", .away)
        ]
        for (phase, title, scene) in cases {
            var snapshot = TripSnapshot.empty(now: now)
            snapshot.phase = phase
            let status = CurrentPetStatus(snapshot: snapshot, events: [], now: now)
            XCTAssertEqual(status.title, title)
            XCTAssertEqual(status.scene, scene)
            XCTAssertTrue(status.codexActivityNotice.contains("暂未接入"))
            XCTAssertFalse(status.codexActivityNotice.contains("由 Codex 管理"))
            XCTAssertEqual(status.desktopSpritePhase, scene == .home ? .resting : scene == .packing ? .preparing : nil)
            XCTAssertNil(status.location)
            XCTAssertNil(status.transport)
        }
    }

    func testOnlyUniqueBoundAcceptedEventProvidesCurrentDetails() {
        let event = makeEvent()
        let snapshot = makeSnapshot(event)
        let status = CurrentPetStatus(snapshot: snapshot, events: [event], now: now)
        XCTAssertEqual(status.location, "西湖")
        XCTAssertEqual(status.transport, "火车")
        XCTAssertEqual(status.summary, "沿湖散步")
        XCTAssertEqual(status.updatedAt, now)
        let wrongTrip = makeEvent(id: event.id)
        let future = makeEvent(id: event.id, tripID: event.tripID, date: now.addingTimeInterval(1))
        let wrongPhase = makeEvent(id: event.id, tripID: event.tripID, phase: .returning)
        for events in [[wrongTrip], [future], [wrongPhase], [event, event], []] {
            let rejected = CurrentPetStatus(snapshot: snapshot, events: events, now: now)
            XCTAssertNil(rejected.location)
            XCTAssertNil(rejected.transport)
            XCTAssertNil(rejected.summary)
        }
    }

    func testFutureSnapshotIsNotPresentedAsCurrentState() {
        var snapshot = TripSnapshot.empty(now: now.addingTimeInterval(10))
        snapshot.phase = .resting
        let status = CurrentPetStatus(snapshot: snapshot, events: [], now: now)
        XCTAssertEqual(status.scene, .unknown)
        XCTAssertEqual(status.title, "当前状态暂不可用")
        XCTAssertNil(status.updatedAt)
        XCTAssertNil(status.desktopSpritePhase)
    }

    func testHomeDoesNotReuseOldDestinationOrInventPlayBehavior() {
        var snapshot = makeSnapshot(makeEvent())
        snapshot.phase = .resting
        snapshot.visitedPlaces = ["旧地点"]
        let status = CurrentPetStatus(snapshot: snapshot, events: [makeEvent()], now: now)
        XCTAssertNil(status.location)
        XCTAssertFalse(status.title.contains("玩耍"))
        XCTAssertFalse(status.title.contains("打盹"))
    }

    private func makeEvent(id: UUID = UUID(), tripID: UUID = UUID(), date: Date? = nil,
                           phase: TravelPhase = .exploring) -> TripEvent {
        TripEvent(id: id, tripID: tripID, previousEventID: nil, occurredAt: date ?? now,
                  phase: phase, location: Location(country: "中国", city: "杭州", place: "西湖"),
                  transport: "火车", summary: "沿湖散步", mood: Mood(level: 1, label: "平静", quote: "湖风很轻"),
                  continuityReferences: [], openHook: nil, consumedItemID: nil, postcardStatus: .none,
                  postcardRelativePath: nil)
    }

    private func makeSnapshot(_ event: TripEvent) -> TripSnapshot {
        TripSnapshot(stateVersion: 1, tripID: event.tripID, lastEventID: event.id,
                     phase: event.phase, nextActionAt: now.addingTimeInterval(600), lastUpdatedAt: now,
                     usedItemIDs: [], visitedPlaces: [], mood: event.mood)
    }
}
