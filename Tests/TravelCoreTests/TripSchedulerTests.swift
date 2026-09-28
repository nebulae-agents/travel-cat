import Foundation
import XCTest
@testable import TravelCore

final class TripSchedulerTests: XCTestCase {
    func testCallerControlsCheckCadenceForBothModes() {
        let exactTenMinute = Date(timeIntervalSince1970: 600)
        let followingMinute = Date(timeIntervalSince1970: 660)

        XCTAssertTrue(TripScheduler(mode: .daily).shouldCheck(now: exactTenMinute))
        XCTAssertTrue(TripScheduler(mode: .daily).shouldCheck(now: followingMinute))
        XCTAssertTrue(TripScheduler(mode: .fast).shouldCheck(now: exactTenMinute))
        XCTAssertTrue(TripScheduler(mode: .fast).shouldCheck(now: followingMinute))
    }

    func testDailyCheckToleratesDelayedAndPreEpochInvocations() {
        XCTAssertTrue(TripScheduler(mode: .daily).shouldCheck(now: Date(timeIntervalSince1970: -0.5)))
        XCTAssertTrue(TripScheduler(mode: .daily).shouldCheck(now: Date(timeIntervalSince1970: -600)))
    }

    func testIsDueRequiresReachedActionTimeIndependentOfInvocationMinute() {
        let due = TripSnapshot.fixture(nextActionAt: Date(timeIntervalSince1970: 599))
        let dueExactlyNow = TripSnapshot.fixture(nextActionAt: Date(timeIntervalSince1970: 600))
        let future = TripSnapshot.fixture(nextActionAt: Date(timeIntervalSince1970: 601))
        let daily = TripScheduler(mode: .daily)

        XCTAssertTrue(daily.isDue(snapshot: due, now: Date(timeIntervalSince1970: 600)))
        XCTAssertTrue(daily.isDue(snapshot: dueExactlyNow, now: Date(timeIntervalSince1970: 600)))
        XCTAssertFalse(daily.isDue(snapshot: future, now: Date(timeIntervalSince1970: 600)))
        XCTAssertTrue(daily.isDue(snapshot: due, now: Date(timeIntervalSince1970: 660)))
    }

    func testDailyDepartureUsesSameDayCandidateWhenItIsStillInFuture() throws {
        let calendar = tokyoCalendar()
        let input = try localDate(year: 2026, month: 8, day: 10, hour: 9, minute: 30, calendar: calendar)
        let scheduler = TripScheduler(mode: .daily)

        let first = scheduler.nextDeparture(after: input, seed: 42, calendar: calendar)
        let repeated = scheduler.nextDeparture(after: input, seed: 42, calendar: calendar)
        let differentSeed = scheduler.nextDeparture(after: input, seed: 43, calendar: calendar)
        let expected = try localDate(
            year: 2026,
            month: 8,
            day: 10,
            hour: 10,
            minute: 9,
            second: 53,
            calendar: calendar
        )
        let windowEnd = try localDate(year: 2026, month: 8, day: 10, hour: 20, calendar: calendar)

        XCTAssertEqual(first, expected)
        XCTAssertLessThan(first, windowEnd)
        XCTAssertGreaterThan(first, input)
        XCTAssertEqual(first, repeated)
        XCTAssertNotEqual(first, differentSeed)
    }

    func testDailyDepartureRollsSameOffsetToNextDayWhenCandidateHasPassed() throws {
        let calendar = tokyoCalendar()
        let input = try localDate(year: 2026, month: 8, day: 10, hour: 11, calendar: calendar)
        let departure = TripScheduler(mode: .daily).nextDeparture(after: input, seed: 42, calendar: calendar)
        let expected = try localDate(
            year: 2026,
            month: 8,
            day: 11,
            hour: 10,
            minute: 9,
            second: 53,
            calendar: calendar
        )

        XCTAssertEqual(departure, expected)
    }

    func testDailyDepartureBeforeWindowUsesTodayAndRemainsInFuture() throws {
        let calendar = tokyoCalendar()
        let input = try localDate(year: 2026, month: 8, day: 10, hour: 7, minute: 30, calendar: calendar)
        let departure = TripScheduler(mode: .daily).nextDeparture(after: input, seed: 0, calendar: calendar)
        let windowStart = try localDate(year: 2026, month: 8, day: 10, hour: 8, calendar: calendar)
        let windowEnd = try localDate(year: 2026, month: 8, day: 10, hour: 20, calendar: calendar)

        XCTAssertGreaterThanOrEqual(departure, windowStart)
        XCTAssertLessThan(departure, windowEnd)
        XCTAssertGreaterThan(departure, input)
    }

    func testDailyDeparturePreservesLocalWindowOnSpringForwardDay() throws {
        try assertDSTDeparture(year: 2026, month: 3, day: 8)
    }

    func testDailyDeparturePreservesLocalWindowOnFallBackDay() throws {
        try assertDSTDeparture(year: 2026, month: 11, day: 1)
    }

    func testFastDepartureIsExactlyTwoMinutesLater() {
        let input = Date(timeIntervalSince1970: 1_786_339_200)

        XCTAssertEqual(
            TripScheduler(mode: .fast).nextDeparture(after: input, seed: 42, calendar: tokyoCalendar()),
            input.addingTimeInterval(120)
        )
    }

    func testSeededGeneratorUsesSpecifiedLCGAndZeroSeedSubstitution() {
        var zero = SeededGenerator(seed: 0)
        var substituted = SeededGenerator(seed: 0x9E3779B97F4A7C15)
        var one = SeededGenerator(seed: 1)

        XCTAssertEqual(zero.next(), substituted.next())
        XCTAssertEqual(one.next(), 1 &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407)
    }

