import Foundation
import TravelCore

public struct PostcardRequest: Codable, Equatable, Sendable {
    public let required: Bool
    public let scenePrompt: String?

    public init(required: Bool, scenePrompt: String?) {
        self.required = required
        self.scenePrompt = scenePrompt
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case required, scenePrompt }

    public init(from decoder: Decoder) throws {
        try StrictKeys.require(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard values.contains(.scenePrompt) else {
            throw DecodingError.keyNotFound(CodingKeys.scenePrompt, .init(
                codingPath: decoder.codingPath,
                debugDescription: "Missing required nullable scenePrompt"
            ))
        }
        required = try values.decode(Bool.self, forKey: .required)
        scenePrompt = try values.decodeIfPresent(String.self, forKey: .scenePrompt)
    }
}

public enum AgentEnvelopeError: Error, Equatable, Sendable {
    case structural([String])
    case continuity([String])
}

public struct ValidationResult: Codable, Sendable {
    public let valid: Bool
    public let violations: [String]
    public let stateVersion: Int
    public let publishEnvelope: PublishEnvelope?

    public init(valid: Bool, violations: [String], stateVersion: Int, publishEnvelope: PublishEnvelope?) {
        self.valid = valid
        self.violations = violations
        self.stateVersion = stateVersion
        self.publishEnvelope = publishEnvelope
    }

    public enum CodingKeys: String, CodingKey {
        case valid, violations, stateVersion, publishEnvelope
    }
}

public struct AgentEventEnvelope: Codable, Sendable {
    public let eventId: UUID
    public let tripId: UUID
    public let previousEventId: UUID?
    public let occurredAt: Date
    public let phase: TravelPhase
    public let location: Location?
    public let transport: String?
    public let summary: String
    public let mood: Mood
    public let continuityReferences: [String]
    public let openHook: String?
    public let consumedItemId: String?
    public let postcard: PostcardRequest

    public init(
        eventId: UUID,
        tripId: UUID,
        previousEventId: UUID?,
        occurredAt: Date,
        phase: TravelPhase,
        location: Location?,
        transport: String?,
        summary: String,
        mood: Mood,
        continuityReferences: [String],
        openHook: String?,
        consumedItemId: String?,
        postcard: PostcardRequest
    ) {
        self.eventId = eventId
        self.tripId = tripId
        self.previousEventId = previousEventId
        self.occurredAt = occurredAt
        self.phase = phase
        self.location = location
        self.transport = transport
        self.summary = summary
        self.mood = mood
        self.continuityReferences = continuityReferences
        self.openHook = openHook
        self.consumedItemId = consumedItemId
        self.postcard = postcard
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case eventId, tripId, previousEventId, occurredAt, phase, location, transport, summary
        case mood, continuityReferences, openHook, consumedItemId, postcard
    }

