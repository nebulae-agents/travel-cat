import Foundation
import XCTest
import TravelCore
@testable import TravelUI

final class TripAlbumChronologyTests: XCTestCase {
    private func event(trip: UUID, day: Int, phase: TravelPhase = .postcardReady, place: String = "河边") -> TripEvent {
        TripEvent(id: UUID(), tripID: trip, previousEventID: nil,
            occurredAt: Date(timeIntervalSince1970: Double(day) * 86400 + 3600), phase: phase,
            location: Location(country: "中国", city: "广州", place: place), transport: nil,
            summary: "旅行记录", mood: Mood(level: 0, label: "平静", quote: "风轻轻吹"),
            continuityReferences: [], openHook: nil, consumedItemID: nil,
            postcardStatus: phase == .postcardReady ? .ready : .none, postcardRelativePath: nil)
    }
    private func work(_ event: TripEvent, supplement: Bool) -> PostcardWorkItem {
        .init(id: event.id, tripID: event.tripID, eventID: event.id, isSupplement: supplement,
              generatedAt: event.occurredAt, status: .ready)
    }

    func testSupplementSortsAndGroupsWithOriginalJourneyWithoutRewritingAuditTime() {
        let oldTrip = UUID(), newTrip = UUID()
        let first = event(trip: oldTrip, day: 1)
        let newer = event(trip: newTrip, day: 4)
        let supplement = event(trip: oldTrip, day: 10)
        let events = [first, newer, supplement]
        let work = [work(first, supplement: false), work(supplement, supplement: true), work(newer, supplement: false)]
        let dates = TripAlbumChronology.dates(events: events, workItems: work)
        XCTAssertEqual(dates[supplement.id], first.occurredAt)
        let ordered = TripAlbumView.orderedEvents(tripID: nil, events: events, workItems: work)
        XCTAssertEqual(ordered.map(\.id), [first.id, supplement.id, newer.id])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let groups = TripAlbumDateGrouping.groups(orderedEvents: ordered, calendar: calendar, displayDates: dates)
        XCTAssertEqual(groups.map { $0.events.map(\.id) }, [[first.id, supplement.id], [newer.id]])
        XCTAssertEqual(supplement.occurredAt, Date(timeIntervalSince1970: 10 * 86400 + 3600))
        XCTAssertEqual(work[1].generatedAt, supplement.occurredAt)
    }

    func testMultiDayJourneyUsesMatchingSceneAndNoCardTripUsesExploration() {
        let trip = UUID()
        let first = event(trip: trip, day: 1, place: "湖边")
        let last = event(trip: trip, day: 3, place: "山顶")
        let supplement = event(trip: trip, day: 10, place: "湖边")
        let items = [work(first, supplement: false), work(last, supplement: false), work(supplement, supplement: true)]
        XCTAssertEqual(TripAlbumChronology.dates(events: [first, last, supplement], workItems: items)[supplement.id], first.occurredAt)
        let exploration = event(trip: trip, day: 2, phase: .exploring, place: "湖边")
        XCTAssertEqual(TripAlbumChronology.dates(events: [exploration, supplement], workItems: [work(supplement, supplement: true)])[supplement.id], exploration.occurredAt)
    }

    func testMissingJourneyContextNeverLabelsGenerationAsTravelDate() {
        let supplement = event(trip: UUID(), day: 10)
        let dates = TripAlbumChronology.dates(events: [supplement], workItems: [work(supplement, supplement: true)])
        XCTAssertEqual(dates[supplement.id], TripAlbumChronology.unknownDate)
        XCTAssertEqual(TripAlbumDateGrouping.visibleLabel(for: TripAlbumChronology.unknownDate, showsYear: true, calendar: .current), "旅行日期待确认")
    }
}
