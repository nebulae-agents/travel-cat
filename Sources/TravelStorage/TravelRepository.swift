import Darwin
import CryptoKit
import Foundation
import ImageIO
import TravelCore
import UniformTypeIdentifiers

public enum RepositoryError: Error, Sendable {
    case lockUnavailable
    case lockFailure(code: Int32)
    case malformedJournal(line: Int, reason: String)
    case recoveryRequired
    case versionConflict
    case continuityConflict
    case brokenJournalChain
    case duplicateEventID(UUID)
    case eventConflict(UUID)
    case eventNotFound(UUID)
    case eventInFuture
    case invalidImageTransition
    case invalidImageResult
    case malformedImageRetryState
    case narrativeChanged(UUID)
    case unsafePostcardPath
    case catIsAway
    case clearHistoryResetFailed(backupPath: String, reason: String)
}

extension RepositoryError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .lockUnavailable:
            "repository lock is unavailable"
        case let .lockFailure(code):
            "repository lock failed with errno \(code)"
        case let .malformedJournal(line, reason):
            "malformed journal record at line \(line): \(reason)"
        case .recoveryRequired:
            "repository recovery required; run recovery before retrying"
        case .versionConflict:
            "snapshot state version conflicts with the repository"
        case .continuityConflict:
            "event continuity conflicts with the repository"
        case .brokenJournalChain:
            "journal previous-event chain is broken"
        case let .duplicateEventID(id):
            "journal contains duplicate event ID \(id.uuidString)"
        case let .eventConflict(id):
            "event ID conflicts with stored event: \(id.uuidString)"
        case let .eventNotFound(id):
            "event not found: \(id.uuidString)"
        case .eventInFuture:
            "event timestamp is later than the trusted repository clock"
        case .invalidImageTransition:
            "postcard image status transition is invalid"
        case .invalidImageResult:
            "postcard image result is invalid"
        case .malformedImageRetryState:
            "postcard retry state is malformed"
        case let .narrativeChanged(id):
            "published narrative changed for postcard event: \(id.uuidString)"
        case .unsafePostcardPath:
            "postcard path must be a safe relative path beneath postcards"
        case .catIsAway:
            "carried item can only change while the cat is resting or preparing"
        case let .clearHistoryResetFailed(backupPath, reason):
            "history reset failed; recoverable backup is at \(backupPath): \(reason)"
        }
    }
}

public struct DueClaim: Codable, Sendable {
    public let due: Bool
    public let snapshot: TripSnapshot
    public let previousEvent: TripEvent?
    public let characterProfile: CharacterProfile
    public let runtime: TravelRuntimeMetadata?

    public init(
        due: Bool,
        snapshot: TripSnapshot,
        previousEvent: TripEvent?,
        characterProfile: CharacterProfile = .defaultBlackCat,
        runtime: TravelRuntimeMetadata? = nil
    ) {
        self.due = due
        self.snapshot = snapshot
        self.previousEvent = previousEvent
        self.characterProfile = characterProfile
        self.runtime = runtime
    }

    private enum CodingKeys: String, CodingKey { case due, snapshot, previousEvent, characterProfile, runtime }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        due = try values.decode(Bool.self, forKey: .due)
        snapshot = try values.decode(TripSnapshot.self, forKey: .snapshot)
        previousEvent = try values.decodeIfPresent(TripEvent.self, forKey: .previousEvent)
        characterProfile = try values.decodeIfPresent(CharacterProfile.self, forKey: .characterProfile) ?? .defaultBlackCat
        runtime = try values.decodeIfPresent(TravelRuntimeMetadata.self, forKey: .runtime)
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(due, forKey: .due)
        try values.encode(snapshot, forKey: .snapshot)
        try values.encodeIfPresent(previousEvent, forKey: .previousEvent)
        if characterProfile != .defaultBlackCat { try values.encode(characterProfile, forKey: .characterProfile) }
        try values.encodeIfPresent(runtime, forKey: .runtime)
    }

    public func enriched(runtime: TravelRuntimeMetadata) -> Self {
        Self(
            due: due,
            snapshot: snapshot,
            previousEvent: previousEvent,
            characterProfile: characterProfile,
            runtime: runtime
        )
    }
}

public struct PublishEnvelope: Codable, Sendable {
    public let event: TripEvent
    public let next: TripSnapshot

    public init(event: TripEvent, next: TripSnapshot) {
        self.event = event
        self.next = next
    }
}

public struct PublishAcknowledgement: Codable, Sendable {
    public let ok: Bool
    public let eventID: UUID
    public let stateVersion: Int

    public init(ok: Bool = true, eventID: UUID, stateVersion: Int) {
        self.ok = ok
        self.eventID = eventID
        self.stateVersion = stateVersion
    }
}

public struct MarkImageAcknowledgement: Codable, Sendable {
    public let ok: Bool
    public let eventID: UUID
    public let status: PostcardStatus

    public init(ok: Bool = true, eventID: UUID, status: PostcardStatus) {
        self.ok = ok
        self.eventID = eventID
        self.status = status
    }
}

public struct RepositoryContents: Equatable, Sendable {
    public let snapshot: TripSnapshot
    public let events: [TripEvent]
    public let characterProfile: CharacterProfile
    public let selectedCharacterProfile: CharacterProfile
    public let presentationReferences: [UUID: PostcardPresentationReference]

    public init(
        snapshot: TripSnapshot,
        events: [TripEvent],
        characterProfile: CharacterProfile = .defaultBlackCat,
        selectedCharacterProfile: CharacterProfile? = nil,
        presentationReferences: [UUID: PostcardPresentationReference] = [:]
    ) {
        self.snapshot = snapshot
        self.events = events
        self.characterProfile = characterProfile
        self.selectedCharacterProfile = selectedCharacterProfile ?? characterProfile
        self.presentationReferences = presentationReferences
    }
}

public final class TravelRepository: @unchecked Sendable {
    public let root: URL
    public let snapshotURL: URL

    private let journalURL: URL
    private let imageRetryURL: URL
    private let characterAnchorURL: URL
    private let lockURL: URL
    private let writer: AtomicFileWriter
    private let clock: any TravelClock
    var imageValidationHook: (() -> Void)?
    var publishAfterJournalHook: (() throws -> Void)?

    public init(root: URL, clock: any TravelClock = SystemClock()) throws {
        self.root = root.standardizedFileURL
        snapshotURL = self.root.appendingPathComponent("state/current-trip.json")
        journalURL = self.root.appendingPathComponent("journal/events.jsonl")
        imageRetryURL = self.root.appendingPathComponent("state/image-retries.json")
        characterAnchorURL = self.root.appendingPathComponent("state/frozen-character.json")
        lockURL = self.root.appendingPathComponent(".repository.lock")
        writer = AtomicFileWriter()
        self.clock = clock
        imageValidationHook = nil
        publishAfterJournalHook = nil
        try bootstrap()
        try withExclusiveLock {
            var events = try readEventsUnlocked()
            let snapshot = try loadSnapshotUnlocked()
            try recoverInterruptedPublicationUnlocked(snapshot: snapshot, events: events)
            var store = try loadRetryStoreUnlocked()
            try reconcileRetryStoreUnlocked(events: &events, store: &store)
        }
    }

    public func loadSnapshot() throws -> TripSnapshot {
        try loadSnapshotUnlocked()
    }

    public func events() throws -> [TripEvent] {
        try withExclusiveLock {
            try readEventsUnlocked()
        }
    }

    public func loadContents() throws -> RepositoryContents {
        try withExclusiveLock {
            let snapshot = try loadSnapshotUnlocked()
            let events = try readEventsUnlocked()
            try requireAligned(snapshot: snapshot, events: events)
            let selectedProfile = try CharacterProfileStore(dataRoot: root).selectedProfile()
            let effectiveProfile = try frozenEffectiveProfileUnlocked(snapshot: snapshot, events: events)
                ?? selectedProfile
            return RepositoryContents(
                snapshot: snapshot,
                events: events,
                characterProfile: effectiveProfile,
                selectedCharacterProfile: selectedProfile,
                presentationReferences: try presentationReferencesUnlocked(events: events)
            )
        }
    }