    public init(from decoder: Decoder) throws {
        try StrictKeys.require(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard values.contains(.previousEventId) else {
            throw DecodingError.keyNotFound(CodingKeys.previousEventId, .init(
                codingPath: decoder.codingPath,
                debugDescription: "Missing required nullable previousEventId"
            ))
        }
        eventId = try values.decode(UUID.self, forKey: .eventId)
        tripId = try values.decode(UUID.self, forKey: .tripId)
        previousEventId = try values.decodeIfPresent(UUID.self, forKey: .previousEventId)
        let occurredAtText = try values.decode(String.self, forKey: .occurredAt)
        guard let strictDate = StrictRFC3339.date(from: occurredAtText) else {
            throw DecodingError.dataCorruptedError(
                forKey: .occurredAt,
                in: values,
                debugDescription: "occurredAt must be a strict RFC 3339 date-time; leap seconds are unsupported"
            )
        }
        occurredAt = strictDate
        phase = try values.decode(TravelPhase.self, forKey: .phase)
        location = try values.decodeIfPresent(StrictLocation.self, forKey: .location)?.value
        transport = try values.decodeIfPresent(String.self, forKey: .transport)
        summary = try values.decode(String.self, forKey: .summary)
        mood = try values.decode(StrictMood.self, forKey: .mood).value
        continuityReferences = try values.decode([String].self, forKey: .continuityReferences)
        openHook = try values.decodeIfPresent(String.self, forKey: .openHook)
        consumedItemId = try values.decodeIfPresent(String.self, forKey: .consumedItemId)
        postcard = try values.decode(PostcardRequest.self, forKey: .postcard)
        guard Self.fieldsAreStructurallyValid(
            location: location, transport: transport, summary: summary, mood: mood,
            continuityReferences: continuityReferences, openHook: openHook,
            consumedItemId: consumedItemId, postcard: postcard
        ) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Agent event candidate violates structural constraints"
            ))
        }
    }

    public static func decode(_ data: Data) throws -> AgentEventEnvelope {
        guard data.count <= StrictJSONPreflight.maximumBytes else {
            throw AgentEnvelopeError.structural(["tooLarge"])
        }
        do {
            try StrictJSONPreflight.validate(data)
        } catch let failure as JSONPreflightFailure {
            throw AgentEnvelopeError.structural([failure.code])
        } catch {
            throw AgentEnvelopeError.structural(["invalidJSON"])
        }
        let object: StructuralJSONValue
        do {
            object = try JSONDecoder().decode(StructuralJSONValue.self, from: data)
        } catch {
            throw AgentEnvelopeError.structural(["invalidJSON"])
        }
        guard case let .object(root) = object else {
            throw AgentEnvelopeError.structural(["type:root"])
        }
        let violations = StructuralValidator.validate(root)
        guard violations.isEmpty else { throw AgentEnvelopeError.structural(violations) }
        do {
            return try JSONDecoder.travelCat.decode(Self.self, from: data)
        } catch {
            throw AgentEnvelopeError.structural(["decodingFailed"])
        }
    }

    public func validatedProjection(
        previous: TripSnapshot,
        existingEventIDs: Set<UUID> = [],
        mode: TravelMode,
        calendar: Calendar,
        now: Date = Date()
    ) throws -> PublishEnvelope {
        let result = validationResult(
            previous: previous,
            existingEventIDs: existingEventIDs,
            mode: mode,
            calendar: calendar,
            now: now
        )
        guard let publish = result.publishEnvelope else {
            throw AgentEnvelopeError.continuity(result.violations)
        }
        return publish
    }

    public func validationResult(
        previous: TripSnapshot,
        existingEventIDs: Set<UUID> = [],
        mode: TravelMode,
        calendar: Calendar,
        now: Date = Date()
    ) -> ValidationResult {
        let event = TripEvent(
            id: eventId,
            tripID: tripId,
            previousEventID: previousEventId,
            occurredAt: occurredAt,
            phase: phase,
            location: location,
            transport: transport,
            summary: summary,
            mood: mood,
            continuityReferences: continuityReferences,
            openHook: openHook,
            consumedItemID: consumedItemId,
            postcardStatus: postcard.required ? .pendingImage : .none,
            postcardRelativePath: nil
        )
        let startsNewTrip = previous.tripID == nil
            || (previous.phase == .resting && phase == .preparing && previous.tripID != tripId)
        var effectivePrevious = previous
        if startsNewTrip {
            effectivePrevious.usedItemIDs = []
            effectivePrevious.visitedPlaces = []
        }

        var violations: [String] = []
        if eventId == previous.lastEventID || existingEventIDs.contains(eventId) {
            violations.append("duplicateEventID")
        }
        do {
            try TravelStateMachine().requireTransition(from: previous.phase, to: phase)
        } catch {
            violations.append("illegalTransition:\(previous.phase.rawValue)->\(phase.rawValue)")
        }
        if previousEventId != previous.lastEventID { violations.append("previousEventMismatch") }

        if let currentTrip = previous.tripID {
            if previous.phase == .resting, phase == .preparing {
                if tripId == currentTrip { violations.append("newTripRequired") }
            } else if tripId != currentTrip {
                violations.append("tripMismatch")
            }
        } else if phase != .preparing {
            violations.append("tripStartRequiresPreparing")
        }

        if let item = consumedItemId, effectivePrevious.usedItemIDs.contains(item) {
            violations.append("itemAlreadyConsumed:\(item)")
        }
        if let item = consumedItemId, item != previous.carriedItemID {
            violations.append("consumedItemMismatch")
        }
        if phase == .exploring || phase == .postcardReady {
            if location == nil { violations.append("locationRequired:\(phase.rawValue)") }
        } else if (phase == .resting || phase == .preparing), location != nil {
            violations.append("locationForbidden:\(phase.rawValue)")
        }
        if postcard.required != (phase == .postcardReady) {
            violations.append("postcardPhaseMismatch")
        }
        if postcard.required, postcard.scenePrompt == nil || postcard.scenePrompt?.isEmpty == true {
            violations.append("scenePromptRequired")
        }
        if !postcard.required, postcard.scenePrompt != nil {
            violations.append("scenePromptForbidden")
        }
        if occurredAt > now { violations.append("occurredAtAfterNow") }
        if occurredAt < previous.lastUpdatedAt { violations.append("occurredAtBeforeSnapshot") }

        for violation in ContinuityValidator().violations(event: event, previous: effectivePrevious) {
            let code: String
            switch violation {
            case .moodJump: code = "moodJump"
            case let .itemAlreadyConsumed(item): code = "itemAlreadyConsumed:\(item)"
            case .missingAnchorReference: code = "missingAnchorReference"
            case .repeatedPlace: code = "repeatedPlace"
            }
            if !violations.contains(code) { violations.append(code) }
        }

        guard violations.isEmpty else {
            return ValidationResult(valid: false, violations: violations, stateVersion: previous.stateVersion, publishEnvelope: nil)
        }

        var used = effectivePrevious.usedItemIDs
        if let consumedItemId { used.insert(consumedItemId) }
        var visited = effectivePrevious.visitedPlaces
        if let place = location?.place { visited.append(place) }
        let next = TripSnapshot(
            schemaVersion: previous.schemaVersion,
            stateVersion: previous.stateVersion + 1,
            tripID: tripId,
            lastEventID: eventId,
            phase: phase,
            nextActionAt: TripScheduler(mode: mode).nextDeparture(
                after: occurredAt,
                seed: Self.stableSeed(eventId),
                calendar: calendar
            ),
            lastUpdatedAt: occurredAt,
            carriedItemID: consumedItemId == nil ? previous.carriedItemID : nil,
            usedItemIDs: used,
            visitedPlaces: visited,
            mood: mood,
            openHook: openHook
        )
        return ValidationResult(
            valid: true,
            violations: [],
            stateVersion: previous.stateVersion,
            publishEnvelope: PublishEnvelope(event: event, next: next)
        )
    }

    private static func stableSeed(_ id: UUID) -> UInt64 {
        var value = id.uuid
        return withUnsafeBytes(of: &value) { bytes in
            bytes.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        }
    }

    private static func fieldsAreStructurallyValid(
        location: Location?, transport: String?, summary: String, mood: Mood,
        continuityReferences: [String], openHook: String?, consumedItemId: String?,
        postcard: PostcardRequest
    ) -> Bool {
        func valid(_ value: String, min: Int, max: Int? = nil) -> Bool {
            value == value.trimmingCharacters(in: .whitespacesAndNewlines)
                && value.unicodeScalars.count >= min
                && max.map { value.unicodeScalars.count <= $0 } != false
        }
        if let location,
           (!valid(location.country, min: 1) || !valid(location.city, min: 1) || !valid(location.place, min: 1)) {
            return false
        }
        if let transport, !valid(transport, min: 1) { return false }
        guard valid(summary, min: 20, max: 240),
              (-2...2).contains(mood.level), valid(mood.label, min: 1),
              CandidateMoodQuoteText.isStructurallyValid(mood.quote),
              (1...4).contains(continuityReferences.count),
              Set(continuityReferences).count == continuityReferences.count,
              continuityReferences.allSatisfy({ valid($0, min: 1) }) else { return false }
        if let openHook, !valid(openHook, min: 1, max: 120) { return false }
        if let consumedItemId, !valid(consumedItemId, min: 1) { return false }
        if let scenePrompt = postcard.scenePrompt, !valid(scenePrompt, min: 1, max: 500) { return false }
        return true
    }

}

