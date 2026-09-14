import Foundation
import XCTest
@testable import TravelCore

final class TravelStateMachineTests: XCTestCase {
    func testPreparingCanEnterTransitButCannotJumpToReturn() {
        let stateMachine = TravelStateMachine()

        XCTAssertNoThrow(try stateMachine.requireTransition(from: .preparing, to: .transit))
        XCTAssertThrowsError(try stateMachine.requireTransition(from: .preparing, to: .returning))
    }

    func testSnapshotRoundTripsWithStableKeys() throws {
        let snapshot = TripSnapshot.empty(now: Date(timeIntervalSince1970: 10))

        let encoded = try JSONEncoder.travelCat.encode(snapshot)
        let decoded = try JSONDecoder.travelCat.decode(TripSnapshot.self, from: encoded)

        XCTAssertEqual(decoded, snapshot)
    }

    func testSnapshotsMoodAndLocationRemainMutable() {
        var snapshot = TripSnapshot.empty(now: Date(timeIntervalSince1970: 10))
        var mood = Mood(level: 0, label: "平静", quote: "今天适合慢一点。")
        var location = Location(country: "中国", city: "杭州", place: "西湖")

        snapshot.carriedItemID = "tea-leaves"
        mood.level = 1
        location.place = "灵隐寺"

        XCTAssertEqual(snapshot.carriedItemID, "tea-leaves")
        XCTAssertEqual(mood.level, 1)
        XCTAssertEqual(location.place, "灵隐寺")
    }

    func testFractionalDatesRoundTripForSnapshotAndEvent() throws {
        let timestamp = Date(timeIntervalSince1970: 10.123456)
        let snapshot = TripSnapshot(
            stateVersion: 4,
            tripID: UUID(uuidString: "00000000-0000-0000-0000-000000000001"),
            lastEventID: UUID(uuidString: "00000000-0000-0000-0000-000000000002"),
            phase: .exploring,
            nextActionAt: timestamp,
            lastUpdatedAt: timestamp,
            carriedItemID: "tea-leaves",
            usedItemIDs: ["b", "a"],
            visitedPlaces: ["West Lake"],
            mood: Mood(level: 2, label: "好奇", quote: "去看看。"),
            openHook: "下一站"
        )
        let event = TripEvent(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            tripID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            previousEventID: UUID(uuidString: "00000000-0000-0000-0000-000000000002"),
            occurredAt: timestamp,
            phase: .postcardReady,
            location: Location(country: "中国", city: "杭州", place: "西湖"),
            transport: "步行",
            summary: "到了湖边。",
            mood: Mood(level: 2, label: "好奇", quote: "去看看。"),
            continuityReferences: ["day-1"],
            openHook: "等一等",
            consumedItemID: "tea-leaves",
            postcardStatus: .imageUnavailable,
            postcardRelativePath: "postcards/1.png"
        )

        let snapshotData = try JSONEncoder.travelCat.encode(snapshot)
        let eventData = try JSONEncoder.travelCat.encode(event)

        XCTAssertEqual(try JSONDecoder.travelCat.decode(TripSnapshot.self, from: snapshotData), snapshot)
        XCTAssertEqual(try JSONDecoder.travelCat.decode(TripEvent.self, from: eventData), event)
    }

    func testDecoderAcceptsLegacyWholeSecondAndMillisecondDates() throws {
        let wholeSecondData = Data("""
        {"schemaVersion":1,"stateVersion":0,"phase":"resting","nextActionAt":"1970-01-01T00:00:10Z","lastUpdatedAt":"1970-01-01T00:00:10Z","usedItemIDs":[],"visitedPlaces":[],"mood":{"level":0,"label":"平静","quote":"今天适合慢一点。"}}
        """.utf8)
        let millisecondData = Data("""
        {"schemaVersion":1,"stateVersion":0,"phase":"resting","nextActionAt":"1970-01-01T00:00:10.125Z","lastUpdatedAt":"1970-01-01T00:00:10.125Z","usedItemIDs":[],"visitedPlaces":[],"mood":{"level":0,"label":"平静","quote":"今天适合慢一点。"}}
        """.utf8)

        let wholeSecondSnapshot = try JSONDecoder.travelCat.decode(TripSnapshot.self, from: wholeSecondData)
        let millisecondSnapshot = try JSONDecoder.travelCat.decode(TripSnapshot.self, from: millisecondData)

        XCTAssertEqual(wholeSecondSnapshot.nextActionAt, Date(timeIntervalSince1970: 10))
        XCTAssertEqual(wholeSecondSnapshot.lastUpdatedAt, Date(timeIntervalSince1970: 10))
        XCTAssertEqual(millisecondSnapshot.nextActionAt, Date(timeIntervalSince1970: 10.125))
        XCTAssertEqual(millisecondSnapshot.lastUpdatedAt, Date(timeIntervalSince1970: 10.125))
    }

