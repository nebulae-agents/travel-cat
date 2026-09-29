import CryptoKit
import Foundation
import TravelCore

/// A durable itinerary, not a second journal. Bindings and completion are rebuilt from
/// published events on every wake, including after publication outlives a state write.
struct TripPostcardPlan: Codable, Equatable {
    struct Slot: Codable, Equatable {
        let id: UUID
        var eventID: UUID?
        var imageReady: Bool
    }

    let tripID: UUID
    var slots: [Slot]
    var catchingUp = false
    var nextCatchUpAt: Date?

    init(tripID: UUID) {
        self.tripID = tripID
        slots = (0..<Self.target(for: tripID)).map {
            Slot(id: Self.slotID(tripID: tripID, index: $0), eventID: nil, imageReady: false)
        }
    }

    static func target(for tripID: UUID) -> Int { 1 + Int(tripID.uuid.0 % 3) }

    private static func slotID(tripID: UUID, index: Int) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("travel-cat/postcard/\(tripID.uuidString.lowercased())/\(index)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    mutating func reconcile(events: [TripEvent]) {
        let postcards = events.filter { $0.tripID == tripID && $0.phase == .postcardReady }
        // Keep every already-published postcard, even if a legacy writer exceeded the target.
        while slots.count < postcards.count {
            slots.append(Slot(id: Self.slotID(tripID: tripID, index: slots.count), eventID: nil, imageReady: false))
        }
        var remaining = postcards
        for index in slots.indices {
            slots[index].eventID = nil
            slots[index].imageReady = false
            if let match = remaining.firstIndex(where: { $0.id == slots[index].id }) {
                let event = remaining.remove(at: match)
                slots[index].eventID = event.id
                slots[index].imageReady = event.postcardStatus == .ready
            }
        }
        for index in slots.indices where slots[index].eventID == nil {
            guard !remaining.isEmpty else { break }
            let event = remaining.removeFirst()
            slots[index].eventID = event.id
            slots[index].imageReady = event.postcardStatus == .ready
        }
    }

    var nextEventID: UUID? { slots.first { $0.eventID == nil }?.id }
    var unpublishedCount: Int { slots.filter { $0.eventID == nil }.count }
    var remainingImageCount: Int { slots.filter { !$0.imageReady }.count }
}
