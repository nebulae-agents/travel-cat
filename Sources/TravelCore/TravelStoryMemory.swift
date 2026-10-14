import Foundation

/// A bounded projection of published history. It cannot add facts or alter old events.
public struct TravelStoryMemory: Codable, Equatable, Sendable {
    public struct Journey: Codable, Equatable, Sendable {
        public let tripID: UUID
        public let sourceEventIDs: [UUID]
        public let destination: Location?
        public let observation: String
        public let usedSupplyIDs: [String]
    }
    public let completedJourneys: [Journey]

    public init(events: [TripEvent], excludingTripID: UUID?, now: Date) {
        let arrived = events.filter { $0.occurredAt <= now && $0.tripID != excludingTripID }
        let groups = Dictionary(grouping: arrived, by: \.tripID)
        let completed = groups.values.filter { $0.contains { $0.phase == .resting } }
            .sorted {
                let a = $0.map(\.occurredAt).max() ?? .distantPast
                let b = $1.map(\.occurredAt).max() ?? .distantPast
                if a != b { return a > b }
                return $0[0].tripID.uuidString < $1[0].tripID.uuidString
            }
        completedJourneys = completed.prefix(6).map { entries in
            let ordered = entries.sorted {
                if $0.occurredAt != $1.occurredAt { return $0.occurredAt < $1.occurredAt }
                return $0.id.uuidString < $1.id.uuidString
            }
            let observation = ordered.last { [.exploring, .postcardReady].contains($0.phase) } ?? ordered.last!
            let supplies = Array(Set(ordered.compactMap(\.consumedItemID))).sorted().prefix(5)
            var sourceIDs: Set<UUID> = [observation.id, ordered.last { $0.phase == .resting }!.id]
            for item in supplies {
                if let source = ordered.last(where: { $0.consumedItemID == item }) { sourceIDs.insert(source.id) }
            }
            for source in ordered.reversed() where sourceIDs.count < 12 { sourceIDs.insert(source.id) }
            return Journey(tripID: observation.tripID,
                           sourceEventIDs: ordered.filter { sourceIDs.contains($0.id) }.map(\.id),
                           destination: observation.location,
                           observation: String(observation.summary.unicodeScalars.prefix(160)),
                           usedSupplyIDs: Array(supplies))
        }
    }
}