private enum CandidateMoodQuoteText {
    static func isStructurallyValid(_ value: String) -> Bool {
        let count = value.unicodeScalars.count
        return (4...32).contains(count)
            && !hasForbiddenBoundaryWhitespace(value)
            && !containsNewline(value)
    }

    static func hasForbiddenBoundaryWhitespace(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first, let last = value.unicodeScalars.last else { return false }
        return isForbiddenBoundaryWhitespace(first) || isForbiddenBoundaryWhitespace(last)
    }

    static func containsNewline(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.value == 0x0A || $0.value == 0x0D }
    }

    private static func isForbiddenBoundaryWhitespace(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A, 0x0D, 0x20: true
        default: false
        }
    }
}

struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

enum StrictKeys {
    static func require(_ decoder: Decoder, allowed: [String]) throws {
        let values = try decoder.container(keyedBy: AnyCodingKey.self)
        let unknown = Set(values.allKeys.map(\.stringValue)).subtracting(allowed).sorted()
        guard unknown.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown keys: \(unknown.joined(separator: ","))"))
        }
    }

}

private struct StrictLocation: Decodable {
    let value: Location
    private enum CodingKeys: String, CodingKey, CaseIterable { case country, city, place }
    init(from decoder: Decoder) throws {
        try StrictKeys.require(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        value = Location(
            country: try values.decode(String.self, forKey: .country),
            city: try values.decode(String.self, forKey: .city),
            place: try values.decode(String.self, forKey: .place)
        )
    }
}

private struct StrictMood: Decodable {
    let value: Mood
    private enum CodingKeys: String, CodingKey, CaseIterable { case level, label, quote }
    init(from decoder: Decoder) throws {
        try StrictKeys.require(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        value = Mood(
            level: try values.decode(Int.self, forKey: .level),
            label: try values.decode(String.self, forKey: .label),
            quote: try values.decode(String.self, forKey: .quote)
        )
    }
}

private indirect enum StructuralJSONValue: Decodable {
    case object([String: StructuralJSONValue])
    case array([StructuralJSONValue])
    case string(String)
    case number(Double)
    case boolean(Bool)
    case null

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: AnyCodingKey.self) {
            var values: [String: StructuralJSONValue] = [:]
            for key in container.allKeys {
                values[key.stringValue] = try container.decode(Self.self, forKey: key)
            }
            self = .object(values)
            return
        }
        if var container = try? decoder.unkeyedContainer() {
            var values: [StructuralJSONValue] = []
            while !container.isAtEnd {
                values.append(try container.decode(Self.self))
            }
            self = .array(values)
            return
        }

        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }
}