    func testGoldenWireFormatUsesStableKeysAndEnumLiterals() throws {
        let snapshot = TripSnapshot(
            schemaVersion: 1,
            stateVersion: 4,
            tripID: UUID(uuidString: "00000000-0000-0000-0000-000000000001"),
            lastEventID: UUID(uuidString: "00000000-0000-0000-0000-000000000002"),
            phase: .postcardReady,
            nextActionAt: Date(timeIntervalSince1970: 10),
            lastUpdatedAt: Date(timeIntervalSince1970: 10),
            carriedItemID: "tea-leaves",
            usedItemIDs: ["z", "a", "m"],
            visitedPlaces: ["West Lake"],
            mood: Mood(level: 2, label: "好奇", quote: "去看看。"),
            openHook: "下一站"
        )
        let event = TripEvent(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            tripID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            previousEventID: UUID(uuidString: "00000000-0000-0000-0000-000000000002"),
            occurredAt: Date(timeIntervalSince1970: 10),
            phase: .postcardReady,
            location: Location(country: "中国", city: "杭州", place: "西湖"),
            transport: "步行",
            summary: "到了湖边。",
            mood: Mood(level: 2, label: "好奇", quote: "去看看。"),
            continuityReferences: ["day-1"],
            openHook: "等一等",
            consumedItemID: "tea-leaves",
            postcardStatus: .imageUnavailable,
            postcardRelativePath: "postcards/1.png"
        )

        let snapshotObject = try decodedObject(for: snapshot)
        let eventObject = try decodedObject(for: event)

        XCTAssertEqual(Set(snapshotObject.keys), ["schemaVersion", "stateVersion", "tripID", "lastEventID", "phase", "nextActionAt", "lastUpdatedAt", "carriedItemID", "usedItemIDs", "visitedPlaces", "mood", "openHook"])
        XCTAssertEqual(snapshotObject["phase"] as? String, "postcardReady")
        XCTAssertEqual(snapshotObject["usedItemIDs"] as? [String], ["a", "m", "z"])
        XCTAssertEqual(Set(eventObject.keys), ["id", "tripID", "previousEventID", "occurredAt", "phase", "location", "transport", "summary", "mood", "continuityReferences", "openHook", "consumedItemID", "postcardStatus", "postcardRelativePath"])
        XCTAssertEqual(eventObject["phase"] as? String, "postcardReady")
        XCTAssertEqual(eventObject["postcardStatus"] as? String, "imageUnavailable")
    }

    func testUsedItemIDsHaveDeterministicSortedWireBytes() throws {
        let snapshot = TripSnapshot(
            stateVersion: 1,
            phase: .resting,
            nextActionAt: Date(timeIntervalSince1970: 10),
            lastUpdatedAt: Date(timeIntervalSince1970: 10),
            usedItemIDs: ["z", "a", "m"],
            visitedPlaces: [],
            mood: Mood(level: 0, label: "平静", quote: "今天适合慢一点。")
        )

        let first = try JSONEncoder.travelCat.encode(snapshot)
        let second = try JSONEncoder.travelCat.encode(snapshot)

        XCTAssertEqual(first, second)
        XCTAssertTrue(try XCTUnwrap(String(data: first, encoding: .utf8)).contains("""
        "usedItemIDs" : [
            "a",
            "m",
            "z"
          ]
        """))
    }

    func testEveryPhasePairMatchesTheAllowedTransitionMatrix() {
        let stateMachine = TravelStateMachine()

        for from in TravelPhase.allCases {
            for to in TravelPhase.allCases {
                do {
                    try stateMachine.requireTransition(from: from, to: to)
                    XCTAssertTrue(isExpectedTransition(from: from, to: to), "Expected \(from) -> \(to) to be rejected")
                } catch {
                    XCTAssertFalse(isExpectedTransition(from: from, to: to), "Expected \(from) -> \(to) to be allowed")
                    XCTAssertEqual(error as? TravelStateMachine.Violation, .illegal(from, to))
                }
            }
        }
    }

    private func decodedObject<T: Encodable>(for value: T) throws -> [String: Any] {
        let data = try JSONEncoder.travelCat.encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func isExpectedTransition(from current: TravelPhase, to next: TravelPhase) -> Bool {
        switch current {
        case .resting:
            next == .preparing
        case .preparing:
            next == .transit || next == .resting
        case .transit:
            next == .exploring || next == .returning
        case .exploring:
            next == .postcardReady || next == .transit || next == .returning
        case .postcardReady:
            next == .exploring || next == .returning
        case .returning:
            next == .resting
        }
    }
}
