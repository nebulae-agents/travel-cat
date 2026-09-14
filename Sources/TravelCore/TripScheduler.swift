import Foundation

public enum TravelMode: String, Codable, Sendable {
    case daily
    case fast
}

public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    public mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

public struct TripScheduler: Sendable {
    public let mode: TravelMode

    public init(mode: TravelMode) {
        self.mode = mode
    }

    public func shouldCheck(now _: Date) -> Bool {
        true
    }

    public func isDue(snapshot: TripSnapshot, now: Date) -> Bool {
        shouldCheck(now: now) && snapshot.nextActionAt <= now
    }

    public func nextDeparture(after date: Date, seed: UInt64, calendar: Calendar) -> Date {
        guard mode == .daily else {
            return date.addingTimeInterval(120)
        }

        var generator = SeededGenerator(seed: seed)
        let randomValue = generator.next()
        let todayWindow = dailyWindow(containing: date, calendar: calendar)
        let todayCandidate = departure(in: todayWindow, randomValue: randomValue)

        if todayCandidate > date {
            return todayCandidate
        }

        let nextDay = calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: date)
        )!
        let nextWindow = dailyWindow(containing: nextDay, calendar: calendar)
        return departure(in: nextWindow, randomValue: randomValue)
    }

    private func dailyWindow(containing date: Date, calendar: Calendar) -> DateInterval {
        var components = calendar.dateComponents([.era, .year, .month, .day], from: date)
        components.timeZone = calendar.timeZone
        components.minute = 0
        components.second = 0
        components.nanosecond = 0

        components.hour = 8
        let start = calendar.date(from: components)!
        components.hour = 20
        let end = calendar.date(from: components)!
        return DateInterval(start: start, end: end)
    }

    private func departure(in window: DateInterval, randomValue: UInt64) -> Date {
        let elapsedSeconds = UInt64(window.duration.rounded(.down))
        let offset = TimeInterval(randomValue % elapsedSeconds)
        return window.start.addingTimeInterval(offset)
    }
}