private enum StructuralValidator {
    private static let topKeys: Set<String> = [
        "eventId", "tripId", "previousEventId", "occurredAt", "phase", "location", "transport",
        "summary", "mood", "continuityReferences", "openHook", "consumedItemId", "postcard",
    ]
    private static let required: [String] = [
        "eventId", "tripId", "previousEventId", "occurredAt", "phase", "summary", "mood",
        "continuityReferences", "postcard",
    ]

    static func validate(_ root: [String: StructuralJSONValue]) -> [String] {
        var result = root.keys.filter { !topKeys.contains($0) }.sorted().map { "unknownKey:\($0)" }
        result += required.filter { root[$0] == nil }.map { "missing:\($0)" }
        guard result.isEmpty else { return result }

        uuid(root, "eventId", &result)
        uuid(root, "tripId", &result)
        if case .null? = root["previousEventId"] {} else { uuid(root, "previousEventId", &result) }
        date(root, "occurredAt", &result)
        string(root, "summary", min: 20, max: 240, required: true, &result)
        optionalString(root, "transport", min: 1, max: nil, &result)
        optionalString(root, "openHook", min: 1, max: 120, &result)
        optionalString(root, "consumedItemId", min: 1, max: nil, &result)
        let phases = Set(TravelPhase.allCases.map(\.rawValue))
        if case let .string(phase)? = root["phase"] {
            if !phases.contains(phase) { result.append("invalid:phase") }
        } else { result.append("type:phase") }

        if let location = root["location"], case .null = location {
        } else if let location = root["location"] {
            object(location, path: "location", keys: ["country", "city", "place"], required: ["country", "city", "place"], result: &result) { object, result in
                for key in ["country", "city", "place"] { string(object, key, path: "location.\(key)", min: 1, max: nil, required: true, &result) }
            }
        }
        object(root["mood"], path: "mood", keys: ["level", "label", "quote"], required: ["level", "label", "quote"], result: &result) { mood, result in
            if case let .number(number)? = mood["level"], (-2.0...2.0).contains(number), number.rounded() == number {
            } else { result.append("range:mood.level") }
            string(mood, "label", path: "mood.label", min: 1, max: nil, required: true, &result)
            moodQuote(mood, &result)
        }
        if case let .array(refs)? = root["continuityReferences"] {
            if !(1...4).contains(refs.count) { result.append("length:continuityReferences") }
            var seen = Set<String>()
            for (index, item) in refs.enumerated() {
                guard case let .string(text) = item else { result.append("type:continuityReferences.\(index)"); continue }
                validateText(text, path: "continuityReferences.\(index)", min: 1, max: nil, result: &result)
                if !seen.insert(text).inserted, !result.contains("duplicate:continuityReferences") { result.append("duplicate:continuityReferences") }
            }
        } else { result.append("type:continuityReferences") }
        object(root["postcard"], path: "postcard", keys: ["required", "scenePrompt"], required: ["required", "scenePrompt"], result: &result) { postcard, result in
            if case .boolean? = postcard["required"] {} else { result.append("type:postcard.required") }
            optionalString(postcard, "scenePrompt", path: "postcard.scenePrompt", min: 1, max: 500, &result)
        }
        return result
    }

