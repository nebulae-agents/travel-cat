import CryptoKit
import Foundation
import TravelCore

public enum ImageResultStatus: String, Codable, Sendable {
    case ready
    case failed
    case rejectedIdentity = "rejected_identity"
}

public enum ImageResultError: Error, Equatable, Sendable {
    case structural(String)
}

enum AttemptTokenValidator {
    static func isValid(_ value: String) -> Bool {
        guard UUID(uuidString: value)?.uuidString.lowercased() == value else { return false }
        let bytes = Array(value.utf8)
        return bytes.count == 36
            && (0x31...0x35).contains(bytes[14])
            && [0x38, 0x39, 0x61, 0x62].contains(bytes[19])
    }
}

public struct ImageResultEnvelope: Codable, Equatable, Sendable {
    public let eventId: UUID
    public let status: ImageResultStatus
    public let attemptedAt: Date
    public let relativePath: String?
    public let reason: String?
    public let attemptToken: String
    public let attemptCount: Int
    public let publishedNarrativeHash: String
    public let presentation: PostcardPresentationReference?

    public init(
        eventId: UUID,
        status: ImageResultStatus,
        attemptedAt: Date,
        relativePath: String?,
        reason: String?,
        attemptToken: String,
        attemptCount: Int,
        publishedNarrativeHash: String,
        presentation: PostcardPresentationReference?
    ) {
        self.eventId = eventId
        self.status = status
        self.attemptedAt = attemptedAt
        self.relativePath = relativePath
        self.reason = reason
        self.attemptToken = attemptToken
        self.attemptCount = attemptCount
        self.publishedNarrativeHash = publishedNarrativeHash
        self.presentation = presentation
    }

    public init(eventId: UUID, status: ImageResultStatus, attemptedAt: Date, relativePath: String?, reason: String?, attemptToken: String, attemptCount: Int, publishedNarrativeHash: String) {
        self.init(eventId: eventId, status: status, attemptedAt: attemptedAt, relativePath: relativePath, reason: reason, attemptToken: attemptToken, attemptCount: attemptCount, publishedNarrativeHash: publishedNarrativeHash, presentation: nil)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case eventId, status, attemptedAt, relativePath, reason
        case attemptToken, attemptCount, publishedNarrativeHash, presentation
    }

    public init(from decoder: Decoder) throws {
        try StrictKeys.require(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        eventId = try values.decode(UUID.self, forKey: .eventId)
        status = try values.decode(ImageResultStatus.self, forKey: .status)
        let attemptedAtText = try values.decode(String.self, forKey: .attemptedAt)
        guard let date = StrictRFC3339.date(from: attemptedAtText) else {
            throw DecodingError.dataCorruptedError(
                forKey: .attemptedAt,
                in: values,
                debugDescription: "attemptedAt must be strict RFC 3339"
            )
        }
        attemptedAt = date
        relativePath = try values.decodeIfPresent(String.self, forKey: .relativePath)
        reason = try values.decodeIfPresent(String.self, forKey: .reason)
        attemptToken = try values.decode(String.self, forKey: .attemptToken)
        attemptCount = try values.decode(Int.self, forKey: .attemptCount)
        publishedNarrativeHash = try values.decode(String.self, forKey: .publishedNarrativeHash)
        presentation = values.contains(.presentation) ? try values.decode(StrictPresentationReference.self, forKey: .presentation).value : nil
        guard AttemptTokenValidator.isValid(attemptToken),
              (0...2).contains(attemptCount),
              publishedNarrativeHash.utf8.count == 64,
              publishedNarrativeHash.utf8.allSatisfy({
                  (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
              }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .attemptToken,
                in: values,
                debugDescription: "attempt binding is invalid"
            )
        }
        guard reason.map({ value in
            value == value.trimmingCharacters(in: .whitespacesAndNewlines)
                && !value.isEmpty
                && value.unicodeScalars.count <= 240
        }) != false else {
            throw DecodingError.dataCorruptedError(
                forKey: .reason,
                in: values,
                debugDescription: "reason must contain 1...240 trimmed Unicode scalars"
            )
        }
        switch status {
        case .ready:
            guard relativePath?.isEmpty == false else {
                throw DecodingError.dataCorruptedError(
                    forKey: .relativePath,
                    in: values,
                    debugDescription: "ready requires relativePath"
                )
            }
        case .failed, .rejectedIdentity:
            guard relativePath == nil, presentation == nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .relativePath,
                    in: values,
                    debugDescription: "non-ready result forbids relativePath"
                )
            }
        }
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= StrictJSONPreflight.maximumBytes else {
            throw ImageResultError.structural("tooLarge")
        }
        do {
            try StrictJSONPreflight.validate(data)
            return try JSONDecoder.travelCat.decode(Self.self, from: data)
        } catch let failure as JSONPreflightFailure {
            throw ImageResultError.structural(failure.code)
        } catch {
            throw ImageResultError.structural("decodingFailed")
        }
    }
}

