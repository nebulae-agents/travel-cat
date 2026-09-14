import Foundation

public enum TravelPhase: String, Codable, CaseIterable, Sendable {
    case resting = "resting"
    case preparing = "preparing"
    case transit = "transit"
    case exploring = "exploring"
    case postcardReady = "postcardReady"
    case returning = "returning"
}

public struct Mood: Codable, Equatable, Sendable {
    public var level: Int
    public var label: String
    public var quote: String

    public init(level: Int, label: String, quote: String) {
        self.level = level
        self.label = label
        self.quote = quote
    }

    private enum CodingKeys: String, CodingKey {
        case level
        case label
        case quote
    }
}

public struct Location: Codable, Equatable, Sendable {
    public var country: String
    public var city: String
    public var place: String

    public init(country: String, city: String, place: String) {
        self.country = country
        self.city = city
        self.place = place
    }

    private enum CodingKeys: String, CodingKey {
        case country
        case city
        case place
    }
}

public enum PostcardStatus: String, Codable, Sendable {
    case none = "none"
    case pendingImage = "pendingImage"
    case ready = "ready"
    case imageUnavailable = "imageUnavailable"
    case rejected = "rejected"
}

public struct TripEvent: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let tripID: UUID
    public let previousEventID: UUID?
    public let occurredAt: Date
    public let phase: TravelPhase
    public let location: Location?
    public let transport: String?
    public let summary: String
    public let mood: Mood
    public let continuityReferences: [String]
    public let openHook: String?
    public let consumedItemID: String?
    public var postcardStatus: PostcardStatus
    public var postcardRelativePath: String?
    /// Frozen journey identity. Present only on the first preparing event of new-format trips.
    public let characterProfile: CharacterProfile?

    public init(
        id: UUID,
        tripID: UUID,
        previousEventID: UUID?,
        occurredAt: Date,
        phase: TravelPhase,
        location: Location?,
        transport: String?,
        summary: String,
        mood: Mood,
        continuityReferences: [String],
        openHook: String?,
        consumedItemID: String?,
        postcardStatus: PostcardStatus,
        postcardRelativePath: String?
    ) {
        self.init(id: id, tripID: tripID, previousEventID: previousEventID, occurredAt: occurredAt,
                  phase: phase, location: location, transport: transport, summary: summary, mood: mood,
                  continuityReferences: continuityReferences, openHook: openHook, consumedItemID: consumedItemID,
                  postcardStatus: postcardStatus, postcardRelativePath: postcardRelativePath, characterProfile: nil)
    }

    public init(
        id: UUID, tripID: UUID, previousEventID: UUID?, occurredAt: Date, phase: TravelPhase,
        location: Location?, transport: String?, summary: String, mood: Mood,
        continuityReferences: [String], openHook: String?, consumedItemID: String?,
        postcardStatus: PostcardStatus, postcardRelativePath: String?, characterProfile: CharacterProfile?
    ) {
        self.id = id
        self.tripID = tripID
        self.previousEventID = previousEventID
        self.occurredAt = occurredAt
        self.phase = phase
        self.location = location
        self.transport = transport
        self.summary = summary
        self.mood = mood
        self.continuityReferences = continuityReferences
        self.openHook = openHook
        self.consumedItemID = consumedItemID
        self.postcardStatus = postcardStatus
        self.postcardRelativePath = postcardRelativePath
        self.characterProfile = characterProfile
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case tripID
        case previousEventID
        case occurredAt
        case phase
        case location
        case transport
        case summary
        case mood
        case continuityReferences
        case openHook
        case consumedItemID
        case postcardStatus
        case postcardRelativePath
        case characterProfile
    }
}