    private static func uuid(_ object: [String: StructuralJSONValue], _ key: String, _ result: inout [String]) {
        guard case let .string(text)? = object[key], UUID(uuidString: text) != nil else { result.append("invalid:\(key)"); return }
    }

    private static func date(_ object: [String: StructuralJSONValue], _ key: String, _ result: inout [String]) {
        guard case let .string(text)? = object[key], StrictRFC3339.date(from: text) != nil else {
            result.append("invalid:\(key)"); return
        }
    }

    private static func object(
        _ value: StructuralJSONValue?, path: String, keys: Set<String>, required: [String], result: inout [String],
        body: (_ object: [String: StructuralJSONValue], _ result: inout [String]) -> Void
    ) {
        guard case let .object(object)? = value else { result.append("type:\(path)"); return }
        result += object.keys.filter { !keys.contains($0) }.sorted().map { "unknownKey:\(path).\($0)" }
        result += required.filter { object[$0] == nil }.map { "missing:\(path).\($0)" }
        body(object, &result)
    }

    private static func string(
        _ object: [String: StructuralJSONValue], _ key: String, path: String? = nil, min: Int, max: Int?, required: Bool,
        _ result: inout [String]
    ) {
        let path = path ?? key
        guard let value = object[key] else { if required { result.append("missing:\(path)") }; return }
        guard case let .string(text) = value else { result.append("type:\(path)"); return }
        validateText(text, path: path, min: min, max: max, result: &result)
    }

    private static func optionalString(
        _ object: [String: StructuralJSONValue], _ key: String, path: String? = nil, min: Int, max: Int?, _ result: inout [String]
    ) {
        guard let value = object[key] else { return }
        if case .null = value { return }
        guard case let .string(text) = value else { result.append("type:\(path ?? key)"); return }
        validateText(text, path: path ?? key, min: min, max: max, result: &result)
    }

    private static func moodQuote(_ mood: [String: StructuralJSONValue], _ result: inout [String]) {
        guard let value = mood["quote"] else { result.append("missing:mood.quote"); return }
        guard case let .string(quote) = value else { result.append("type:mood.quote"); return }
        if CandidateMoodQuoteText.hasForbiddenBoundaryWhitespace(quote) {
            result.append("untrimmed:mood.quote")
        }
        if !(4...32).contains(quote.unicodeScalars.count) {
            result.append("length:mood.quote")
        }
        if CandidateMoodQuoteText.containsNewline(quote) {
            result.append("newline:mood.quote")
        }
    }

