import Foundation
import XCTest
import TravelCore

final class DateCodingTests: XCTestCase {
    func testRoundTripPreservesDatesFinerThanUnixEpochResolution() throws {
        // Date stores seconds from 2001; adding the Unix epoch offset loses a bit
        // at these dates. That bit must survive a journal JSON round trip.
        for base in [814_967_620.0, -1.0] {
            for index in 0..<16 {
                let date = Date(timeIntervalSinceReferenceDate: base + Double(index) * base.ulp)
                let data = try JSONEncoder.travelCat.encode(date)
                let restored = try JSONDecoder.travelCat.decode(Date.self, from: data)
                XCTAssertEqual(restored, date, "base \(base), step \(index)")
            }
        }
    }

    func testTinyNegativeReferenceOffsetDoesNotMoveBackAWholeSecond() throws {
        let date = Date(timeIntervalSinceReferenceDate: -1e-18)
        let restored = try JSONDecoder.travelCat.decode(Date.self, from: JSONEncoder.travelCat.encode(date))
        XCTAssertEqual(restored.timeIntervalSinceReferenceDate, date.timeIntervalSinceReferenceDate, accuracy: 1e-15)
    }

    func testCanonicalLegacyTimestampsKeepTheirWireRepresentation() throws {
        for timestamp in [
            "2026-10-29T09:01:26.83610391616821300Z",
            "2026-10-29T08:22:56.00527286529541016Z",
            "2001-01-01T00:00:00.00000000000000000Z",
            "1970-01-01T00:00:00.50000000000000000Z"
        ] {
            let data = try JSONEncoder().encode(timestamp)
            let date = try JSONDecoder.travelCat.decode(Date.self, from: data)
            let encoded = try JSONEncoder.travelCat.encode(date)
            XCTAssertEqual(try JSONDecoder().decode(String.self, from: encoded), timestamp)
        }
    }

    func testExistingWholeAndShortFractionTimestampsStillDecode() throws {
        for (timestamp, expected) in [
            ("2001-01-01T00:00:00Z", 0.0),
            ("2001-01-01T00:00:00.125Z", 0.125),
            ("2000-12-31T23:59:59.875Z", -0.125)
        ] {
            let date = try JSONDecoder.travelCat.decode(Date.self, from: JSONEncoder().encode(timestamp))
            XCTAssertEqual(date.timeIntervalSinceReferenceDate, expected)
        }
    }
}