public struct ImageRetry: Codable, Equatable, Sendable {
    public var attemptCount: Int
    public var retryAt: Date?
    public let publishedNarrativeHash: String
    var lastResultHash: String?
    var lastAttemptedAt: Date?
    var activeAttemptToken: String?
    var leaseExpiresAt: Date?
    var terminalStatus: PostcardStatus?
    var terminalResultHash: String?
    var imageContentHash: String?
    var terminalRelativePath: String?
    var terminalPresentation: PostcardPresentationReference?
    var currentPresentation: PostcardPresentationReference?

    public init(
        attemptCount: Int,
        retryAt: Date?,
        publishedNarrativeHash: String,
        lastResultHash: String? = nil,
        lastAttemptedAt: Date? = nil,
        activeAttemptToken: String? = nil,
        leaseExpiresAt: Date? = nil,
        terminalStatus: PostcardStatus? = nil,
        terminalResultHash: String? = nil,
        imageContentHash: String? = nil,
        terminalRelativePath: String? = nil,
        terminalPresentation: PostcardPresentationReference? = nil,
        currentPresentation: PostcardPresentationReference? = nil
    ) {
        self.attemptCount = attemptCount
        self.retryAt = retryAt
        self.publishedNarrativeHash = publishedNarrativeHash
        self.lastResultHash = lastResultHash
        self.lastAttemptedAt = lastAttemptedAt
        self.activeAttemptToken = activeAttemptToken
        self.leaseExpiresAt = leaseExpiresAt
        self.terminalStatus = terminalStatus
        self.terminalResultHash = terminalResultHash
        self.imageContentHash = imageContentHash
        self.terminalRelativePath = terminalRelativePath
        self.terminalPresentation = terminalPresentation
        self.currentPresentation = currentPresentation
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case attemptCount = "imageAttemptCount"
        case retryAt = "imageRetryAt"
        case publishedNarrativeHash, lastResultHash, lastAttemptedAt
        case activeAttemptToken, leaseExpiresAt, terminalStatus, terminalResultHash
        case imageContentHash, terminalRelativePath, terminalPresentation, currentPresentation
    }