    func testDailyPhaseIntervalsAreDeterministicAndBounded() {
        let input = Date(timeIntervalSince1970: 1_786_339_200)
        let scheduler = TripScheduler(mode: .daily)
        let ranges: [(TravelPhase, ClosedRange<TimeInterval>)] = [
            (.preparing, 900...2700), (.transit, 3600...10800),
            (.returning, 3600...10800), (.exploring, 14400...21600),
            (.postcardReady, 14400...21600)
        ]
        for (phase, range) in ranges {
            for seed in [UInt64(0), 1, 42, 43, UInt64.max] {
                let first = scheduler.nextAction(after: input, phase: phase, seed: seed, calendar: tokyoCalendar())
                XCTAssertTrue(range.contains(first.timeIntervalSince(input)), "\(phase), seed \(seed)")
                XCTAssertEqual(first, scheduler.nextAction(after: input, phase: phase, seed: seed, calendar: tokyoCalendar()))
            }
            XCTAssertNotEqual(
                scheduler.nextAction(after: input, phase: phase, seed: 42, calendar: tokyoCalendar()),
                scheduler.nextAction(after: input, phase: phase, seed: 43, calendar: tokyoCalendar())
            )
        }
    }

    func testDailyPhaseIntervalsHaveStableSeedFortyTwoValues() {
        let input = Date(timeIntervalSince1970: 1_786_339_200)
        for (phase, seconds) in [(TravelPhase.preparing, 1950), (.transit, 6406), (.returning, 6406), (.exploring, 17206), (.postcardReady, 17206)] {
            XCTAssertEqual(
                TripScheduler(mode: .daily).nextAction(after: input, phase: phase, seed: 42, calendar: tokyoCalendar()),
                input.addingTimeInterval(TimeInterval(seconds))
            )
        }
    }

    func testFastEveryPhaseIsExactlyTwoMinutesLater() {
        let input = Date(timeIntervalSince1970: 1_786_339_200)
        for phase in TravelPhase.allCases {
            XCTAssertEqual(
                TripScheduler(mode: .fast).nextAction(after: input, phase: phase, seed: 42, calendar: tokyoCalendar()),
                input.addingTimeInterval(120)
            )
        }
    }

    func testDailyRestRequiresTwelveHoursAndANewLocalDay() throws {
        let calendar = tokyoCalendar()
        for hour in [0, 7, 12, 19, 23] {
            let returned = try localDate(year: 2026, month: 8, day: 10, hour: hour, calendar: calendar)
            for seed in [UInt64(0), 1, 42, 43, UInt64.max] {
                let next = TripScheduler(mode: .daily).nextAction(after: returned, phase: .resting, seed: seed, calendar: calendar)
                XCTAssertGreaterThanOrEqual(next.timeIntervalSince(returned), 12 * 3600)
                XCTAssertFalse(calendar.isDate(next, inSameDayAs: returned))
                XCTAssertTrue((8..<20).contains(calendar.component(.hour, from: next)))
            }
        }
    }

    func testDailyRestPreservesElapsedRestAndLocalWindowAcrossBothDSTChanges() throws {
        let calendar = losAngelesCalendar()
        for (month, day) in [(3, 7), (10, 31)] {
            let returned = try localDate(year: 2026, month: month, day: day, hour: 23, calendar: calendar)
            for seed in [UInt64(0), 42, 43] {
                let next = TripScheduler(mode: .daily).nextAction(after: returned, phase: .resting, seed: seed, calendar: calendar)
                XCTAssertGreaterThanOrEqual(next.timeIntervalSince(returned), 12 * 3600)
                XCTAssertTrue((8..<20).contains(calendar.component(.hour, from: next)))
                XCTAssertEqual(next, TripScheduler(mode: .daily).nextAction(after: returned, phase: .resting, seed: seed, calendar: calendar))
            }
            for phase in [TravelPhase.preparing, .transit, .exploring, .postcardReady, .returning] {
                let next = TripScheduler(mode: .daily).nextAction(after: returned, phase: phase, seed: 42, calendar: calendar)
                let utc = Calendar(identifier: .gregorian)
                XCTAssertEqual(next, TripScheduler(mode: .daily).nextAction(after: returned, phase: phase, seed: 42, calendar: utc))
            }
        }
    }

    private func tokyoCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }

    private func losAngelesCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    private func assertDSTDeparture(year: Int, month: Int, day: Int) throws {
        let calendar = losAngelesCalendar()
        let input = try localDate(
            year: year,
            month: month,
            day: day,
            hour: 7,
            minute: 30,
            calendar: calendar
        )
        let windowStart = try localDate(
            year: year,
            month: month,
            day: day,
            hour: 8,
            calendar: calendar
        )
        let windowEnd = try localDate(
            year: year,
            month: month,
            day: day,
            hour: 20,
            calendar: calendar
        )
        let expected = try localDate(
            year: year,
            month: month,
            day: day,
            hour: 10,
            minute: 9,
            second: 53,
            calendar: calendar
        )
        let scheduler = TripScheduler(mode: .daily)
        let departure = scheduler.nextDeparture(after: input, seed: 42, calendar: calendar)

        XCTAssertEqual(departure, expected)
        XCTAssertGreaterThanOrEqual(departure, windowStart)
        XCTAssertLessThan(departure, windowEnd)
        XCTAssertGreaterThan(departure, input)
        XCTAssertEqual(scheduler.nextDeparture(after: input, seed: 42, calendar: calendar), departure)
        XCTAssertGreaterThanOrEqual(calendar.component(.hour, from: departure), 8)
        XCTAssertLessThan(calendar.component(.hour, from: departure), 20)
    }

    private func localDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int = 0,
        second: Int = 0,
        calendar: Calendar
    ) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        )))
    }
}
