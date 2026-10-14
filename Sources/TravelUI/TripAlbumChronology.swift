import Foundation
import TravelCore

/// Album dates are a projection of the original journey, never a rewrite of
/// publication/attempt timestamps. Older supplements have no independent scene date.
public enum TripAlbumChronology {
    public static let unknownDate = Date.distantFuture

    public static func dates(events: [TripEvent], workItems: [PostcardWorkItem]) -> [UUID: Date] {
        let supplements = Set(workItems.filter(\.isSupplement).compactMap(\.eventID))
        let originals = Dictionary(grouping: events.filter { !supplements.contains($0.id) }, by: \.tripID)
        return Dictionary(events.map { event in
            guard supplements.contains(event.id) else { return (event.id, event.occurredAt) }
            let trip = (originals[event.tripID] ?? []).sorted { $0.occurredAt < $1.occurredAt }
            let scenes = trip.filter { $0.phase == .exploring || $0.phase == .postcardReady }
            if let place = event.location?.place, !place.isEmpty,
               let matched = scenes.last(where: { $0.location?.place == place }) {
                return (event.id, matched.occurredAt)
            }
            // Preserve a slot's position relative to the original cards when no
            // exact scene is known. Tie-break toward the preceding original slot.
            let slots = workItems.filter { $0.tripID == event.tripID }
            if let index = slots.firstIndex(where: { $0.eventID == event.id }) {
                let candidates = slots.enumerated().filter { !$0.element.isSupplement && $0.element.eventID != nil }
                    .sorted {
                        let left = abs($0.offset - index), right = abs($1.offset - index)
                        return left == right ? $0.offset < $1.offset : left < right
                    }
                for candidate in candidates {
                    if let anchor = trip.first(where: { $0.id == candidate.element.eventID }) {
                        return (event.id, anchor.occurredAt)
                    }
                }
            }
            let anchor = scenes.last ?? trip.last(where: { $0.phase == .transit }) ?? trip.first
            return (event.id, anchor?.occurredAt ?? unknownDate)
        }, uniquingKeysWith: { first, _ in first })
    }
}
