import Foundation
@testable import TravelCore

extension TripSnapshot {
    static func fixture(
        moodLevel: Int = 0,
        usedItemIDs: Set<String> = [],
        lastEventID: UUID? = nil,
        visitedPlaces: [String] = [],
        nextActionAt: Date = Date(timeIntervalSince1970: 0)
    ) -> TripSnapshot {
        TripSnapshot(
            stateVersion: lastEventID == nil ? 0 : 1,
            tripID: UUID(uuidString: "00000000-0000-0000-0000-000000000001"),
            lastEventID: lastEventID,
            phase: .exploring,
            nextActionAt: nextActionAt,
            lastUpdatedAt: Date(timeIntervalSince1970: 0),
            usedItemIDs: usedItemIDs,
            visitedPlaces: visitedPlaces,
            mood: Mood(level: moodLevel, label: "curious", quote: "Onward.")
        )
    }
}

extension TripEvent {
    static func fixture(
        moodLevel: Int = 0,
        consumedItemID: String? = nil,
        references: [String] = ["previous-event"],
        place: String? = "Great Buddha"
    ) -> TripEvent {
        TripEvent(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            tripID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            previousEventID: UUID(uuidString: "00000000-0000-0000-0000-000000000002"),
            occurredAt: Date(timeIntervalSince1970: 1),
            phase: .exploring,
            location: place.map { Location(country: "Japan", city: "Kamakura", place: $0) },
            transport: "walking",
            summary: "Exploring Kamakura.",
            mood: Mood(level: moodLevel, label: "curious", quote: "Onward."),
            continuityReferences: references,
            openHook: nil,
            consumedItemID: consumedItemID,
            postcardStatus: .none,
            postcardRelativePath: nil
        )
    }
}
