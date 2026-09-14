import Foundation
import TravelCore

public struct TravelPostcardJournalRecord: Codable, Equatable, Sendable {
    public let eventID: UUID
    public let tripID: UUID
    public let occurredAt: Date
    public let location: Location?
    public let summary: String
    public let mood: Mood
    public let postcardStatus: PostcardStatus
    public let postcardRelativePath: String?

    public init(
        eventID: UUID,
        tripID: UUID,
        occurredAt: Date,
        location: Location?,
        summary: String,
        mood: Mood,
        postcardStatus: PostcardStatus,
        postcardRelativePath: String?
    ) {
        self.eventID = eventID
        self.tripID = tripID
        self.occurredAt = occurredAt
        self.location = location
        self.summary = summary
        self.mood = mood
        self.postcardStatus = postcardStatus
        self.postcardRelativePath = postcardRelativePath
    }
}

public struct TravelJournalView: Codable, Equatable, Sendable {
    public let snapshot: TripSnapshot
    public let currentEvent: TripEvent?
    public let latestReadyPostcard: TravelPostcardJournalRecord?
    public let postcardCount: Int
    public let album: [TravelPostcardJournalRecord]
    public let runtime: TravelRuntimeMetadata?

    public init(
        snapshot: TripSnapshot,
        currentEvent: TripEvent?,
        latestReadyPostcard: TravelPostcardJournalRecord?,
        postcardCount: Int,
        album: [TravelPostcardJournalRecord],
        runtime: TravelRuntimeMetadata? = nil
    ) {
        self.snapshot = snapshot
        self.currentEvent = currentEvent
        self.latestReadyPostcard = latestReadyPostcard
        self.postcardCount = postcardCount
        self.album = album
        self.runtime = runtime
    }

    public func enriched(runtime: TravelRuntimeMetadata) -> Self {
        Self(
            snapshot: snapshot,
            currentEvent: currentEvent,
            latestReadyPostcard: latestReadyPostcard,
            postcardCount: postcardCount,
            album: album,
            runtime: runtime
        )
    }
}

public enum TravelJournalProjection {
    public static func make(
        contents: RepositoryContents,
        albumLimit: Int = 100,
        now: Date
    ) -> TravelJournalView {
        let visibleEvents = contents.events.filter { $0.occurredAt <= now }
        let indexed = visibleEvents.enumerated()
        let postcardEligible = indexed.filter {
            $0.element.postcardStatus == .ready || $0.element.postcardStatus == .imageUnavailable
        }
        let orderedByTimeThenIndex = postcardEligible.sorted {
            if $0.element.occurredAt != $1.element.occurredAt {
                return $0.element.occurredAt < $1.element.occurredAt
            }
            return $0.offset < $1.offset
        }
        let records = orderedByTimeThenIndex.map { record(for: $0.element) }
        let boundedAlbum = Array(records.suffix(max(0, albumLimit)))
        let latestReadyPostcard = orderedByTimeThenIndex
            .last(where: { $0.element.postcardStatus == .ready })
            .map { record(for: $0.element) }

        let currentEvent = visibleEvents.first(where: { $0.id == contents.snapshot.lastEventID })

        return TravelJournalView(
            snapshot: contents.snapshot,
            currentEvent: currentEvent,
            latestReadyPostcard: latestReadyPostcard,
            postcardCount: records.count,
            album: boundedAlbum
        )
    }

    private static func record(for event: TripEvent) -> TravelPostcardJournalRecord {
        TravelPostcardJournalRecord(
            eventID: event.id,
            tripID: event.tripID,
            occurredAt: event.occurredAt,
            location: event.location,
            summary: event.summary,
            mood: event.mood,
            postcardStatus: event.postcardStatus,
            postcardRelativePath: event.postcardRelativePath
        )
    }
}