    private static func validateText(_ text: String, path: String, min: Int, max: Int?, result: inout [String]) {
        // Trimming is an intentional contract hardening in addition to schema code-point lengths.
        if text != text.trimmingCharacters(in: .whitespacesAndNewlines) { result.append("untrimmed:\(path)") }
        let length = text.unicodeScalars.count
        if length < min || max.map({ length > $0 }) == true { result.append("length:\(path)") }
    }

}

struct JSONPreflightFailure: Error {
    let code: String
}

struct StrictJSONPreflight {
    static let maximumBytes = 1_048_576
    private static let maximumDepth = 64

    private let bytes: [UInt8]
    private var index = 0

    static func validate(_ data: Data) throws {
        var parser = Self(bytes: Array(data))
        try parser.skipWhitespace()
        try parser.parseValue(depth: 0)
        try parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw JSONPreflightFailure(code: "invalidJSON") }
    }

    private mutating func parseValue(depth: Int) throws {
        guard index < bytes.count else { throw JSONPreflightFailure(code: "invalidJSON") }
        switch bytes[index] {
        case 0x7B: try parseObject(depth: depth + 1)
        case 0x5B: try parseArray(depth: depth + 1)
        case 0x22: _ = try parseString()
        case 0x74: try consumeLiteral([0x74, 0x72, 0x75, 0x65])
        case 0x66: try consumeLiteral([0x66, 0x61, 0x6C, 0x73, 0x65])
        case 0x6E: try consumeLiteral([0x6E, 0x75, 0x6C, 0x6C])
        case 0x2D, 0x30...0x39: try parseNumber()
        default: throw JSONPreflightFailure(code: "invalidJSON")
        }
    }

    private mutating func parseObject(depth: Int) throws {
        guard depth <= Self.maximumDepth else { throw JSONPreflightFailure(code: "tooDeep") }
        index += 1
        try skipWhitespace()
        if consume(0x7D) { return }
        var keys = Set<String>()
        while true {
            try skipWhitespace()
            guard index < bytes.count, bytes[index] == 0x22 else { throw JSONPreflightFailure(code: "invalidJSON") }
            let key = try parseString()
            guard keys.insert(key).inserted else {
                let diagnostic = String(key.unicodeScalars.prefix(64))
                throw JSONPreflightFailure(code: "duplicateKey:\(diagnostic)")
            }
            try skipWhitespace()
            guard consume(0x3A) else { throw JSONPreflightFailure(code: "invalidJSON") }
            try skipWhitespace()
            try parseValue(depth: depth)
            try skipWhitespace()
            if consume(0x7D) { return }
            guard consume(0x2C) else { throw JSONPreflightFailure(code: "invalidJSON") }
        }
    }

    private mutating func parseArray(depth: Int) throws {
        guard depth <= Self.maximumDepth else { throw JSONPreflightFailure(code: "tooDeep") }
        index += 1
        try skipWhitespace()
        if consume(0x5D) { return }
        while true {
            try parseValue(depth: depth)
            try skipWhitespace()
            if consume(0x5D) { return }
            guard consume(0x2C) else { throw JSONPreflightFailure(code: "invalidJSON") }
            try skipWhitespace()
        }
    }

    private mutating func parseString() throws -> String {
        let start = index
        index += 1
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x22 {
                index += 1
                do {
                    return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
                } catch {
                    throw JSONPreflightFailure(code: "invalidJSON")
                }
            }
            if byte < 0x20 { throw JSONPreflightFailure(code: "invalidJSON") }
            if byte == 0x5C {
                index += 1
                guard index < bytes.count else { throw JSONPreflightFailure(code: "invalidJSON") }
                switch bytes[index] {
                case 0x22, 0x2F, 0x5C, 0x62, 0x66, 0x6E, 0x72, 0x74:
                    index += 1
                case 0x75:
                    guard index + 4 < bytes.count,
                          bytes[(index + 1)...(index + 4)].allSatisfy(Self.isHexDigit) else {
                        throw JSONPreflightFailure(code: "invalidJSON")
                    }
                    index += 5
                default:
                    throw JSONPreflightFailure(code: "invalidJSON")
                }
            } else {
                index += 1
            }
        }
        throw JSONPreflightFailure(code: "invalidJSON")
    }

    private mutating func parseNumber() throws {
        if consume(0x2D), index == bytes.count { throw JSONPreflightFailure(code: "invalidJSON") }
        if consume(0x30) {
            if index < bytes.count, (0x30...0x39).contains(bytes[index]) { throw JSONPreflightFailure(code: "invalidJSON") }
        } else {
            guard index < bytes.count, (0x31...0x39).contains(bytes[index]) else { throw JSONPreflightFailure(code: "invalidJSON") }
            while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
        }
        if consume(0x2E) {
            guard index < bytes.count, (0x30...0x39).contains(bytes[index]) else { throw JSONPreflightFailure(code: "invalidJSON") }
            while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
        }
        if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
            index += 1
            if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D { index += 1 }
            guard index < bytes.count, (0x30...0x39).contains(bytes[index]) else { throw JSONPreflightFailure(code: "invalidJSON") }
            while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
        }
    }

    private mutating func consumeLiteral(_ literal: [UInt8]) throws {
        guard index + literal.count <= bytes.count,
              Array(bytes[index..<(index + literal.count)]) == literal else {
            throw JSONPreflightFailure(code: "invalidJSON")
        }
        index += literal.count
    }

    private mutating func skipWhitespace() throws {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
    }
}

