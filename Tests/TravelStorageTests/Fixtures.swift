import Foundation
import TravelCore

extension TripEvent {
    static func fixture(
        id: UUID = UUID(),
        tripID: UUID = UUID(),
        previousEventID: UUID? = nil,
        occurredAt: Date = Date(timeIntervalSince1970: 100),
        phase: TravelPhase = .preparing,
        place: String? = nil,
        consumedItemID: String? = nil,
        postcardStatus: PostcardStatus = .none,
        postcardRelativePath: String? = nil,
        characterProfile: CharacterProfile? = nil
    ) -> Self {
        .init(
            id: id,
            tripID: tripID,
            previousEventID: previousEventID,
            occurredAt: occurredAt,
            phase: phase,
            location: place.map { Location(country: "Japan", city: "Kamakura", place: $0) },
            transport: nil,
            summary: "黑猫把紫色项圈整理好，准备开始这次旅行。",
            mood: .init(level: 1, label: "期待", quote: "想看看风会把我带去哪里。"),
            continuityReferences: ["出发动机"],
            openHook: "寻找慢一点的海边",
            consumedItemID: consumedItemID,
            postcardStatus: postcardStatus,
            postcardRelativePath: postcardRelativePath,
            characterProfile: characterProfile
        )
    }
}

extension TripSnapshot {
    static func fixture(
        stateVersion: Int = 0,
        tripID: UUID? = nil,
        lastEventID: UUID? = nil,
        phase: TravelPhase = .preparing,
        nextActionAt: Date = Date(timeIntervalSince1970: 100),
        lastUpdatedAt: Date = Date(timeIntervalSince1970: 100),
        carriedItemID: String? = nil,
        usedItemIDs: Set<String> = [],
        visitedPlaces: [String] = [],
        mood: Mood = .init(level: 1, label: "期待", quote: "想看看风会把我带去哪里。"),
        openHook: String? = "寻找慢一点的海边"
    ) -> Self {
        .init(
            stateVersion: stateVersion,
            tripID: tripID,
            lastEventID: lastEventID,
            phase: phase,
            nextActionAt: nextActionAt,
            lastUpdatedAt: lastUpdatedAt,
            carriedItemID: carriedItemID,
            usedItemIDs: usedItemIDs,
            visitedPlaces: visitedPlaces,
            mood: mood,
            openHook: openHook
        )
    }
}