    public func configureCharacter(
        _ request: CharacterConfigurationRequest
    ) throws -> CharacterConfigurationResponse {
        try withExclusiveLock {
            let snapshot = try loadSnapshotUnlocked()
            let events = try readEventsUnlocked()
            try requireAligned(snapshot: snapshot, events: events)
            try validateJournalChain(events)
            let frozenProfile = try frozenEffectiveProfileUnlocked(snapshot: snapshot, events: events)
            let store = CharacterProfileStore(dataRoot: root)
            if frozenProfile == nil { _ = try store.selectedProfile() }

            let selectedProfile: CharacterProfile
            switch request {
            case .default:
                try store.selectDefault()
                selectedProfile = .defaultBlackCat
            case let .import(directory):
                selectedProfile = try store.importProfile(from: directory)
            }
            return CharacterConfigurationResponse(
                selectedProfile: selectedProfile,
                effectiveProfile: frozenProfile ?? selectedProfile,
                dataRoot: root
            )
        }
    }

    public func characterConfiguration() throws -> CharacterConfigurationResponse {
        try withExclusiveLock {
            let snapshot = try loadSnapshotUnlocked()
            let events = try readEventsUnlocked()
            try requireAligned(snapshot: snapshot, events: events)
            try validateJournalChain(events)
            let selectedProfile = try CharacterProfileStore(dataRoot: root).selectedProfile()
            return CharacterConfigurationResponse(
                selectedProfile: selectedProfile,
                effectiveProfile: try frozenEffectiveProfileUnlocked(snapshot: snapshot, events: events)
                    ?? selectedProfile,
                dataRoot: root
            )
        }
    }

    /// Runs `body` while the repository's authoritative snapshot and journal
    /// remain protected by the repository lock. Prompt observation uses this to
    /// commit its cursor before a clear, append, or in-place postcard update can
    /// become visible.
    func withValidatedLockedContents<T>(
        _ body: (RepositoryContents) throws -> T
    ) throws -> T {
        try withExclusiveLock {
            let snapshot = try loadSnapshotUnlocked()
            let events = try readEventsUnlocked()
            try requireAligned(snapshot: snapshot, events: events)
            try validateJournalChain(events)
            let selectedProfile = try CharacterProfileStore(dataRoot: root).selectedProfile()
            let effectiveProfile = try frozenEffectiveProfileUnlocked(snapshot: snapshot, events: events)
                ?? selectedProfile
            return try body(RepositoryContents(
                snapshot: snapshot,
                events: events,
                characterProfile: effectiveProfile,
                selectedCharacterProfile: selectedProfile,
                presentationReferences: try presentationReferencesUnlocked(events: events)
            ))
        }
    }

    public func export(to destination: URL) throws -> URL {
        try withExclusiveLock {
            let fileManager = FileManager.default
            let final = destination.standardizedFileURL
            guard !fileManager.fileExists(atPath: final.path) else { throw CocoaError(.fileWriteFileExists) }
            let temporary = final.deletingLastPathComponent().appendingPathComponent(
                ".\(final.lastPathComponent).\(UUID().uuidString).export.tmp",
                isDirectory: true
            )
            defer { try? fileManager.removeItem(at: temporary) }
            try fileManager.createDirectory(at: temporary, withIntermediateDirectories: false)
            for relative in [
                "state/current-trip.json",
                "state/settings.json",
                "state/image-retries.json",
                "state/active-character.json",
                "state/frozen-character.json",
                "journal/events.jsonl",
            ] {
                let source = root.appendingPathComponent(relative)
                try copyOptionalRegularFile(source, to: temporary.appendingPathComponent(relative))
            }
            try copyTreeWithoutLinks(
                root.appendingPathComponent("postcards", isDirectory: true),
                to: temporary.appendingPathComponent("postcards", isDirectory: true)
            )
            try copyOptionalTreeWithoutLinks(
                root.appendingPathComponent("characters", isDirectory: true),
                to: temporary.appendingPathComponent("characters", isDirectory: true),
                skippingTransientFiles: false
            )
            try fileManager.moveItem(at: temporary, to: final)
            return final
        }
    }