    public init(from decoder: Decoder) throws {
        try StrictKeys.require(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        attemptCount = try values.decode(Int.self, forKey: .attemptCount)
        retryAt = try values.decodeIfPresent(Date.self, forKey: .retryAt)
        publishedNarrativeHash = try values.decode(String.self, forKey: .publishedNarrativeHash)
        lastResultHash = try values.decodeIfPresent(String.self, forKey: .lastResultHash)
        lastAttemptedAt = try values.decodeIfPresent(Date.self, forKey: .lastAttemptedAt)
        activeAttemptToken = try values.decodeIfPresent(String.self, forKey: .activeAttemptToken)
        leaseExpiresAt = try values.decodeIfPresent(Date.self, forKey: .leaseExpiresAt)
        terminalStatus = try values.decodeIfPresent(PostcardStatus.self, forKey: .terminalStatus)
        terminalResultHash = try values.decodeIfPresent(String.self, forKey: .terminalResultHash)
        imageContentHash = try values.decodeIfPresent(String.self, forKey: .imageContentHash)
        terminalRelativePath = try values.decodeIfPresent(String.self, forKey: .terminalRelativePath)
        terminalPresentation = values.contains(.terminalPresentation) ? try values.decode(StrictPresentationReference.self, forKey: .terminalPresentation).value : nil
        currentPresentation = values.contains(.currentPresentation) ? try values.decode(StrictPresentationReference.self, forKey: .currentPresentation).value : nil
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(attemptCount, forKey: .attemptCount)
        try values.encode(retryAt, forKey: .retryAt)
        try values.encode(publishedNarrativeHash, forKey: .publishedNarrativeHash)
        try values.encodeIfPresent(lastResultHash, forKey: .lastResultHash)
        try values.encodeIfPresent(lastAttemptedAt, forKey: .lastAttemptedAt)
        try values.encodeIfPresent(activeAttemptToken, forKey: .activeAttemptToken)
        try values.encodeIfPresent(leaseExpiresAt, forKey: .leaseExpiresAt)
        try values.encodeIfPresent(terminalStatus, forKey: .terminalStatus)
        try values.encodeIfPresent(terminalResultHash, forKey: .terminalResultHash)
        try values.encodeIfPresent(imageContentHash, forKey: .imageContentHash)
        try values.encodeIfPresent(terminalRelativePath, forKey: .terminalRelativePath)
        try values.encodeIfPresent(terminalPresentation, forKey: .terminalPresentation)
        try values.encodeIfPresent(currentPresentation, forKey: .currentPresentation)
    }

    mutating func recordFailure(now: Date, mode: TravelMode, resultHash: String) -> PostcardStatus {
        attemptCount += 1
        lastAttemptedAt = now
        lastResultHash = resultHash
        activeAttemptToken = nil
        leaseExpiresAt = nil
        guard attemptCount < 3 else {
            retryAt = nil
            return .imageUnavailable
        }
        let daily: [TimeInterval] = [600, 1_800, 7_200]
        let fast: [TimeInterval] = [60, 120, 240]
        retryAt = now.addingTimeInterval((mode == .fast ? fast : daily)[attemptCount - 1])
        return .pendingImage
    }
}

public struct PendingImageWork: Codable, Equatable, Sendable {
    public let event: TripEvent
    public let characterProfile: CharacterProfile
    public let imageAttemptCount: Int
    public let retryAt: Date?
    public let publishedNarrativeHash: String
    public let attemptToken: String
    public let leaseExpiresAt: Date
    public let runtime: TravelRuntimeMetadata?

    public init(
        event: TripEvent,
        retry: ImageRetry,
        characterProfile: CharacterProfile = .defaultBlackCat,
        runtime: TravelRuntimeMetadata? = nil
    ) {
        self.event = event
        self.characterProfile = characterProfile
        imageAttemptCount = retry.attemptCount
        retryAt = retry.retryAt
        publishedNarrativeHash = retry.publishedNarrativeHash
        attemptToken = retry.activeAttemptToken ?? ""
        leaseExpiresAt = retry.leaseExpiresAt ?? .distantPast
        self.runtime = runtime
    }

