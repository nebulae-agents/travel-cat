import Foundation
import XCTest
import TravelCore
import TravelStorage
@testable import TravelCatApp

final class TravelStoryMemoryRequestTests: XCTestCase {
    func testLongJourneyRetainsSourcesForProjectedObservationAndSupplies() throws {
        let trip = UUID()
        let supply = event(trip: trip, phase: .preparing, seconds: 1, item: "camera")
        let observation = event(trip: trip, phase: .exploring, seconds: 2, place: "西湖")
        var history = [supply, observation]
        for number in 3..<30 { history.append(event(trip: trip, phase: .resting, seconds: Double(number))) }
        let memory = TravelStoryMemory(events: history, excludingTripID: nil, now: Date(timeIntervalSince1970: 1000))
        let journey = try XCTUnwrap(memory.completedJourneys.first)
        XCTAssertTrue(journey.sourceEventIDs.contains(supply.id))
        XCTAssertTrue(journey.sourceEventIDs.contains(observation.id))
        XCTAssertTrue(journey.sourceEventIDs.contains(history.last!.id))
        XCTAssertLessThanOrEqual(journey.sourceEventIDs.count, 12)
        XCTAssertEqual(memory, TravelStoryMemory(events: history.reversed(), excludingTripID: nil, now: Date(timeIntervalSince1970: 1000)))
    }
    func testNewDepartureIncludesPreviousCompletedJourneyBeyondRecentContext() throws {
        let trip = UUID()
        let now = Date(timeIntervalSince1970: 2000)
        let observation = event(trip: trip, phase: .exploring, seconds: 1000, place: "西湖", item: "camera")
        let home = event(trip: trip, phase: .resting, seconds: 1200)
        var snapshot = TripSnapshot.empty(now: now)
        snapshot.tripID = trip
        let request = TravelEventRequest(claim: .init(due: true, snapshot: snapshot, previousEvent: home),
            recentEvents: [home], phase: .preparing, historyEvents: [observation, home], now: now)
        let encoded = try JSONEncoder().encode(request)
        let restored = try JSONDecoder().decode(TravelEventRequest.self, from: encoded)
        let memory = try XCTUnwrap(restored.travelMemory.completedJourneys.first)
        XCTAssertEqual(memory.destination?.place, "西湖")
        XCTAssertEqual(memory.usedSupplyIDs, ["camera"])
        XCTAssertTrue(memory.sourceEventIDs.contains(observation.id))
        XCTAssertEqual(request.recentEvents, [home])
    }

    func testActiveIncompleteAndFutureJourneysAreExcludedAndProjectionIsDeterministic() {
        let active = UUID(), old = UUID(), future = UUID()
        let events = [event(trip: old, phase: .exploring, seconds: 100, place: "古城"),
                      event(trip: old, phase: .resting, seconds: 200),
                      event(trip: active, phase: .resting, seconds: 300),
                      event(trip: future, phase: .resting, seconds: 5000)]
        let now = Date(timeIntervalSince1970: 1000)
        let memory = TravelStoryMemory(events: events, excludingTripID: active, now: now)
        XCTAssertEqual(memory.completedJourneys.map(\.tripID), [old])
        XCTAssertEqual(memory, TravelStoryMemory(events: events.reversed(), excludingTripID: active, now: now))
        XCTAssertTrue(TravelStoryMemory(events: [events[0]], excludingTripID: nil, now: now).completedJourneys.isEmpty)
    }

    func testMemoryIsBoundedAndDoesNotChangePublishedEvents() throws {
        var history: [TripEvent] = []
        for number in 0..<20 {
            let trip = UUID()
            history += [event(trip: trip, phase: .exploring, seconds: Double(number * 10), place: "河岸"),
                        event(trip: trip, phase: .resting, seconds: Double(number * 10 + 1))]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let before = try encoder.encode(history)
        let memory = TravelStoryMemory(events: history, excludingTripID: nil, now: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(memory.completedJourneys.count, 6)
        XCTAssertEqual(memory.completedJourneys.first?.tripID, history.last?.tripID)
        XCTAssertEqual(try encoder.encode(history), before)
    }

    private func event(trip: UUID, phase: TravelPhase, seconds: Double, place: String? = nil, item: String? = nil) -> TripEvent {
        .init(id: UUID(), tripID: trip, previousEventID: nil, occurredAt: Date(timeIntervalSince1970: seconds), phase: phase,
              location: place.map { .init(country: "中国", city: "杭州", place: $0) }, transport: nil,
              summary: "小黑沿着岸边观察水面的倒影。", mood: .init(level: 0, label: "平静", quote: "风景刚刚好。"),
              continuityReferences: ["岸边"], openHook: nil, consumedItemID: item, postcardStatus: .none, postcardRelativePath: nil)
    }
}
