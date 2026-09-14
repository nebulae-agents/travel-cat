import Foundation
import XCTest
import TravelCore
@testable import TravelUI

final class TripAlbumDateGroupingTests: XCTestCase {
    func testGroupsSameDayEventsIncludingEqualTimestampsInInputOrder() {
        let calendar = calendar(timeZoneID: "Asia/Shanghai")
        let morning = date(2026, 12, 31, 8, 0, calendar: calendar)
        let noon = date(2026, 12, 31, 12, 0, calendar: calendar)
        let events = [readyPostcard(at: noon), readyPostcard(at: morning), readyPostcard(at: noon)]

        let groups = TripAlbumDateGrouping.groups(orderedEvents: events, calendar: calendar)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].day, calendar.startOfDay(for: morning))
        XCTAssertEqual(groups[0].events.map(\.id), events.map(\.id))
    }

    func testGroupsNextDayAsSecondGroup() {
        let calendar = calendar(timeZoneID: "Asia/Shanghai")
        let first = readyPostcard(at: date(2026, 12, 31, 23, 59, calendar: calendar))
        let second = readyPostcard(at: date(2027, 1, 1, 0, 1, calendar: calendar))

        let groups = TripAlbumDateGrouping.groups(orderedEvents: [first, second], calendar: calendar)

        XCTAssertEqual(groups.map(\.events), [[first], [second]])
    }

    func testGroupsEmptyInputAsEmpty() {
        XCTAssertEqual(
            TripAlbumDateGrouping.groups(
                orderedEvents: [],
                calendar: calendar(timeZoneID: "Asia/Shanghai")
            ),
            []
        )
    }

    func testGroupsUsingSuppliedCalendarWhenAbsoluteInstantsCrossLosAngelesMidnightOnly() {
        let losAngeles = calendar(timeZoneID: "America/Los_Angeles")
        let shanghai = calendar(timeZoneID: "Asia/Shanghai")
        let beforeMidnight = readyPostcard(at: date(2026, 1, 8, 23, 59, calendar: losAngeles))
        let afterMidnight = readyPostcard(at: date(2026, 1, 9, 0, 0, calendar: losAngeles))

        let losAngelesGroups = TripAlbumDateGrouping.groups(
            orderedEvents: [beforeMidnight, afterMidnight],
            calendar: losAngeles
        )
        let shanghaiGroups = TripAlbumDateGrouping.groups(
            orderedEvents: [beforeMidnight, afterMidnight],
            calendar: shanghai
        )

        XCTAssertEqual(losAngelesGroups.count, 2)
        XCTAssertEqual(losAngelesGroups.map(\.day), [
            losAngeles.startOfDay(for: beforeMidnight.occurredAt),
            losAngeles.startOfDay(for: afterMidnight.occurredAt),
        ])
        XCTAssertEqual(shanghaiGroups.count, 1)
        XCTAssertEqual(shanghaiGroups.map(\.day), [
            shanghai.startOfDay(for: beforeMidnight.occurredAt),
        ])
        XCTAssertEqual(shanghaiGroups[0].events, [beforeMidnight, afterMidnight])
    }

    func testGroupsLosAngelesSpringForwardTimesOnOneDay() {
        let calendar = calendar(timeZoneID: "America/Los_Angeles")
        let beforeJump = readyPostcard(at: date(2026, 3, 8, 1, 30, calendar: calendar))
        let afterJump = readyPostcard(at: date(2026, 3, 8, 3, 30, calendar: calendar))

        let groups = TripAlbumDateGrouping.groups(
            orderedEvents: [beforeJump, afterJump],
            calendar: calendar
        )

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].events, [beforeJump, afterJump])
    }

    func testDetectsWhetherDaysSpanMultipleYears() {
        let calendar = calendar(timeZoneID: "Asia/Shanghai")
        let december = date(2026, 12, 31, 12, 0, calendar: calendar)
        let january = date(2027, 1, 1, 12, 0, calendar: calendar)

        XCTAssertFalse(TripAlbumDateGrouping.spansMultipleYears(days: [december], calendar: calendar))
        XCTAssertTrue(TripAlbumDateGrouping.spansMultipleYears(days: [december, january], calendar: calendar))
    }

    func testFormatsExactChineseVisibleLabels() {
        let calendar = calendar(timeZoneID: "Asia/Shanghai")
        let december = date(2026, 12, 31, 12, 0, calendar: calendar)
        let january = date(2027, 1, 1, 12, 0, calendar: calendar)

        XCTAssertEqual(
            TripAlbumDateGrouping.visibleLabel(for: december, showsYear: false, calendar: calendar),
            "12月31日 · 周四"
        )
        XCTAssertEqual(
            TripAlbumDateGrouping.visibleLabel(for: january, showsYear: true, calendar: calendar),
            "2027年1月1日 · 周五"
        )
    }

    func testFormatsAccessibilityLabelWithYear() {
        let calendar = calendar(timeZoneID: "Asia/Shanghai")
        let date = date(2026, 12, 31, 12, 0, calendar: calendar)

        XCTAssertEqual(
            TripAlbumDateGrouping.accessibilityLabel(for: date, calendar: calendar),
            "2026年12月31日 · 周四"
        )
    }

    private func calendar(timeZoneID: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneID)!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }

    private func readyPostcard(at occurredAt: Date) -> TripEvent {
        TripEvent(
            id: UUID(),
            tripID: UUID(),
            previousEventID: nil,
            occurredAt: occurredAt,
            phase: .postcardReady,
            location: Location(country: "中国", city: "上海", place: "外滩"),
            transport: nil,
            summary: "明信片已抵达。",
            mood: Mood(level: 2, label: "轻快", quote: "慢慢走。"),
            continuityReferences: [],
            openHook: nil,
            consumedItemID: nil,
            postcardStatus: .ready,
            postcardRelativePath: "postcards/trip/card.webp"
        )
    }
}