    private enum CodingKeys: String, CodingKey {
        case event, characterProfile, imageAttemptCount, retryAt, publishedNarrativeHash, attemptToken, leaseExpiresAt, runtime
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        event = try values.decode(TripEvent.self, forKey: .event)
        characterProfile = try values.decodeIfPresent(CharacterProfile.self, forKey: .characterProfile) ?? .defaultBlackCat
        imageAttemptCount = try values.decode(Int.self, forKey: .imageAttemptCount)
        retryAt = try values.decodeIfPresent(Date.self, forKey: .retryAt)
        publishedNarrativeHash = try values.decode(String.self, forKey: .publishedNarrativeHash)
        attemptToken = try values.decode(String.self, forKey: .attemptToken)
        leaseExpiresAt = try values.decode(Date.self, forKey: .leaseExpiresAt)
        runtime = try values.decodeIfPresent(TravelRuntimeMetadata.self, forKey: .runtime)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(event, forKey: .event)
        if characterProfile != .defaultBlackCat { try values.encode(characterProfile, forKey: .characterProfile) }
        try values.encode(imageAttemptCount, forKey: .imageAttemptCount)
        try values.encodeIfPresent(retryAt, forKey: .retryAt)
        try values.encode(publishedNarrativeHash, forKey: .publishedNarrativeHash)
        try values.encode(attemptToken, forKey: .attemptToken)
        try values.encode(leaseExpiresAt, forKey: .leaseExpiresAt)
        try values.encodeIfPresent(runtime, forKey: .runtime)
    }

    public func enriched(runtime: TravelRuntimeMetadata) -> Self {
        Self(
            event: event,
            characterProfile: characterProfile,
            imageAttemptCount: imageAttemptCount,
            retryAt: retryAt,
            publishedNarrativeHash: publishedNarrativeHash,
            attemptToken: attemptToken,
            leaseExpiresAt: leaseExpiresAt,
            runtime: runtime
        )
    }

    private init(
        event: TripEvent,
        characterProfile: CharacterProfile,
        imageAttemptCount: Int,
        retryAt: Date?,
        publishedNarrativeHash: String,
        attemptToken: String,
        leaseExpiresAt: Date,
        runtime: TravelRuntimeMetadata?
    ) {
        self.event = event
        self.characterProfile = characterProfile
        self.imageAttemptCount = imageAttemptCount
        self.retryAt = retryAt
        self.publishedNarrativeHash = publishedNarrativeHash
        self.attemptToken = attemptToken
        self.leaseExpiresAt = leaseExpiresAt
        self.runtime = runtime
    }
}

struct ImageRetryStore: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var entries: [String: ImageRetry]

    init(schemaVersion: Int = 2, entries: [String: ImageRetry] = [:]) {
        self.schemaVersion = schemaVersion
        self.entries = entries
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case schemaVersion, entries }

