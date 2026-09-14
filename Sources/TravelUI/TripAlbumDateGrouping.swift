import Foundation
import TravelCore

public struct TripAlbumDateGroup: Identifiable, Equatable, Sendable {
    public let day: Date
    public let events: [TripEvent]

    public var id: Date { day }

    public init(day: Date, events: [TripEvent]) {
        self.day = day
        self.events = events
    }
}

public enum TripAlbumDateGrouping {
    public static func groups(
        orderedEvents: [TripEvent],
        calendar: Calendar
    ) -> [TripAlbumDateGroup] {
        var result: [TripAlbumDateGroup] = []

        for event in orderedEvents {
            let day = calendar.startOfDay(for: event.occurredAt)
            if let lastGroup = result.last, lastGroup.day == day {
                result[result.count - 1] = TripAlbumDateGroup(
                    day: lastGroup.day,
                    events: lastGroup.events + [event]
                )
            } else {
                result.append(TripAlbumDateGroup(day: day, events: [event]))
            }
        }

        return result
    }

    public static func spansMultipleYears(days: [Date], calendar: Calendar) -> Bool {
        Set(days.map { calendar.component(.year, from: $0) }).count > 1
    }

    public static func visibleLabel(for day: Date, showsYear: Bool, calendar: Calendar) -> String {
        guard let components = components(for: day, calendar: calendar) else {
            return fallbackLabel(for: day, includesYear: showsYear, calendar: calendar)
        }

        let dateLabel: String
        if showsYear {
            dateLabel = "\(components.year)年\(components.month)月\(components.day)日"
        } else {
            dateLabel = "\(components.month)月\(components.day)日"
        }
        return "\(dateLabel) · \(weekdayLabel(for: components.weekday))"
    }

    public static func accessibilityLabel(for day: Date, calendar: Calendar) -> String {
        guard let components = components(for: day, calendar: calendar) else {
            return fallbackLabel(for: day, includesYear: true, calendar: calendar)
        }

        return "\(components.year)年\(components.month)月\(components.day)日 · \(weekdayLabel(for: components.weekday))"
    }

    private static func components(for day: Date, calendar: Calendar) -> DateParts? {
        let components = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
        guard
            let year = components.year,
            let month = components.month,
            let day = components.day,
            let weekday = components.weekday,
            (1...7).contains(weekday)
        else {
            return nil
        }
        return DateParts(year: year, month: month, day: day, weekday: weekday)
    }

    private static func weekdayLabel(for weekday: Int) -> String {
        ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][weekday - 1]
    }

    private static func fallbackLabel(for day: Date, includesYear: Bool, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = includesYear ? "y年M月d日 EEEE" : "M月d日 EEEE"
        return formatter.string(from: day)
    }

    private struct DateParts {
        let year: Int
        let month: Int
        let day: Int
        let weekday: Int
    }
}
