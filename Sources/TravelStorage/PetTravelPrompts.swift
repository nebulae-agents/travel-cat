import Foundation
import TravelCore

public enum PetTravelPrompt: Codable, Equatable, Sendable {
    case departed(eventID: UUID, tripID: UUID, location: Location?, summary: String)
    case postcardReady(eventID: UUID, tripID: UUID, location: Location?, mood: String, quote: String)
    case returned(eventID: UUID, tripID: UUID, mood: String)

    public var identifier: String {
        switch self {
        case let .departed(eventID, _, _, _):
            "pet-departed-\(eventID.uuidString.lowercased())"
        case let .postcardReady(eventID, _, _, _, _):
            "pet-postcard-\(eventID.uuidString.lowercased())"
        case let .returned(eventID, tripID, _):
            "pet-returned-\(tripID.uuidString.lowercased())-\(eventID.uuidString.lowercased())"
        }
    }
}

public enum PetTravelPromptDetector {
    public static func detect(
        previous: RepositoryContents,
        current: RepositoryContents
    ) -> [PetTravelPrompt] {
        let previousIDs = Set(previous.events.map(\.id))
        let previousReadyIDs = Set(
            previous.events.compactMap { event in
                event.postcardStatus == .ready ? event.id : nil
            }
        )
        var currentIDCounts: [UUID: Int] = [:]
        for event in current.events {
            currentIDCounts[event.id, default: 0] += 1
        }
        let duplicateCurrentIDs = Set(
            currentIDCounts.compactMap { id, count in
                count > 1 ? id : nil
            }
        )
        var indexedPrompts: [(prompt: PetTravelPrompt, occurredAt: Date, journalIndex: Int, sequence: Int)] = []
        var sequence = 0

        for (journalIndex, event) in current.events.enumerated() {
            guard !duplicateCurrentIDs.contains(event.id) else { continue }
            let isNewEvent = !previousIDs.contains(event.id)
            if isNewEvent {
                if event.phase == .preparing {
                    indexedPrompts.append((
                        .departed(
                            eventID: event.id,
                            tripID: event.tripID,
                            location: event.location,
                            summary: event.summary
                        ),
                        event.occurredAt,
                        journalIndex,
                        sequence
                    ))
                    sequence += 1
                }

                if event.phase == .resting {
                    indexedPrompts.append((
                        .returned(eventID: event.id, tripID: event.tripID, mood: event.mood.label),
                        event.occurredAt,
                        journalIndex,
                        sequence
                    ))
                    sequence += 1
                }

                if event.postcardStatus == .ready {
                    indexedPrompts.append((
                        .postcardReady(
                            eventID: event.id,
                            tripID: event.tripID,
                            location: event.location,
                            mood: event.mood.label,
                            quote: event.mood.quote
                        ),
                        event.occurredAt,
                        journalIndex,
                        sequence
                    ))
                    sequence += 1
                }
                continue
            }

            if !previousReadyIDs.contains(event.id), event.postcardStatus == .ready {
                indexedPrompts.append((
                    .postcardReady(
                        eventID: event.id,
                        tripID: event.tripID,
                        location: event.location,
                        mood: event.mood.label,
                        quote: event.mood.quote
                    ),
                    event.occurredAt,
                    journalIndex,
                    sequence
                ))
                sequence += 1
            }
        }

        return indexedPrompts
            .sorted {
                if $0.occurredAt != $1.occurredAt {
                    return $0.occurredAt < $1.occurredAt
                }
                if $0.journalIndex != $1.journalIndex {
                    return $0.journalIndex < $1.journalIndex
                }
                return $0.sequence < $1.sequence
            }
            .map(\.prompt)
    }
}