    init(from decoder: Decoder) throws {
        try StrictKeys.require(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        entries = try values.decode([String: ImageRetry].self, forKey: .entries)
    }

    func validated() throws -> Self {
        func isLowercaseSHA256(_ value: String) -> Bool {
            value.utf8.count == 64 && value.utf8.allSatisfy {
                (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
            }
        }
        guard schemaVersion == 1 || schemaVersion == 2 else { throw RepositoryError.malformedImageRetryState }
        for (key, retry) in entries {
            try retry.terminalPresentation.map { try StrictPresentationReference.validate($0) }
            try retry.currentPresentation.map { try StrictPresentationReference.validate($0) }
            guard retry.terminalStatus == .ready || (retry.terminalPresentation == nil && retry.currentPresentation == nil) else {
                throw RepositoryError.malformedImageRetryState
            }
            let terminalIsConsistent: Bool
            switch retry.terminalStatus {
            case nil:
                terminalIsConsistent = retry.terminalResultHash == nil
                    && retry.imageContentHash == nil
                    && retry.terminalRelativePath == nil
            case .ready:
                terminalIsConsistent = retry.imageContentHash != nil
                    && retry.terminalRelativePath != nil
                    && retry.retryAt == nil
                    && retry.activeAttemptToken == nil
            case .imageUnavailable:
                terminalIsConsistent = retry.imageContentHash == nil
                    && retry.terminalRelativePath == nil
                    && retry.retryAt == nil
                    && retry.activeAttemptToken == nil
            default:
                terminalIsConsistent = false
            }
            guard let id = UUID(uuidString: key), key == id.uuidString.lowercased(),
                  (0...3).contains(retry.attemptCount),
                  isLowercaseSHA256(retry.publishedNarrativeHash),
                  retry.lastResultHash.map(isLowercaseSHA256) != false,
                  retry.terminalResultHash.map(isLowercaseSHA256) != false,
                  retry.imageContentHash.map(isLowercaseSHA256) != false,
                  (retry.lastResultHash == nil) == (retry.lastAttemptedAt == nil),
                  retry.attemptCount == 0 || retry.lastAttemptedAt != nil,
                  retry.attemptCount < 3 || retry.retryAt == nil,
                  (retry.activeAttemptToken == nil) == (retry.leaseExpiresAt == nil),
                  retry.activeAttemptToken.map(AttemptTokenValidator.isValid) != false,
                  retry.terminalStatus.map({ $0 == .ready || $0 == .imageUnavailable }) != false,
                  terminalIsConsistent else {
                throw RepositoryError.malformedImageRetryState
            }
        }
        return self
    }
}

enum NarrativeHasher {
    private struct Projection: Codable {
        let id: UUID
        let tripID: UUID
        let previousEventID: UUID?
        let occurredAt: Date
        let phase: TravelPhase
        let location: Location?
        let transport: String?
        let summary: String
        let mood: Mood
        let continuityReferences: [String]
        let openHook: String?
        let consumedItemID: String?
    }

    static func hash(_ event: TripEvent) throws -> String {
        let projection = Projection(
            id: event.id,
            tripID: event.tripID,
            previousEventID: event.previousEventID,
            occurredAt: event.occurredAt,
            phase: event.phase,
            location: event.location,
            transport: event.transport,
            summary: event.summary,
            mood: event.mood,
            continuityReferences: event.continuityReferences,
            openHook: event.openHook,
            consumedItemID: event.consumedItemID
        )
        let data = try JSONEncoder.travelCat.encode(projection)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func hash(_ result: ImageResultEnvelope) throws -> String {
        let data = try JSONEncoder.travelCat.encode(result)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension ImageResultEnvelope {
    func requireValidFields() throws {
        try presentation.map { try StrictPresentationReference.validate($0) }
        guard AttemptTokenValidator.isValid(attemptToken),
              (0...2).contains(attemptCount),
              publishedNarrativeHash.utf8.count == 64,
              publishedNarrativeHash.utf8.allSatisfy({
                  (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
              }) else { throw RepositoryError.invalidImageResult }
        guard reason.map({ value in
            value == value.trimmingCharacters(in: .whitespacesAndNewlines)
                && !value.isEmpty
                && value.unicodeScalars.count <= 240
        }) != false else {
            throw RepositoryError.invalidImageResult
        }
        switch status {
        case .ready:
            guard relativePath?.isEmpty == false else { throw RepositoryError.invalidImageResult }
        case .failed, .rejectedIdentity:
            guard relativePath == nil, presentation == nil else { throw RepositoryError.invalidImageResult }
        }
    }
}

private struct StrictPresentationReference: Decodable {
    let value: PostcardPresentationReference
    private enum CodingKeys: String, CodingKey, CaseIterable { case relativePath, sha256 }
    init(from decoder: Decoder) throws {
        try StrictKeys.require(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        value = PostcardPresentationReference(relativePath: try values.decode(String.self, forKey: .relativePath), sha256: try values.decode(String.self, forKey: .sha256))
        try Self.validate(value)
    }
    static func validate(_ value: PostcardPresentationReference) throws {
        let parts = value.relativePath.components(separatedBy: "/")
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789._-".utf8)
        guard parts.count == 3, parts[0] == "postcards", parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.allSatisfy(allowed.contains) }),
              UUID(uuidString: parts[1])?.uuidString.lowercased() == parts[1],
              parts[2].utf8.first.map({ (48...57).contains($0) || (97...122).contains($0) }) == true,
              (parts[2] as NSString).pathExtension == "json", value.sha256.utf8.count == 64,
              value.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw RepositoryError.invalidImageResult }
    }
}