    public func clearHistory(now: Date = Date()) throws -> URL {
        try withExclusiveLock {
            let fileManager = FileManager.default
            let hasCharacterAnchor = try readCharacterAnchorUnlocked() != nil
            let backups = root.appendingPathComponent("backups", isDirectory: true)
            let backup = root.appendingPathComponent(
                "backups/cleared-\(Int(now.timeIntervalSince1970))-\(UUID().uuidString)",
                isDirectory: true
            )
            let stagedBackup = backups.appendingPathComponent(".\(backup.lastPathComponent).staging-\(UUID().uuidString)")
            try fileManager.createDirectory(at: stagedBackup.appendingPathComponent("state"), withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: stagedBackup) }
            try fileManager.createDirectory(at: stagedBackup.appendingPathComponent("journal"), withIntermediateDirectories: true)
            for relative in [
                "state/current-trip.json",
                "state/settings.json",
                "state/image-retries.json",
                "state/active-character.json",
                "state/frozen-character.json",
                "journal/events.jsonl",
            ] {
                if relative == "state/frozen-character.json", !hasCharacterAnchor { continue }
                try copyOptionalRegularFile(
                    root.appendingPathComponent(relative),
                    to: stagedBackup.appendingPathComponent(relative)
                )
            }
            try copyTreeWithoutLinks(
                root.appendingPathComponent("postcards", isDirectory: true),
                to: stagedBackup.appendingPathComponent("postcards", isDirectory: true)
            )
            try copyOptionalTreeWithoutLinks(
                root.appendingPathComponent("characters", isDirectory: true),
                to: stagedBackup.appendingPathComponent("characters", isDirectory: true),
                skippingTransientFiles: false
            )
            let previousSnapshot = try Data(contentsOf: stagedBackup.appendingPathComponent("state/current-trip.json"))
            let previousJournal = try Data(contentsOf: stagedBackup.appendingPathComponent("journal/events.jsonl"))
            let previousRetries = try? Data(contentsOf: stagedBackup.appendingPathComponent("state/image-retries.json"))
            let previousCharacterAnchor = hasCharacterAnchor
                ? try Data(contentsOf: stagedBackup.appendingPathComponent("state/frozen-character.json")) : nil
            guard previousSnapshot == (try Data(contentsOf: snapshotURL)),
                  previousJournal == (try Data(contentsOf: journalURL)) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try fileManager.moveItem(at: stagedBackup, to: backup)
            let postcards = root.appendingPathComponent("postcards", isDirectory: true)
            let old = root.appendingPathComponent(".postcards-\(UUID().uuidString).old", isDirectory: true)
            do {
                try writer.write(JSONEncoder.travelCat.encode(TripSnapshot.empty(now: now)), to: snapshotURL)
                try writer.write(Data(), to: journalURL)
                try writer.write(JSONEncoder.travelCat.encode(ImageRetryStore()), to: imageRetryURL)
                if hasCharacterAnchor { try fileManager.removeItem(at: characterAnchorURL) }
                try fileManager.moveItem(at: postcards, to: old)
                try fileManager.createDirectory(at: postcards, withIntermediateDirectories: false)
                try fileManager.removeItem(at: old)
            } catch {
                let resetError = error
                try? writer.write(previousSnapshot, to: snapshotURL)
                try? writer.write(previousJournal, to: journalURL)
                if let previousCharacterAnchor {
                    try? writer.write(previousCharacterAnchor, to: characterAnchorURL)
                }
                if let previousRetries {
                    try? writer.write(previousRetries, to: imageRetryURL)
                } else {
                    try? fileManager.removeItem(at: imageRetryURL)
                }
                if fileManager.fileExists(atPath: old.path) {
                    try? fileManager.removeItem(at: postcards)
                    try? fileManager.moveItem(at: old, to: postcards)
                }
                throw RepositoryError.clearHistoryResetFailed(
                    backupPath: backup.path,
                    reason: String(describing: resetError)
                )
            }
            return backup
        }
    }

    @discardableResult
    public func updateCarriedItem(_ id: String?) throws -> TripSnapshot {
        try withExclusiveLock {
            var snapshot = try loadSnapshotUnlocked()
            let events = try readEventsUnlocked()
            try requireAligned(snapshot: snapshot, events: events)
            guard snapshot.phase == .resting || snapshot.phase == .preparing else {
                throw RepositoryError.catIsAway
            }
            snapshot.carriedItemID = id
            try writer.write(JSONEncoder.travelCat.encode(snapshot), to: snapshotURL)
            return snapshot
        }
    }

    public func claimDue(mode: TravelMode, now: Date) throws -> DueClaim {
        try withExclusiveLock {
            let snapshot = try loadSnapshotUnlocked()
            let journalEvents = try readEventsUnlocked()
            let due = TripScheduler(mode: mode).isDue(snapshot: snapshot, now: now)
            let profile: CharacterProfile
            if due, snapshot.phase == .resting {
                profile = try frozenProfileForBoundaryUnlocked(snapshot: snapshot, claimedAt: now)
            } else {
                profile = try effectiveProfileUnlocked(snapshot: snapshot, events: journalEvents)
            }
            return DueClaim(
                due: due,
                snapshot: snapshot,
                previousEvent: journalEvents.last,
                characterProfile: profile
            )
        }
    }

    @discardableResult
    public func publish(event: TripEvent, next: TripSnapshot) throws -> Int {
        try withExclusiveLock {
            let current = try loadSnapshotUnlocked()
            let journalEvents = try readEventsUnlocked()
            try requireAligned(snapshot: current, events: journalEvents)

            if let storedEvent = journalEvents.first(where: { $0.id == event.id }) {
                guard isIdempotentRetry(stored: storedEvent, supplied: event) else {
                    throw RepositoryError.eventConflict(event.id)
                }
                try validateJournalChain(journalEvents)
                return current.stateVersion
            }
            let trustedNow = clock.now
            guard event.occurredAt <= trustedNow,
                  next.lastUpdatedAt <= trustedNow else {
                throw RepositoryError.eventInFuture
            }
            guard (event.postcardStatus == .none || event.postcardStatus == .pendingImage),
                  event.postcardRelativePath == nil else {
                throw RepositoryError.invalidImageTransition
            }
            guard next.stateVersion == current.stateVersion + 1 else {
                throw RepositoryError.versionConflict
            }

            guard event.previousEventID == current.lastEventID,
                  next.lastEventID == event.id else {
                throw RepositoryError.continuityConflict
            }
            guard next.tripID == event.tripID,
                  next.phase == event.phase else {
                throw RepositoryError.continuityConflict
            }
            if current.tripID != event.tripID {
                guard current.phase == .resting, event.phase == .preparing else {
                    throw RepositoryError.continuityConflict
                }
            } else {
                do {
                    try TravelStateMachine().requireTransition(
                        from: current.phase,
                        to: event.phase
                    )
                } catch {
                    throw RepositoryError.continuityConflict
                }
            }

            let trustedProfile: CharacterProfile
            if current.tripID != event.tripID {
                trustedProfile = try anchoredProfileForPublishUnlocked(snapshot: current)
            } else {
                trustedProfile = try profileForTripUnlocked(event.tripID, events: journalEvents)
            }
            guard current.tripID != event.tripID
                    ? (event.characterProfile == nil || event.characterProfile == trustedProfile)
                    : event.characterProfile == nil else {
                throw RepositoryError.continuityConflict
            }
            let storedEvent = eventWithFrozenProfile(event, profile: current.tripID == event.tripID ? nil : trustedProfile)

            // Publication is deliberately event-first: an error or crash after this append but
            // before sidecar/snapshot replacement is recoverable from the authoritative journal.
            try appendEventUnlocked(storedEvent)
            try publishAfterJournalHook?()
            if storedEvent.postcardStatus == .pendingImage {
                var retryStore = try loadRetryStoreUnlocked()
                let key = retryKey(storedEvent.id)
                let hash = try NarrativeHasher.hash(storedEvent)
                if let existing = retryStore.entries[key] {
                    guard existing.publishedNarrativeHash == hash else {
                        throw RepositoryError.narrativeChanged(event.id)
                    }
                } else {
                    retryStore.entries[key] = ImageRetry(
                        attemptCount: 0,
                        retryAt: nil,
                        publishedNarrativeHash: hash
                    )
                    try writeRetryStoreUnlocked(retryStore)
                }
            }
            try writer.write(JSONEncoder.travelCat.encode(next), to: snapshotURL)
            return next.stateVersion
        }
    }

    @discardableResult
    public func recover() throws -> TripSnapshot {
        try withExclusiveLock {
            let rebuilt = try rebuildSnapshot(from: readEventsUnlocked())
            try writer.write(JSONEncoder.travelCat.encode(rebuilt), to: snapshotURL)
            return rebuilt
        }
    }

    public func pendingImages(mode: TravelMode) throws -> [PendingImageWork] {
        try pendingImages(mode: mode, trustedNow: clock.now)
    }

    // Test-only compatibility hook. Production scheduling always uses the injected clock above.
    func pendingImages(now: Date) throws -> [PendingImageWork] {
        try pendingImages(mode: .fast, trustedNow: now)
    }

    private func pendingImages(mode: TravelMode, trustedNow now: Date) throws -> [PendingImageWork] {
        try withExclusiveLock {
            var events = try readEventsUnlocked()
            var store = try loadRetryStoreUnlocked()
            try reconcileRetryStoreUnlocked(events: &events, store: &store)
            let due = try events
                .filter { $0.postcardStatus == .pendingImage }
                .compactMap { event -> (TripEvent, ImageRetry)? in
                    let retry = try retryForPendingEventUnlocked(event, store: &store)
                    guard retry.retryAt.map({ $0 <= now }) ?? true,
                          retry.leaseExpiresAt.map({ $0 <= now }) ?? true else { return nil }
                    return (event, retry)
                }
                .sorted {
                    if $0.0.occurredAt != $1.0.occurredAt {
                        return $0.0.occurredAt < $1.0.occurredAt
                    }
                    return $0.0.id.uuidString < $1.0.id.uuidString
                }
            guard let (event, current) = due.first else { return [] }
            let profile = try profileForTripUnlocked(event.tripID, events: events)
            var leased = current
            leased.activeAttemptToken = UUID().uuidString.lowercased()
            leased.leaseExpiresAt = now.addingTimeInterval(mode == .fast ? 1_800 : 3_600)
            store.schemaVersion = 2
            store.entries[retryKey(event.id)] = leased
            try writeRetryStoreUnlocked(store)
            return [PendingImageWork(event: event, retry: leased, characterProfile: profile)]
        }
    }

    public func imageRetry(for eventID: UUID) throws -> ImageRetry? {
        try withExclusiveLock {
            var events = try readEventsUnlocked()
            var store = try loadRetryStoreUnlocked()
            try reconcileRetryStoreUnlocked(events: &events, store: &store)
            guard let event = events.first(where: { $0.id == eventID }), event.postcardStatus != .none else {
                return nil
            }
            if event.postcardStatus == .pendingImage {
                return try retryForPendingEventUnlocked(event, store: &store)
            }
            guard let retry = store.entries[retryKey(eventID)] else { return nil }
            try requireNarrativeHash(event, retry: retry)
            return retry
        }
    }

    @discardableResult
    public func markImage(_ result: ImageResultEnvelope, mode: TravelMode) throws -> MarkImageAcknowledgement {
        if result.status == .ready {
            return try markReadyImage(result)
        }
        return try withExclusiveLock {
            try result.requireValidFields()
            let trustedNow = clock.now
            var events = try readEventsUnlocked()
            var store = try loadRetryStoreUnlocked()
            try reconcileRetryStoreUnlocked(events: &events, store: &store)
            guard let index = events.firstIndex(where: { $0.id == result.eventId }) else {
                throw RepositoryError.eventNotFound(result.eventId)
            }
            let existing = events[index]
            guard existing.postcardStatus != .none else { throw RepositoryError.invalidImageTransition }
            var retry = try retryForEventUnlocked(existing, store: &store)
            try requireNarrativeHash(existing, retry: retry)
            let resultHash = try NarrativeHasher.hash(result)
            guard result.publishedNarrativeHash == retry.publishedNarrativeHash else {
                throw RepositoryError.invalidImageResult
            }

            if existing.postcardStatus == .ready { throw RepositoryError.invalidImageTransition }
            if existing.postcardStatus == .imageUnavailable {
                guard retry.terminalStatus == .imageUnavailable,
                      retry.terminalResultHash == resultHash else { throw RepositoryError.invalidImageTransition }
                return MarkImageAcknowledgement(eventID: result.eventId, status: .imageUnavailable)
            }
            guard existing.postcardStatus == .pendingImage else {
                throw RepositoryError.invalidImageTransition
            }
            if retry.lastResultHash == resultHash {
                return MarkImageAcknowledgement(eventID: result.eventId, status: .pendingImage)
            }
            guard retry.activeAttemptToken == result.attemptToken,
                  retry.attemptCount == result.attemptCount,
                  retry.retryAt.map({ $0 <= trustedNow }) ?? true else {
                throw RepositoryError.invalidImageResult
            }

            switch result.status {
            case .ready:
                throw RepositoryError.invalidImageResult
            case .failed, .rejectedIdentity:
                let terminal = retry.recordFailure(now: trustedNow, mode: mode, resultHash: resultHash)
                if terminal == .imageUnavailable {
                    retry.terminalStatus = .imageUnavailable
                    retry.terminalResultHash = resultHash
                }
                store.schemaVersion = 2
                store.entries[retryKey(result.eventId)] = retry
                try writeRetryStoreUnlocked(store)
                if terminal == .imageUnavailable {
                    events[index].postcardStatus = .imageUnavailable
                    events[index].postcardRelativePath = nil
                    try writer.write(try encodedJournal(events), to: journalURL)
                }
                return MarkImageAcknowledgement(eventID: result.eventId, status: terminal)
            }
        }
    }

    private func markReadyImage(_ result: ImageResultEnvelope) throws -> MarkImageAcknowledgement {
        try result.requireValidFields()
        let initialEvent: TripEvent = try withExclusiveLock {
            let events = try readEventsUnlocked()
            var store = try loadRetryStoreUnlocked()
            var mutableEvents = events
            try reconcileRetryStoreUnlocked(events: &mutableEvents, store: &store)
            guard let event = mutableEvents.first(where: { $0.id == result.eventId }) else {
                throw RepositoryError.eventNotFound(result.eventId)
            }
            let retry = try retryForEventUnlocked(event, store: &store)
            try requireReadySubmission(result, event: event, retry: retry, resultHash: NarrativeHasher.hash(result))
            return event
        }

        // The bounded read, decode and content hash happen without the global repository lock.
        let validated = try validateReadyImage(result.relativePath, tripID: initialEvent.tripID)
        defer { validated.closeAll() }
        func publish(_ revalidate: () throws -> Void) throws -> MarkImageAcknowledgement {
          imageValidationHook?()
          return try withExclusiveLock {
            var events = try readEventsUnlocked()
            var store = try loadRetryStoreUnlocked()
            try reconcileRetryStoreUnlocked(events: &events, store: &store)
            guard let index = events.firstIndex(where: { $0.id == result.eventId }) else {
                throw RepositoryError.eventNotFound(result.eventId)
            }
            let event = events[index]
            guard try NarrativeHasher.hash(event) == NarrativeHasher.hash(initialEvent) else { throw RepositoryError.invalidImageResult }
            var retry = try retryForEventUnlocked(event, store: &store)
            let resultHash = try NarrativeHasher.hash(result)
            try requireReadySubmission(result, event: event, retry: retry, resultHash: resultHash)
            try requireUnchanged(validated)
            try revalidate()
            try Task.checkCancellation()

            if event.postcardStatus == .ready {
                guard retry.imageContentHash == validated.contentHash else { throw RepositoryError.invalidImageResult }
                return MarkImageAcknowledgement(eventID: result.eventId, status: .ready)
            }

            retry.retryAt = nil
            retry.lastAttemptedAt = result.attemptedAt
            retry.lastResultHash = resultHash
            retry.activeAttemptToken = nil
            retry.leaseExpiresAt = nil
            retry.terminalStatus = .ready
            retry.terminalResultHash = resultHash
            retry.imageContentHash = validated.contentHash
            retry.terminalRelativePath = validated.relativePath
            retry.terminalPresentation = result.presentation
            store.schemaVersion = 2
            store.entries[retryKey(result.eventId)] = retry
            // Persist terminal intent first. Reconciliation can finish the journal after a crash.
            try writeRetryStoreUnlocked(store)
            events[index].postcardStatus = .ready
            events[index].postcardRelativePath = validated.relativePath
            try writer.write(try encodedJournal(events), to: journalURL)
            return MarkImageAcknowledgement(eventID: result.eventId, status: .ready)
          }
        }
        if let reference = result.presentation {
            return try PostcardPresentationStore(root: physicalPresentationRoot()).withValidatedPresentation(reference: reference, event: initialEvent, expectedSourceRelativePath: validated.relativePath) { presentation, revalidate in
                guard presentation.manifest.source.sha256 == validated.contentHash else { throw RepositoryError.invalidImageResult }
                return try publish(revalidate)
            }
        }
        return try publish({})
    }

    private func requireReadySubmission(
        _ result: ImageResultEnvelope,
        event: TripEvent,
        retry: ImageRetry,
        resultHash: String
    ) throws {
        try requireNarrativeHash(event, retry: retry)
        let trustedNow = clock.now
        guard result.publishedNarrativeHash == retry.publishedNarrativeHash else {
            throw RepositoryError.invalidImageResult
        }
        if event.postcardStatus == .ready {
            guard retry.terminalStatus == .ready,
                  retry.terminalResultHash == resultHash,
                  retry.terminalRelativePath == result.relativePath,
                  retry.terminalPresentation == result.presentation,
                  event.postcardRelativePath == result.relativePath else {
                throw RepositoryError.invalidImageTransition
            }
            return
        }
        guard event.postcardStatus == .pendingImage,
              retry.activeAttemptToken == result.attemptToken,
              retry.attemptCount == result.attemptCount,
              retry.leaseExpiresAt.map({ $0 > trustedNow }) == true,
              retry.retryAt.map({ $0 <= trustedNow }) ?? true else {
            throw RepositoryError.invalidImageResult
        }
    }

    private func physicalPresentationRoot() throws -> URL {
        guard let path = realpath(root.path, nil) else { throw RepositoryError.unsafePostcardPath }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path))
    }

    private func presentationReferencesUnlocked(events: [TripEvent]) throws -> [UUID: PostcardPresentationReference] {
        let store = try loadRetryStoreUnlocked()
        var references: [UUID: PostcardPresentationReference] = [:]
        for event in events where event.postcardStatus == .ready {
            if let retry = store.entries[retryKey(event.id)] {
                references[event.id] = retry.currentPresentation ?? retry.terminalPresentation
            }
        }
        return references
    }

    /// Compare-and-swap only the presentation selection; the original terminal result remains replayable.
    @discardableResult
    public func publishPresentation(_ reference: PostcardPresentationReference, for eventID: UUID, expectedSourceSHA256: String, expectedPresentationSHA256: String?) throws -> PostcardPresentationReference {
        try Task.checkCancellation()
        let initial: TripEvent = try withExclusiveLock {
            guard let event = try readEventsUnlocked().first(where: { $0.id == eventID }), event.postcardStatus == .ready else { throw RepositoryError.invalidImageTransition }
            return event
        }
        guard let path = initial.postcardRelativePath else { throw RepositoryError.invalidImageResult }
        return try PostcardPresentationStore(root: physicalPresentationRoot()).withValidatedPresentation(reference: reference, event: initial, expectedSourceRelativePath: path) { presentation, revalidate in
            guard presentation.manifest.source.sha256 == expectedSourceSHA256 else { throw RepositoryError.invalidImageResult }
            imageValidationHook?()
            return try withExclusiveLock {
                guard let event = try readEventsUnlocked().first(where: { $0.id == eventID }), event == initial else { throw RepositoryError.invalidImageTransition }
                var store = try loadRetryStoreUnlocked()
                guard var retry = store.entries[retryKey(eventID)], retry.terminalStatus == .ready,
                      retry.terminalRelativePath == path, retry.imageContentHash == expectedSourceSHA256,
                      (retry.currentPresentation ?? retry.terminalPresentation)?.sha256 == expectedPresentationSHA256 else { throw RepositoryError.invalidImageResult }
                try requireNarrativeHash(event, retry: retry)
                try revalidate()
                try Task.checkCancellation()
                retry.currentPresentation = reference
                store.entries[retryKey(eventID)] = retry
                try writeRetryStoreUnlocked(store)
                return reference
            }
        }
    }

    func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        let descriptor = open(
            lockURL.path,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw RepositoryError.lockFailure(code: errno)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            _ = close(descriptor)
            if code == EWOULDBLOCK { throw RepositoryError.lockUnavailable }
            throw RepositoryError.lockFailure(code: code)
        }
        defer {
            _ = flock(descriptor, LOCK_UN)
            _ = close(descriptor)
        }
        return try body()
    }

    private func bootstrap() throws {
        let fileManager = FileManager.default
        for directory in ["state", "journal", "postcards", "inbox"] {
            try fileManager.createDirectory(
                at: root.appendingPathComponent(directory, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        try createIfAbsent(
            data: JSONEncoder.travelCat.encode(TripSnapshot.empty(now: clock.now)),
            at: snapshotURL
        )
        try createIfAbsent(data: Data(), at: journalURL)
    }

    private func retryKey(_ id: UUID) -> String { id.uuidString.lowercased() }

    private func loadRetryStoreUnlocked() throws -> ImageRetryStore {
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard rootFD >= 0 else { throw RepositoryError.malformedImageRetryState }
        defer { _ = close(rootFD) }
        let stateFD = openat(rootFD, "state", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard stateFD >= 0 else { throw RepositoryError.malformedImageRetryState }
        defer { _ = close(stateFD) }
        let descriptor = openat(stateFD, "image-retries.json", O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ENOENT { return ImageRetryStore() }
            throw RepositoryError.malformedImageRetryState
        }
        defer { _ = close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1,
              info.st_size > 0,
              info.st_size <= off_t(StrictJSONPreflight.maximumBytes) else {
            throw RepositoryError.malformedImageRetryState
        }
        do {
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            let data = try handle.readToEnd() ?? Data()
            guard data.count == Int(info.st_size) else {
                throw RepositoryError.malformedImageRetryState
            }
            try StrictJSONPreflight.validate(data)
            return try JSONDecoder.travelCat.decode(ImageRetryStore.self, from: data).validated()
        } catch let error as RepositoryError {
            throw error
        } catch {
            throw RepositoryError.malformedImageRetryState
        }
    }

    private func writeRetryStoreUnlocked(_ store: ImageRetryStore) throws {
        var upgraded = store
        upgraded.schemaVersion = 2
        try writer.write(JSONEncoder.travelCat.encode(try upgraded.validated()), to: imageRetryURL)
    }

    private func retryForPendingEventUnlocked(_ event: TripEvent, store: inout ImageRetryStore) throws -> ImageRetry {
        let retry = try retryForEventUnlocked(event, store: &store)
        try requireNarrativeHash(event, retry: retry)
        return retry
    }

    private func retryForEventUnlocked(_ event: TripEvent, store: inout ImageRetryStore) throws -> ImageRetry {
        let key = retryKey(event.id)
        if let retry = store.entries[key] { return retry }
        let retry = ImageRetry(
            attemptCount: 0,
            retryAt: nil,
            publishedNarrativeHash: try NarrativeHasher.hash(event)
        )
        store.entries[key] = retry
        try writeRetryStoreUnlocked(store)
        return retry
    }

    private func requireNarrativeHash(_ event: TripEvent, retry: ImageRetry) throws {
        guard try NarrativeHasher.hash(event) == retry.publishedNarrativeHash else {
            throw RepositoryError.narrativeChanged(event.id)
        }
    }

    private func reconcileRetryStoreUnlocked(events: inout [TripEvent], store: inout ImageRetryStore) throws {
        var changedJournal = false
        var changedStore = false
        let isLegacyStore = store.schemaVersion == 1
        for index in events.indices where events[index].postcardStatus != .none {
            let key = retryKey(events[index].id)
            if store.entries[key] == nil {
                var migrated = ImageRetry(
                    attemptCount: 0,
                    retryAt: nil,
                    publishedNarrativeHash: try NarrativeHasher.hash(events[index])
                )
                if events[index].postcardStatus == .ready,
                   let path = events[index].postcardRelativePath,
                   let image = try? validateStoredReadyImage(path, tripID: events[index].tripID) {
                    defer { image.closeAll() }
                    migrated.terminalStatus = .ready
                    migrated.imageContentHash = image.contentHash
                    migrated.terminalRelativePath = path
                } else if events[index].postcardStatus == .imageUnavailable {
                    migrated.terminalStatus = .imageUnavailable
                }
                store.entries[key] = migrated
                changedStore = true
            }
            guard var retry = store.entries[key] else {
                throw RepositoryError.malformedImageRetryState
            }
            if isLegacyStore, retry.terminalStatus == nil, events[index].postcardStatus == .ready,
               let path = events[index].postcardRelativePath {
                let image = try validateStoredReadyImage(path, tripID: events[index].tripID)
                defer { image.closeAll() }
                retry.terminalStatus = .ready
                retry.terminalRelativePath = path
                retry.imageContentHash = image.contentHash
                // A v1 result hash covered the old envelope shape, so replay stays fail-closed.
                retry.terminalResultHash = nil
                store.entries[key] = retry
                changedStore = true
            } else if isLegacyStore, retry.terminalStatus == nil,
                      events[index].postcardStatus == .imageUnavailable {
                retry.terminalStatus = .imageUnavailable
                retry.terminalResultHash = nil
                store.entries[key] = retry
                changedStore = true
            }
            try requireNarrativeHash(events[index], retry: retry)
            guard retry.attemptCount == 0 ? retry.retryAt == nil : (retry.attemptCount >= 3 || retry.retryAt != nil || retry.terminalStatus == .ready) else {
                throw RepositoryError.malformedImageRetryState
            }
            if events[index].postcardStatus == .pendingImage, retry.terminalStatus == .ready {
                guard let path = retry.terminalRelativePath,
                      retry.currentPresentation == nil,
                      retry.terminalResultHash != nil,
                      retry.imageContentHash != nil else { throw RepositoryError.malformedImageRetryState }
                let image = try validateReadyImage(path, tripID: events[index].tripID)
                defer { image.closeAll() }
                guard image.contentHash == retry.imageContentHash else { throw RepositoryError.malformedImageRetryState }
                if let reference = retry.terminalPresentation {
                    try PostcardPresentationStore(root: physicalPresentationRoot()).withValidatedPresentation(reference: reference, event: events[index], expectedSourceRelativePath: path) { presentation, revalidate in
                        guard presentation.manifest.source.sha256 == image.contentHash else { throw RepositoryError.malformedImageRetryState }
                        try requireUnchanged(image)
                        try revalidate()
                        events[index].postcardStatus = .ready
                        events[index].postcardRelativePath = path
                        // Keep verified descriptors alive through the recovery journal write.
                        try writer.write(try encodedJournal(events), to: journalURL)
                        changedJournal = false
                    }
                }
                events[index].postcardStatus = .ready
                events[index].postcardRelativePath = path
                changedJournal = retry.terminalPresentation == nil || changedJournal
            } else if events[index].postcardStatus == .pendingImage,
                      retry.attemptCount >= 3 || retry.terminalStatus == .imageUnavailable {
                events[index].postcardStatus = .imageUnavailable
                events[index].postcardRelativePath = nil
                changedJournal = true
            } else if events[index].postcardStatus == .ready {
                guard retry.terminalStatus == .ready,
                      retry.terminalRelativePath == events[index].postcardRelativePath else {
                    throw RepositoryError.malformedImageRetryState
                }
            } else if events[index].postcardStatus == .imageUnavailable {
                guard retry.terminalStatus == .imageUnavailable else {
                    throw RepositoryError.malformedImageRetryState
                }
            }
        }
        let eventKeys = Set(events.lazy.filter { $0.postcardStatus != .none }.map { self.retryKey($0.id) })
        guard Set(store.entries.keys).isSubset(of: eventKeys) else {
            throw RepositoryError.malformedImageRetryState
        }
        if isLegacyStore { store.schemaVersion = 2; changedStore = true }
        if changedStore { try writeRetryStoreUnlocked(store) }
        if changedJournal { try writer.write(try encodedJournal(events), to: journalURL) }
    }

    private struct ValidatedImage {
        let descriptor: Int32
        let tripDescriptor: Int32
        let parentDescriptors: [Int32]
        let postcardsInfo: stat
        let tripInfo: stat
        let tripComponent: String
        let filename: String
        let relativePath: String
        let fileInfo: stat
        let contentHash: String

        func closeAll() {
            _ = close(descriptor)
            parentDescriptors.reversed().forEach { _ = close($0) }
        }
    }

    private func validateReadyImage(_ path: String?, tripID: UUID) throws -> ValidatedImage {
        try validateReadyImage(path, tripID: tripID, allowLegacyStoredPath: false)
    }

    private func validateStoredReadyImage(_ path: String?, tripID: UUID) throws -> ValidatedImage {
        try validateReadyImage(path, tripID: tripID, allowLegacyStoredPath: true)
    }

    private func validateReadyImage(
        _ path: String?,
        tripID: UUID,
        allowLegacyStoredPath: Bool
    ) throws -> ValidatedImage {
        guard let path else { throw RepositoryError.unsafePostcardPath }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let tripComponent = tripID.uuidString.lowercased()
        let allowedFilenameBytes = Set("abcdefghijklmnopqrstuvwxyz0123456789._-".utf8)
        let directoryComponent: String
        let filename: String
        if components.count == 3,
           components[0] == "postcards",
           components[1] == tripComponent,
           path == "postcards/\(tripComponent)/\(components[2])" {
            directoryComponent = tripComponent
            filename = components[2]
        } else if allowLegacyStoredPath,
                  components.count == 2,
                  !components[0].isEmpty,
                  components[0] != ".",
                  components[0] != "..",
                  components[0].utf8.allSatisfy(allowedFilenameBytes.contains),
                  path == "\(components[0])/\(components[1])" {
            directoryComponent = components[0]
            filename = components[1]
        } else {
            throw RepositoryError.unsafePostcardPath
        }
        guard
              !filename.isEmpty,
              filename.first?.isLetter == true || filename.first?.isNumber == true,
              filename.utf8.allSatisfy(allowedFilenameBytes.contains) else {
            throw RepositoryError.unsafePostcardPath
        }
        let extensionName = (filename as NSString).pathExtension.lowercased()
        guard extensionName == "png" || extensionName == "webp" else {
            throw RepositoryError.invalidImageResult
        }
        let rootDescriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard rootDescriptor >= 0 else { throw RepositoryError.unsafePostcardPath }
        var parents = [rootDescriptor]
        func fail(_ error: RepositoryError) throws -> Never {
            parents.reversed().forEach { _ = close($0) }
            throw error
        }
        let postcardsDescriptor = openat(rootDescriptor, "postcards", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard postcardsDescriptor >= 0 else { try fail(.unsafePostcardPath) }
        parents.append(postcardsDescriptor)
        var postcardsInfo = stat()
        guard fstat(postcardsDescriptor, &postcardsInfo) == 0,
              (postcardsInfo.st_mode & S_IFMT) == S_IFDIR else { try fail(.unsafePostcardPath) }
        let tripDescriptor = openat(postcardsDescriptor, directoryComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard tripDescriptor >= 0 else { try fail(.unsafePostcardPath) }
        parents.append(tripDescriptor)
        var tripInfo = stat()
        guard fstat(tripDescriptor, &tripInfo) == 0,
              (tripInfo.st_mode & S_IFMT) == S_IFDIR else { try fail(.unsafePostcardPath) }
        let descriptor = openat(tripDescriptor, filename, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { try fail(.invalidImageResult) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1 else {
            _ = close(descriptor)
            try fail(.invalidImageResult)
        }
        guard info.st_size > 0, info.st_size <= 15 * 1_024 * 1_024 else {
            _ = close(descriptor)
            try fail(.invalidImageResult)
        }
        do {
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            let data = try handle.readToEnd() ?? Data()
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetCount(source) > 0,
                  let actualType = CGImageSourceGetType(source) as String?,
                  (extensionName == "png" ? actualType == UTType.png.identifier : actualType == UTType.webP.identifier),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                  width.intValue >= 768,
                  height.intValue >= 768,
                  width.intValue <= 32_768,
                  height.intValue <= 32_768,
                  Int64(width.intValue) * Int64(height.intValue) <= 100_000_000,
                  CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 256,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                  ] as CFDictionary) != nil else {
                throw RepositoryError.invalidImageResult
            }
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return ValidatedImage(
                descriptor: descriptor, tripDescriptor: tripDescriptor, parentDescriptors: parents,
                postcardsInfo: postcardsInfo, tripInfo: tripInfo, tripComponent: directoryComponent,
                filename: filename, relativePath: path, fileInfo: info, contentHash: hash
            )
        } catch {
            _ = close(descriptor)
            parents.reversed().forEach { _ = close($0) }
            throw error
        }
    }

    private func requireUnchanged(_ image: ValidatedImage) throws {
        var descriptorInfo = stat()
        var pathInfo = stat()
        var postcardsPathInfo = stat()
        var tripPathInfo = stat()
        guard image.parentDescriptors.count == 3 else { throw RepositoryError.invalidImageResult }
        let rootDescriptor = image.parentDescriptors[0]
        let postcardsDescriptor = image.parentDescriptors[1]
        guard fstat(image.descriptor, &descriptorInfo) == 0,
              fstatat(rootDescriptor, "postcards", &postcardsPathInfo, AT_SYMLINK_NOFOLLOW) == 0,
              fstatat(postcardsDescriptor, image.tripComponent, &tripPathInfo, AT_SYMLINK_NOFOLLOW) == 0,
              fstatat(image.tripDescriptor, image.filename, &pathInfo, AT_SYMLINK_NOFOLLOW) == 0,
              (postcardsPathInfo.st_mode & S_IFMT) == S_IFDIR,
              (tripPathInfo.st_mode & S_IFMT) == S_IFDIR,
              postcardsPathInfo.st_dev == image.postcardsInfo.st_dev,
              postcardsPathInfo.st_ino == image.postcardsInfo.st_ino,
              tripPathInfo.st_dev == image.tripInfo.st_dev,
              tripPathInfo.st_ino == image.tripInfo.st_ino,
              (pathInfo.st_mode & S_IFMT) == S_IFREG,
              descriptorInfo.st_nlink == 1,
              pathInfo.st_nlink == 1,
              descriptorInfo.st_dev == image.fileInfo.st_dev,
              descriptorInfo.st_ino == image.fileInfo.st_ino,
              descriptorInfo.st_size == image.fileInfo.st_size,
              pathInfo.st_dev == image.fileInfo.st_dev,
              pathInfo.st_ino == image.fileInfo.st_ino,
              pathInfo.st_size == image.fileInfo.st_size,
              pathInfo.st_mtimespec.tv_sec == image.fileInfo.st_mtimespec.tv_sec,
              pathInfo.st_mtimespec.tv_nsec == image.fileInfo.st_mtimespec.tv_nsec,
              pathInfo.st_ctimespec.tv_sec == image.fileInfo.st_ctimespec.tv_sec,
              pathInfo.st_ctimespec.tv_nsec == image.fileInfo.st_ctimespec.tv_nsec else {
            throw RepositoryError.invalidImageResult
        }
    }

    private func createIfAbsent(data: Data, at url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).bootstrap.tmp")
        defer {
            try? FileManager.default.removeItem(at: temporary)
        }
        try data.write(to: temporary, options: .withoutOverwriting)
        guard link(temporary.path, url.path) == 0 else {
            if errno == EEXIST { return }
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func loadSnapshotUnlocked() throws -> TripSnapshot {
        try JSONDecoder.travelCat.decode(TripSnapshot.self, from: Data(contentsOf: snapshotURL))
    }

    private func readEventsUnlocked() throws -> [TripEvent] {
        let data = try Data(contentsOf: journalURL)
        guard let text = String(data: data, encoding: .utf8) else {
            throw RepositoryError.malformedJournal(line: 1, reason: "journal is not UTF-8")
        }

        var result: [TripEvent] = []
        for (offset, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            do {
                result.append(try JSONDecoder.travelCat.decode(TripEvent.self, from: Data(line.utf8)))
            } catch {
                throw RepositoryError.malformedJournal(line: offset + 1, reason: String(describing: error))
            }
        }
        return result
    }

    private func appendEventUnlocked(_ event: TripEvent) throws {
        var record = try compactEncoder().encode(event)
        record.append(0x0A)
        let descriptor = open(journalURL.path, O_WRONLY | O_APPEND)
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { _ = close(descriptor) }

        try record.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let count = Darwin.write(descriptor, baseAddress.advanced(by: written), rawBuffer.count - written)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw CocoaError(.fileWriteUnknown)
                }
                written += count
            }
        }
        guard fsync(descriptor) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func encodedJournal(_ events: [TripEvent]) throws -> Data {
        let encoder = compactEncoder()
        return try events.reduce(into: Data()) { data, event in
            data.append(try encoder.encode(event))
            data.append(0x0A)
        }
    }

    private func compactEncoder() -> JSONEncoder {
        let encoder = JSONEncoder.travelCat
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func rebuildSnapshot(from events: [TripEvent]) throws -> TripSnapshot {
        guard let last = events.last else {
            return .empty(now: Date(timeIntervalSince1970: 0))
        }

        try validateJournalChain(events)

        let currentTripStart = events.lastIndex(where: { $0.tripID != last.tripID })
            .map { events.index(after: $0) } ?? events.startIndex
        let currentTripEvents = events[currentTripStart...]

        return TripSnapshot(
            stateVersion: events.count,
            tripID: last.tripID,
            lastEventID: last.id,
            phase: last.phase,
            nextActionAt: last.occurredAt,
            lastUpdatedAt: last.occurredAt,
            carriedItemID: nil,
            usedItemIDs: Set(currentTripEvents.compactMap(\.consumedItemID)),
            visitedPlaces: currentTripEvents.compactMap { $0.location?.place },
            mood: last.mood,
            openHook: last.openHook
        )
    }

    private func recoverInterruptedPublicationUnlocked(
        snapshot: TripSnapshot,
        events: [TripEvent]
    ) throws {
        do {
            try requireAligned(snapshot: snapshot, events: events)
            return
        } catch RepositoryError.recoveryRequired {
            // Only the event-first publication crash window is automatic: the persisted
            // snapshot must be an exact, valid prefix and the journal must have one valid tail.
        }

        guard snapshot.stateVersion >= 0,
              events.count == snapshot.stateVersion + 1,
              let event = events.last else {
            // Preserve the explicit recovery contract for every other mismatch. The public
            // aligned reads remain fail-closed with recoveryRequired and no files are rewritten.
            return
        }
        let prefix = Array(events.dropLast())
        try requireRecoverablePrefix(snapshot: snapshot, events: prefix)
        try validateJournalChain(events)
        try validateInterruptedPublication(event, previous: snapshot)
        try writer.write(JSONEncoder.travelCat.encode(
            recoveredSnapshot(appending: event, to: snapshot)
        ), to: snapshotURL)
    }

    private func requireRecoverablePrefix(snapshot: TripSnapshot, events: [TripEvent]) throws {
        try requireAligned(snapshot: snapshot, events: events)
        try validateJournalChain(events)
        guard let last = events.last else {
            let canonical = TripSnapshot.empty(now: snapshot.lastUpdatedAt)
            guard snapshot.schemaVersion == canonical.schemaVersion,
                  snapshot.nextActionAt == snapshot.lastUpdatedAt,
                  snapshot.mood == canonical.mood,
                  snapshot.usedItemIDs.isEmpty,
                  snapshot.visitedPlaces.isEmpty,
                  snapshot.openHook == nil else {
                throw RepositoryError.recoveryRequired
            }
            return
        }
        let currentTripStart = events.lastIndex(where: { $0.tripID != last.tripID })
            .map { events.index(after: $0) } ?? events.startIndex
        let currentTripEvents = events[currentTripStart...]
        guard snapshot.lastUpdatedAt == last.occurredAt,
              snapshot.nextActionAt >= snapshot.lastUpdatedAt,
              snapshot.usedItemIDs == Set(currentTripEvents.compactMap(\.consumedItemID)),
              snapshot.visitedPlaces == currentTripEvents.compactMap({ $0.location?.place }),
              snapshot.mood == last.mood,
              snapshot.openHook == last.openHook else {
            throw RepositoryError.recoveryRequired
        }
    }

    private func validateInterruptedPublication(_ event: TripEvent, previous: TripSnapshot) throws {
        guard (event.postcardStatus == .none || event.postcardStatus == .pendingImage),
              event.postcardRelativePath == nil,
              event.previousEventID == previous.lastEventID,
              event.occurredAt >= previous.lastUpdatedAt else {
            throw RepositoryError.recoveryRequired
        }
        let startsNewTrip = previous.tripID == nil
            || (previous.phase == .resting && event.phase == .preparing && previous.tripID != event.tripID)
        var effectivePrevious = previous
        if startsNewTrip {
            effectivePrevious.usedItemIDs = []
            effectivePrevious.visitedPlaces = []
        }
        guard (event.consumedItemID == nil || event.consumedItemID == previous.carriedItemID),
              ContinuityValidator().violations(event: event, previous: effectivePrevious).isEmpty else {
            throw RepositoryError.continuityConflict
        }
        if event.phase == .exploring || event.phase == .postcardReady {
            guard event.location != nil else { throw RepositoryError.continuityConflict }
        } else if event.phase == .resting || event.phase == .preparing {
            guard event.location == nil else { throw RepositoryError.continuityConflict }
        }
        guard (event.phase == .postcardReady) == (event.postcardStatus == .pendingImage) else {
            throw RepositoryError.invalidImageTransition
        }
    }

    private func recoveredSnapshot(appending event: TripEvent, to previous: TripSnapshot) -> TripSnapshot {
        let startsNewTrip = previous.tripID == nil
            || (previous.phase == .resting && event.phase == .preparing && previous.tripID != event.tripID)
        var usedItemIDs = startsNewTrip ? Set<String>() : previous.usedItemIDs
        var visitedPlaces = startsNewTrip ? [] : previous.visitedPlaces
        if let consumedItemID = event.consumedItemID { usedItemIDs.insert(consumedItemID) }
        if let place = event.location?.place { visitedPlaces.append(place) }
        return TripSnapshot(
            schemaVersion: previous.schemaVersion,
            stateVersion: previous.stateVersion + 1,
            tripID: event.tripID,
            lastEventID: event.id,
            phase: event.phase,
            nextActionAt: event.occurredAt,
            lastUpdatedAt: event.occurredAt,
            carriedItemID: event.consumedItemID == nil ? previous.carriedItemID : nil,
            usedItemIDs: usedItemIDs,
            visitedPlaces: visitedPlaces,
            mood: event.mood,
            openHook: event.openHook
        )
    }

    private func validateJournalChain(_ events: [TripEvent]) throws {
        var seen = Set<UUID>()
        var expectedPreviousID: UUID?
        var previousEvent: TripEvent?
        for event in events {
            guard seen.insert(event.id).inserted else {
                throw RepositoryError.duplicateEventID(event.id)
            }
            guard event.previousEventID == expectedPreviousID else {
                throw RepositoryError.brokenJournalChain
            }
            if let previousEvent {
                if previousEvent.tripID == event.tripID {
                    do {
                        try TravelStateMachine().requireTransition(
                            from: previousEvent.phase,
                            to: event.phase
                        )
                    } catch {
                        throw RepositoryError.continuityConflict
                    }
                } else {
                    guard previousEvent.phase == .resting, event.phase == .preparing else {
                        throw RepositoryError.continuityConflict
                    }
                }
            } else {
                guard event.phase == .preparing else {
                    throw RepositoryError.continuityConflict
                }
            }
            expectedPreviousID = event.id
            previousEvent = event
        }
    }

    private func requireAligned(snapshot: TripSnapshot, events: [TripEvent]) throws {
        guard snapshot.stateVersion == events.count else {
            throw RepositoryError.recoveryRequired
        }
        guard let tail = events.last else {
            guard snapshot.lastEventID == nil,
                  snapshot.tripID == nil,
                  snapshot.phase == .resting else {
                throw RepositoryError.recoveryRequired
            }
            return
        }
        guard snapshot.lastEventID == tail.id,
              snapshot.tripID == tail.tripID,
              snapshot.phase == tail.phase else {
            throw RepositoryError.recoveryRequired
        }
    }

    private func copyRegularFile(_ source: URL, to destination: URL) throws {
        var info = stat()
        guard lstat(source.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw RepositoryError.unsafePostcardPath
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private func copyOptionalRegularFile(_ source: URL, to destination: URL) throws {
        try requireRealDirectoryChain(to: source.deletingLastPathComponent())
        var info = stat()
        if lstat(source.path, &info) != 0 {
            guard errno == ENOENT else { throw RepositoryError.unsafePostcardPath }
            return
        }
        try copyRegularFile(source, to: destination)
    }

    private func copyOptionalTreeWithoutLinks(
        _ source: URL,
        to destination: URL,
        skippingTransientFiles: Bool
    ) throws {
        try requireRealDirectoryChain(to: source.deletingLastPathComponent())
        var info = stat()
        if lstat(source.path, &info) != 0 {
            guard errno == ENOENT else { throw RepositoryError.unsafePostcardPath }
            return
        }
        try copyTreeWithoutLinks(
            source,
            to: destination,
            skippingTransientFiles: skippingTransientFiles
        )
    }

    private func requireRealDirectoryChain(to directory: URL) throws {
        let rootPath = root.standardizedFileURL.path
        let directoryPath = directory.standardizedFileURL.path
        guard directoryPath == rootPath || directoryPath.hasPrefix(rootPath + "/") else {
            throw RepositoryError.unsafePostcardPath
        }
        var candidate = root
        var info = stat()
        guard lstat(candidate.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw RepositoryError.unsafePostcardPath
        }
        guard directoryPath != rootPath else { return }
        let relative = directoryPath.dropFirst(rootPath.count + 1)
        for component in relative.split(separator: "/") {
            candidate.appendPathComponent(String(component), isDirectory: true)
            guard lstat(candidate.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
                throw RepositoryError.unsafePostcardPath
            }
        }
    }

    private func copyTreeWithoutLinks(
        _ source: URL,
        to destination: URL,
        skippingTransientFiles: Bool = true
    ) throws {
        let fileManager = FileManager.default
        var info = stat()
        guard lstat(source.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw RepositoryError.unsafePostcardPath
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for item in try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            let name = item.lastPathComponent
            if skippingTransientFiles, (name.hasPrefix(".") || name.hasSuffix(".tmp")) { continue }
            var childInfo = stat()
            guard lstat(item.path, &childInfo) == 0 else { throw RepositoryError.unsafePostcardPath }
            let target = destination.appendingPathComponent(item.lastPathComponent)
            switch childInfo.st_mode & S_IFMT {
            case S_IFDIR:
                try copyTreeWithoutLinks(
                    item,
                    to: target,
                    skippingTransientFiles: skippingTransientFiles
                )
            case S_IFREG:
                try copyRegularFile(item, to: target)
            default:
                throw RepositoryError.unsafePostcardPath
            }
        }
    }

    private func isIdempotentRetry(stored: TripEvent, supplied: TripEvent) -> Bool {
        let canonicalStored = eventWithFrozenProfile(stored, profile: stored.characterProfile)
        let canonicalSupplied = eventWithFrozenProfile(supplied, profile: supplied.characterProfile)
        // Only an actually absent caller profile inherits server enrichment. An
        // explicit default must not masquerade as a missing custom identity.
        let normalizedSupplied = supplied.characterProfile == nil && canonicalStored.characterProfile != nil
            ? eventWithFrozenProfile(supplied, profile: canonicalStored.characterProfile)
            : canonicalSupplied
        if canonicalStored == normalizedSupplied { return true }
        guard normalizedSupplied.postcardStatus == .pendingImage,
              normalizedSupplied.postcardRelativePath == nil,
              stored.postcardStatus == .ready
                || stored.postcardStatus == .imageUnavailable
                || stored.postcardStatus == .rejected else {
            return false
        }

        var normalizedStored = canonicalStored
        normalizedStored.postcardStatus = .pendingImage
        normalizedStored.postcardRelativePath = nil
        return normalizedStored == normalizedSupplied
    }

    private struct CharacterAnchor: Codable {
        let version: Int
        let stateVersion: Int
        let lastEventID: UUID?
        let snapshotLastUpdatedAt: Date
        let claimedAt: Date
        let profileFingerprint: String
        let profile: CharacterProfile
    }

    private func effectiveProfileUnlocked(snapshot: TripSnapshot, events: [TripEvent]) throws -> CharacterProfile {
        try frozenEffectiveProfileUnlocked(snapshot: snapshot, events: events)
            ?? CharacterProfileStore(dataRoot: root).selectedProfile()
    }

    private func frozenEffectiveProfileUnlocked(snapshot: TripSnapshot, events: [TripEvent]) throws -> CharacterProfile? {
        if let tripID = snapshot.tripID, snapshot.phase != .resting {
            return try profileForTripUnlocked(tripID, events: events)
        }
        if let anchor = try readCharacterAnchorUnlocked(), try anchorMatchesCurrentBoundary(anchor, snapshot: snapshot) {
            return try validateAnchorProfile(anchor)
        }
        return nil
    }

    private func profileForTripUnlocked(_ tripID: UUID, events: [TripEvent]) throws -> CharacterProfile {
        let profile = events.first(where: { $0.tripID == tripID })?.characterProfile ?? .defaultBlackCat
        return try CharacterProfileStore(dataRoot: root).validatedProfile(profile)
    }

    private func frozenProfileForBoundaryUnlocked(snapshot: TripSnapshot, claimedAt: Date) throws -> CharacterProfile {
        if let anchor = try readCharacterAnchorUnlocked(),
           anchor.stateVersion == snapshot.stateVersion,
           anchor.lastEventID == snapshot.lastEventID,
           try anchorMatchesCurrentBoundary(anchor, snapshot: snapshot) {
            return try validateAnchorProfile(anchor)
        }
        let profile = try CharacterProfileStore(dataRoot: root).selectedProfile()
        let anchor = CharacterAnchor(version: 1, stateVersion: snapshot.stateVersion, lastEventID: snapshot.lastEventID, snapshotLastUpdatedAt: snapshot.lastUpdatedAt, claimedAt: claimedAt, profileFingerprint: try profileFingerprint(profile), profile: profile)
        try writer.write(JSONEncoder.travelCat.encode(anchor), to: characterAnchorURL)
        return profile
    }

    private func anchoredProfileForPublishUnlocked(snapshot: TripSnapshot) throws -> CharacterProfile {
        if let anchor = try readCharacterAnchorUnlocked(),
           anchor.stateVersion == snapshot.stateVersion,
           anchor.lastEventID == snapshot.lastEventID,
           try anchorMatchesCurrentBoundary(anchor, snapshot: snapshot) {
            return try validateAnchorProfile(anchor)
        }
        return try frozenProfileForBoundaryUnlocked(snapshot: snapshot, claimedAt: clock.now)
    }

    private func validateAnchorProfile(_ anchor: CharacterAnchor) throws -> CharacterProfile {
        guard anchor.version == 1,
              anchor.profileFingerprint == (try profileFingerprint(anchor.profile)) else {
            throw RepositoryError.recoveryRequired
        }
        do { return try CharacterProfileStore(dataRoot: root).validatedProfile(anchor.profile) }
        catch { throw RepositoryError.recoveryRequired }
    }

    private func anchorMatchesCurrentBoundary(_ anchor: CharacterAnchor, snapshot: TripSnapshot) throws -> Bool {
        return anchor.stateVersion == snapshot.stateVersion
            && anchor.lastEventID == snapshot.lastEventID
            && anchor.snapshotLastUpdatedAt == snapshot.lastUpdatedAt
    }

    private func profileFingerprint(_ profile: CharacterProfile) throws -> String {
        SHA256.hash(data: try JSONEncoder.travelCat.encode(profile)).map { String(format: "%02x", $0) }.joined()
    }

    private func readCharacterAnchorUnlocked() throws -> CharacterAnchor? {
        var info = stat()
        guard lstat(characterAnchorURL.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw RepositoryError.recoveryRequired
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
              info.st_size > 0, info.st_size <= off_t(StrictJSONPreflight.maximumBytes) else {
            throw RepositoryError.recoveryRequired
        }
        do {
            let data = try Data(contentsOf: characterAnchorURL)
            try StrictJSONPreflight.validate(data)
            return try JSONDecoder.travelCat.decode(CharacterAnchor.self, from: data)
        } catch { throw RepositoryError.recoveryRequired }
    }

    private func eventWithFrozenProfile(_ event: TripEvent, profile: CharacterProfile?) -> TripEvent {
        TripEvent(id: event.id, tripID: event.tripID, previousEventID: event.previousEventID,
                  occurredAt: event.occurredAt, phase: event.phase, location: event.location,
                  transport: event.transport, summary: event.summary, mood: event.mood,
                  continuityReferences: event.continuityReferences, openHook: event.openHook,
                  consumedItemID: event.consumedItemID, postcardStatus: event.postcardStatus,
                  postcardRelativePath: event.postcardRelativePath,
                  characterProfile: profile == .defaultBlackCat ? nil : profile)
    }
}