public struct TripSnapshot: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var stateVersion: Int
    public var tripID: UUID?
    public var lastEventID: UUID?
    public var phase: TravelPhase
    public var nextActionAt: Date
    public var lastUpdatedAt: Date
    public var carriedItemID: String?
    public var usedItemIDs: Set<String>
    public var visitedPlaces: [String]
    public var mood: Mood
    public var openHook: String?

    public init(
        schemaVersion: Int = 1,
        stateVersion: Int,
        tripID: UUID? = nil,
        lastEventID: UUID? = nil,
        phase: TravelPhase,
        nextActionAt: Date,
        lastUpdatedAt: Date,
        carriedItemID: String? = nil,
        usedItemIDs: Set<String>,
        visitedPlaces: [String],
        mood: Mood,
        openHook: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.stateVersion = stateVersion
        self.tripID = tripID
        self.lastEventID = lastEventID
        self.phase = phase
        self.nextActionAt = nextActionAt
        self.lastUpdatedAt = lastUpdatedAt
        self.carriedItemID = carriedItemID
        self.usedItemIDs = usedItemIDs
        self.visitedPlaces = visitedPlaces
        self.mood = mood
        self.openHook = openHook
    }

    public static func empty(now: Date) -> TripSnapshot {
        TripSnapshot(
            stateVersion: 0,
            phase: .resting,
            nextActionAt: now,
            lastUpdatedAt: now,
            usedItemIDs: [],
            visitedPlaces: [],
            mood: Mood(level: 0, label: "平静", quote: "今天适合慢一点。")
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case stateVersion
        case tripID
        case lastEventID
        case phase
        case nextActionAt
        case lastUpdatedAt
        case carriedItemID
        case usedItemIDs
        case visitedPlaces
        case mood
        case openHook
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        stateVersion = try container.decode(Int.self, forKey: .stateVersion)
        tripID = try container.decodeIfPresent(UUID.self, forKey: .tripID)
        lastEventID = try container.decodeIfPresent(UUID.self, forKey: .lastEventID)
        phase = try container.decode(TravelPhase.self, forKey: .phase)
        nextActionAt = try container.decode(Date.self, forKey: .nextActionAt)
        lastUpdatedAt = try container.decode(Date.self, forKey: .lastUpdatedAt)
        carriedItemID = try container.decodeIfPresent(String.self, forKey: .carriedItemID)
        usedItemIDs = Set(try container.decode([String].self, forKey: .usedItemIDs))
        visitedPlaces = try container.decode([String].self, forKey: .visitedPlaces)
        mood = try container.decode(Mood.self, forKey: .mood)
        openHook = try container.decodeIfPresent(String.self, forKey: .openHook)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(stateVersion, forKey: .stateVersion)
        try container.encodeIfPresent(tripID, forKey: .tripID)
        try container.encodeIfPresent(lastEventID, forKey: .lastEventID)
        try container.encode(phase, forKey: .phase)
        try container.encode(nextActionAt, forKey: .nextActionAt)
        try container.encode(lastUpdatedAt, forKey: .lastUpdatedAt)
        try container.encodeIfPresent(carriedItemID, forKey: .carriedItemID)
        try container.encode(usedItemIDs.sorted(), forKey: .usedItemIDs)
        try container.encode(visitedPlaces, forKey: .visitedPlaces)
        try container.encode(mood, forKey: .mood)
        try container.encodeIfPresent(openHook, forKey: .openHook)
    }
}

public extension JSONEncoder {
    static var travelCat: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(TravelCatDateCoding.string(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

public extension JSONDecoder {
    static var travelCat: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)

            if let date = TravelCatDateCoding.date(from: value) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected an ISO 8601 timestamp, received \(value)."
            )
        }
        return decoder
    }
}

private enum TravelCatDateCoding {
    static func string(from date: Date) -> String {
        let seconds = date.timeIntervalSince1970
        let wholeSeconds = floor(seconds)
        let wholeDate = Date(timeIntervalSince1970: wholeSeconds)
        let prefix = wholeDate.formatted(Date.ISO8601FormatStyle())
        let fractionalSeconds = seconds - wholeSeconds
        let fraction = String(
            format: "%.17f",
            locale: Locale(identifier: "en_US_POSIX"),
            fractionalSeconds
        )

        return String(prefix.dropLast()) + String(fraction.dropFirst()) + "Z"
    }

    static func date(from value: String) -> Date? {
        if let decimalIndex = value.lastIndex(of: "."), value.hasSuffix("Z") {
            let fractionStart = value.index(after: decimalIndex)
            let fractionEnd = value.index(before: value.endIndex)
            let fraction = value[fractionStart..<fractionEnd]
            let wholeSecondValue = String(value[..<decimalIndex]) + "Z"

            if !fraction.isEmpty,
               fraction.allSatisfy(\.isNumber),
               let wholeSecondDate = try? Date.ISO8601FormatStyle().parse(wholeSecondValue),
               let fractionalSeconds = Double("0." + fraction)
            {
                return Date(timeIntervalSince1970: wholeSecondDate.timeIntervalSince1970 + fractionalSeconds)
            }
        }

        return try? Date.ISO8601FormatStyle().parse(value)
    }
}