enum StrictRFC3339 {
    /// Leap seconds are rejected because Foundation `Date` cannot preserve them.
    static func date(from value: String) -> Date? {
        let bytes = Array(value.utf8)
        guard bytes.count >= 20, bytes.allSatisfy({ $0 < 0x80 }),
              bytes[4] == 0x2D, bytes[7] == 0x2D, bytes[10] == 0x54 || bytes[10] == 0x74,
              bytes[13] == 0x3A, bytes[16] == 0x3A else { return nil }
        func integer(_ range: Range<Int>) -> Int? {
            guard range.allSatisfy({ (0x30...0x39).contains(bytes[$0]) }) else { return nil }
            return range.reduce(0) { $0 * 10 + Int(bytes[$1] - 0x30) }
        }
        guard let year = integer(0..<4), (1...9999).contains(year),
              let month = integer(5..<7), let day = integer(8..<10),
              let hour = integer(11..<13), hour < 24,
              let minute = integer(14..<16), minute < 60,
              let second = integer(17..<19), second < 60 else { return nil }

        var cursor = 19
        var fraction = 0.0
        if cursor < bytes.count, bytes[cursor] == 0x2E {
            let start = cursor + 1
            cursor = start
            while cursor < bytes.count, (0x30...0x39).contains(bytes[cursor]) { cursor += 1 }
            guard cursor > start,
                  let parsed = Double("0." + String(decoding: bytes[start..<cursor], as: UTF8.self)) else { return nil }
            fraction = parsed
        }

        let offsetSeconds: Int
        if cursor < bytes.count, (bytes[cursor] == 0x5A || bytes[cursor] == 0x7A), cursor + 1 == bytes.count {
            offsetSeconds = 0
        } else {
            guard cursor + 6 == bytes.count,
                  bytes[cursor] == 0x2B || bytes[cursor] == 0x2D,
                  bytes[cursor + 3] == 0x3A,
                  let offsetHour = integer((cursor + 1)..<(cursor + 3)), offsetHour < 24,
                  let offsetMinute = integer((cursor + 4)..<(cursor + 6)), offsetMinute < 60 else { return nil }
            let magnitude = offsetHour * 3_600 + offsetMinute * 60
            offsetSeconds = bytes[cursor] == 0x2B ? magnitude : -magnitude
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(
            calendar: calendar, timeZone: calendar.timeZone,
            year: year, month: month, day: day,
            hour: hour, minute: minute, second: second
        )
        guard let local = calendar.date(from: components) else { return nil }
        let roundTrip = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: local)
        guard roundTrip.year == year, roundTrip.month == month, roundTrip.day == day,
              roundTrip.hour == hour, roundTrip.minute == minute, roundTrip.second == second else { return nil }
        return local.addingTimeInterval(TimeInterval(-offsetSeconds) + fraction)
    }
}
