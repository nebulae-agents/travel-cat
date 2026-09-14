import Darwin
import CryptoKit
import Foundation
import TravelCore

public enum PetTravelPromptDelivery: Codable, Equatable, Sendable {
    case prompt(PetTravelPrompt)
    case summary(promptIDs: [String], count: Int)

    public var identifiers: [String] {
        switch self {
        case let .prompt(prompt): [prompt.identifier]
        case let .summary(promptIDs, _): promptIDs
        }
    }
}

public enum PetTravelPromptCoordinatorError: Error, Equatable, Sendable {
    case corruptValue(String)
    case encodingFailed(String)
    case persistenceFailed(String)
    case repositoryUnavailable(String)
    case repositoryInvalid(String)
    case invalidAcknowledgement
}

@MainActor
public final class PetTravelPromptCoordinator {
    private enum QueueKind: String, Codable, Sendable {
        case ordinary
        case deferred
    }

    private struct QueuedPrompt: Codable, Equatable, Sendable {
        let sequence: UInt64
        let kind: QueueKind
        let prompt: PetTravelPrompt
    }

    private struct StoredSummary: Codable, Equatable, Sendable {
        let promptIDs: [String]
        let count: Int
        let throughSequence: UInt64

        var delivery: PetTravelPromptDelivery {
            .summary(promptIDs: promptIDs, count: count)
        }
    }

    private struct Envelope: Codable, Equatable, Sendable {
        let schemaVersion: Int
        var nextSequence: UInt64
        var queue: [QueuedPrompt]
        var summary: StoredSummary?
        var observation: ObservationCursor?

        static let empty = Envelope(
            schemaVersion: 2,
            nextSequence: 0,
            queue: [],
            summary: nil,
            observation: nil
        )
    }

    private struct ObservationCursor: Codable, Equatable, Sendable {
        let observedEventCount: Int
        let firstObservedEventID: UUID?
        let lastObservedEventID: UUID?
        let normalizedPrefixDigest: String
        let pendingImageEventIDs: [UUID]
    }

    private struct DeliveryOwnership {
        let lockDescriptor: Int32
        let rootDescriptor: Int32
    }

    private struct DirectoryIdentity {
        let device: dev_t
        let inode: ino_t

        init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
        }

        func matches(_ info: stat) -> Bool {
            info.st_dev == device && info.st_ino == inode
        }
    }

    private static let stateDirectoryName = "state"
    private static let stateFileName = PetTravelPromptStore.databaseName
    private static let lockDirectoryName = "travel-cat-pet-prompt-locks-v1"
    /// Outstanding prompts can legitimately include a long offline catch-up;
    /// the durable observation cursor itself remains constant-size apart from
    /// currently pending postcard-image identifiers.
    private static let maximumStateBytes = 16 * 1_048_576

    private let repository: TravelRepository
    private let root: URL
    private let rootIdentity: DirectoryIdentity
    private let statePath: String
    private let store: PetTravelPromptStore
    private var inFlight: PetTravelPromptDelivery?
    private var deliveryOwnership: DeliveryOwnership?

    // Internal deterministic race hook. Tests swap the visible state path after
    // this coordinator has anchored the trusted directory descriptor.
    var afterOpeningStateDirectory: (() -> Void)?
    var afterAcquiringDeliveryOwnership: (() -> Void)?
    var afterBeginningPromptTransaction: ((String) -> Void)?
    var beforeCommittingPromptTransaction: ((String) -> Void)?
    var afterCommittingPromptTransaction: ((String) throws -> Void)?
    var beforeInstallingPromptBootstrap: ((String) -> Void)?
    var rootDirectorySync: (Int32) -> Int32

    public init(repository: TravelRepository) throws {
        self.repository = repository
        let standardizedRoot = repository.root.standardizedFileURL
        let canonicalRoot = standardizedRoot.resolvingSymlinksInPath().standardizedFileURL
        guard standardizedRoot.path == canonicalRoot.path else {
            throw PetTravelPromptCoordinatorError.corruptValue(standardizedRoot.path)
        }
        root = canonicalRoot
        let rootDescriptor = open(
            canonicalRoot.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootDescriptor >= 0 else {
            throw PetTravelPromptCoordinatorError.corruptValue(canonicalRoot.path)
        }
        var rootInfo = stat()
        guard fstat(rootDescriptor, &rootInfo) == 0,
              (rootInfo.st_mode & S_IFMT) == S_IFDIR,
              rootInfo.st_uid == geteuid(),
              rootInfo.st_mode & mode_t(0o022) == 0 else {
            _ = close(rootDescriptor)
            throw PetTravelPromptCoordinatorError.corruptValue(canonicalRoot.path)
        }
        rootIdentity = DirectoryIdentity(rootInfo)
        _ = close(rootDescriptor)
        statePath = self.root
            .appendingPathComponent(Self.stateDirectoryName, isDirectory: true)
            .appendingPathComponent(Self.stateFileName)
            .path
        store = PetTravelPromptStore(statePath: statePath)
        inFlight = nil
        deliveryOwnership = nil
        afterOpeningStateDirectory = nil
        afterAcquiringDeliveryOwnership = nil
        afterBeginningPromptTransaction = nil
        beforeCommittingPromptTransaction = nil
        afterCommittingPromptTransaction = nil
        beforeInstallingPromptBootstrap = nil
        rootDirectorySync = { fsync($0) }
    }

    deinit {
        if let ownership = deliveryOwnership {
            _ = flock(ownership.lockDescriptor, LOCK_UN)
            _ = close(ownership.lockDescriptor)
            _ = close(ownership.rootDescriptor)
        }
    }

    public var pendingCount: Int {
        get throws {
            try withLockedState(rootDescriptor: deliveryOwnership?.rootDescriptor) { stateDirectory, _ in
                try loadEnvelope(from: stateDirectory).queue.count
            }
        }
    }

    /// Observes the repository's validated current contents and commits the
    /// resulting cursor and prompt queue before releasing the repository lock.
    /// Callers cannot provide a stale snapshot or a destructive active-ID set.
    public func ingestCurrent(
        policy: NotificationPolicy,
        hour: Int
    ) throws {
        var invalidatesLocalDelivery = false
        var observationWasInstalled = false
        do {
            try repository.withValidatedLockedContents { current in
                try withLockedState { stateDirectory, rootDescriptor in
                    let validateReachability = {
                        try self.validateReachability(
                            stateDirectory: stateDirectory,
                            rootDescriptor: rootDescriptor
                        )
                    }
                    var envelope = try loadEnvelope(
                        from: stateDirectory,
                        validateReachability: validateReachability
                    )
                    let original = envelope
                    let matches = try envelope.observation.map {
                        try observation($0, matchesPrefixOf: current.events)
                    } ?? current.events.isEmpty

                    let previousEvents: [TripEvent]
                    if matches, let cursor = envelope.observation {
                        previousEvents = normalizedPrefix(
                            of: current.events,
                            count: cursor.observedEventCount,
                            pendingImageEventIDs: Set(cursor.pendingImageEventIDs)
                        )
                    } else {
                        envelope.queue = []
                        envelope.summary = nil
                        envelope.nextSequence = 0
                        envelope.observation = nil
                        previousEvents = []
                        invalidatesLocalDelivery = inFlight != nil
                    }

                    let prompts = PetTravelPromptDetector.detect(
                        previous: RepositoryContents(snapshot: current.snapshot, events: previousEvents),
                        current: current
                    )
                    var known = Set(envelope.queue.map { $0.prompt.identifier })
                    let kind: QueueKind = policy.isQuiet(hour: hour) ? .deferred : .ordinary
                    for prompt in prompts where known.insert(prompt.identifier).inserted {
                        guard envelope.nextSequence < UInt64.max else { throw corrupt() }
                        envelope.queue.append(
                            QueuedPrompt(sequence: envelope.nextSequence, kind: kind, prompt: prompt)
                        )
                        envelope.nextSequence += 1
                    }
                    envelope.observation = try makeObservation(for: current.events)

                    if !invalidatesLocalDelivery, let inFlight {
                        invalidatesLocalDelivery = !envelopeContains(inFlight, envelope: envelope)
                    }
                    if envelope != original {
                        try persist(
                            envelope,
                            to: stateDirectory,
                            didInstall: &observationWasInstalled,
                            validateReachability: validateReachability
                        )
                    }
                }
            }
        } catch {
            if invalidatesLocalDelivery, observationWasInstalled {
                clearLocalDeliveryOwnership()
            }
            if let repositoryError = error as? RepositoryError {
                throw Self.coordinatorError(for: repositoryError)
            }
            throw error
        }

        if invalidatesLocalDelivery {
            clearLocalDeliveryOwnership()
        }
    }

    private static func coordinatorError(
        for repositoryError: RepositoryError
    ) -> PetTravelPromptCoordinatorError {
        switch repositoryError {
        case .lockUnavailable, .lockFailure:
            .repositoryUnavailable(repositoryError.description)
        case .malformedJournal,
             .recoveryRequired,
             .eventInFuture,
             .versionConflict,
             .continuityConflict,
             .brokenJournalChain,
             .duplicateEventID,
             .eventConflict,
             .eventNotFound,
             .invalidImageTransition,
             .invalidImageResult,
             .malformedImageRetryState,
             .narrativeChanged,
             .unsafePostcardPath,
             .catIsAway,
             .clearHistoryResetFailed:
            .repositoryInvalid(repositoryError.description)
        }
    }

    /// Plans only from already-ingested durable state. It never advances or
    /// prunes repository authority, so permission, settings, and timer callbacks
    /// can safely call it without suppressing a later detector transition.
    public func nextDelivery(
        policy: NotificationPolicy,
        hour: Int
    ) throws -> [PetTravelPromptDelivery] {
        guard inFlight == nil else { return [] }
        guard let ownership = try acquireDeliveryOwnership() else { return [] }
        if let hook = afterAcquiringDeliveryOwnership {
            afterAcquiringDeliveryOwnership = nil
            hook()
        }

        do {
            let delivery = try withLockedState(
                rootDescriptor: ownership.rootDescriptor,
                allowDetachedRoot: true
            ) { stateDirectory, rootDescriptor -> PetTravelPromptDelivery? in
                let validateReachability = {
                    try self.validateReachability(
                        stateDirectory: stateDirectory,
                        rootDescriptor: rootDescriptor,
                        allowDetachedRoot: true
                    )
                }
                var envelope = try loadEnvelope(
                    from: stateDirectory,
                    validateReachability: validateReachability
                )
                guard !policy.isQuiet(hour: hour) else { return nil }

                let planned: PetTravelPromptDelivery?
                if let summary = envelope.summary {
                    planned = summary.delivery
                } else if let first = envelope.queue.first {
                    if first.kind == .ordinary {
                        planned = .prompt(first.prompt)
                    } else {
                        let prefix = envelope.queue.prefix { $0.kind == .deferred }
                        let summary = StoredSummary(
                            promptIDs: prefix.map { $0.prompt.identifier },
                            count: prefix.count,
                            throughSequence: prefix.last!.sequence
                        )
                        envelope.summary = summary
                        planned = summary.delivery
                    }
                } else {
                    planned = nil
                }

                if planned != nil {
                    // This fsynced atomic commit is deliberately made before
                    // every delivery, including an ordinary retry.
                    try persist(
                        envelope,
                        to: stateDirectory,
                        validateReachability: validateReachability
                    )
                }
                return planned
            }

            guard let delivery else {
                releaseOwnership(ownership)
                return []
            }
            deliveryOwnership = ownership
            inFlight = delivery
            return [delivery]
        } catch {
            releaseOwnership(ownership)
            throw error
        }
    }

    public func deliverySucceeded(_ delivery: PetTravelPromptDelivery) throws {
        guard inFlight == delivery, let ownership = deliveryOwnership else {
            throw PetTravelPromptCoordinatorError.invalidAcknowledgement
        }

        var acknowledgementWasInstalled = false
        do {
            try withLockedState(
                rootDescriptor: ownership.rootDescriptor,
                allowDetachedRoot: true
            ) { stateDirectory, rootDescriptor in
                let validateReachability = {
                    try self.validateReachability(
                        stateDirectory: stateDirectory,
                        rootDescriptor: rootDescriptor,
                        allowDetachedRoot: true
                    )
                }
                var envelope = try loadEnvelope(
                    from: stateDirectory,
                    validateReachability: validateReachability
                )
                switch delivery {
                case let .prompt(prompt):
                    guard envelope.summary == nil,
                          let first = envelope.queue.first,
                          first.kind == .ordinary,
                          first.prompt == prompt else {
                        throw PetTravelPromptCoordinatorError.invalidAcknowledgement
                    }
                    envelope.queue.removeFirst()

                case let .summary(promptIDs, count):
                    guard let summary = envelope.summary,
                          summary.delivery == delivery,
                          promptIDs.count == count,
                          envelope.queue.count >= count else {
                        throw PetTravelPromptCoordinatorError.invalidAcknowledgement
                    }
                    envelope.queue.removeFirst(count)
                    envelope.summary = nil
                }
                try persist(
                    envelope,
                    to: stateDirectory,
                    didInstall: &acknowledgementWasInstalled,
                    validateReachability: validateReachability
                )
            }
        } catch PetTravelPromptCoordinatorError.invalidAcknowledgement {
            // Another ingestion may have authoritatively pruned this exact
            // source event. The stale callback is rejected, but ownership must
            // not deadlock future deliveries.
            clearLocalDeliveryOwnership()
            throw PetTravelPromptCoordinatorError.invalidAcknowledgement
        } catch {
            if acknowledgementWasInstalled {
                clearLocalDeliveryOwnership()
            }
            throw error
        }

        clearLocalDeliveryOwnership()
    }

    public func deliveryFailed(_ delivery: PetTravelPromptDelivery) throws {
        guard inFlight == delivery, deliveryOwnership != nil else {
            throw PetTravelPromptCoordinatorError.invalidAcknowledgement
        }
        clearLocalDeliveryOwnership()
    }

    private func observation(
        _ cursor: ObservationCursor,
        matchesPrefixOf events: [TripEvent]
    ) throws -> Bool {
        guard cursor.observedEventCount <= events.count else { return false }
        let prefix = Array(events.prefix(cursor.observedEventCount))
        guard prefix.first?.id == cursor.firstObservedEventID,
              prefix.last?.id == cursor.lastObservedEventID else {
            return cursor.observedEventCount == 0
                && cursor.firstObservedEventID == nil
                && cursor.lastObservedEventID == nil
        }
        let prefixIDs = Set(prefix.map(\.id))
        guard Set(cursor.pendingImageEventIDs).isSubset(of: prefixIDs) else { return false }
        let normalized = normalizedPrefix(
            of: prefix,
            count: prefix.count,
            pendingImageEventIDs: Set(cursor.pendingImageEventIDs)
        )
        return try prefixDigest(normalized) == cursor.normalizedPrefixDigest
    }

    private func makeObservation(for events: [TripEvent]) throws -> ObservationCursor {
        let pending = events.compactMap {
            $0.postcardStatus == .pendingImage ? $0.id : nil
        }
        return ObservationCursor(
            observedEventCount: events.count,
            firstObservedEventID: events.first?.id,
            lastObservedEventID: events.last?.id,
            normalizedPrefixDigest: try prefixDigest(events),
            pendingImageEventIDs: pending
        )
    }

    private func normalizedPrefix(
        of events: [TripEvent],
        count: Int,
        pendingImageEventIDs: Set<UUID>
    ) -> [TripEvent] {
        events.prefix(count).map { event in
            guard pendingImageEventIDs.contains(event.id) else { return event }
            return TripEvent(
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
                consumedItemID: event.consumedItemID,
                postcardStatus: .pendingImage,
                postcardRelativePath: nil
            )
        }
    }

    private func prefixDigest(_ events: [TripEvent]) throws -> String {
        do {
            let encoder = JSONEncoder.travelCat
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(events)
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        } catch {
            throw PetTravelPromptCoordinatorError.encodingFailed(statePath)
        }
    }

    private func envelopeContains(
        _ delivery: PetTravelPromptDelivery,
        envelope: Envelope
    ) -> Bool {
        switch delivery {
        case let .prompt(prompt):
            return envelope.summary == nil
                && envelope.queue.first?.kind == .ordinary
                && envelope.queue.first?.prompt == prompt
        case .summary:
            return envelope.summary?.delivery == delivery
        }
    }

    private func validate(_ envelope: Envelope) throws {
        guard envelope.schemaVersion == 2 else { throw corrupt() }
        var prior: UInt64?
        var queueIDs = Set<String>()
        for entry in envelope.queue {
            guard entry.sequence < envelope.nextSequence,
                  prior.map({ entry.sequence > $0 }) ?? true,
                  queueIDs.insert(entry.prompt.identifier).inserted else {
                throw corrupt()
            }
            prior = entry.sequence
        }

        if let observation = envelope.observation {
            let anchorsAreValid = observation.observedEventCount == 0
                ? observation.firstObservedEventID == nil && observation.lastObservedEventID == nil
                : observation.firstObservedEventID != nil && observation.lastObservedEventID != nil
            guard observation.observedEventCount >= 0,
                  anchorsAreValid,
                  observation.normalizedPrefixDigest.count == 64,
                  observation.normalizedPrefixDigest.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
                  Set(observation.pendingImageEventIDs).count == observation.pendingImageEventIDs.count else {
                throw corrupt()
            }
        }

        if let summary = envelope.summary {
            let prefix = envelope.queue.prefix { $0.sequence <= summary.throughSequence }
            let expected = prefix.map { $0.prompt.identifier }
            guard !expected.isEmpty,
                  let last = prefix.last,
                  last.sequence == summary.throughSequence,
                  prefix.allSatisfy({ $0.kind == .deferred }),
                  summary.promptIDs == expected,
                  summary.count == expected.count else {
                throw corrupt()
            }
        }
    }

    private func withLockedState<T>(
        rootDescriptor suppliedRoot: Int32? = nil,
        allowDetachedRoot: Bool = false,
        _ body: (Int32, Int32) throws -> T
    ) throws -> T {
        let lockDirectory = try openLockDirectory()
        defer { _ = close(lockDirectory) }
        let lockDescriptor = try openValidatedLock(mutationLockName, directory: lockDirectory)
        defer { _ = close(lockDescriptor) }
        guard flock(lockDescriptor, LOCK_EX) == 0 else {
            throw PetTravelPromptCoordinatorError.persistenceFailed(statePath)
        }
        defer { _ = flock(lockDescriptor, LOCK_UN) }

        let rootDescriptor: Int32
        let ownsRootDescriptor: Bool
        if let suppliedRoot {
            try validatePinnedRootDescriptor(suppliedRoot)
            rootDescriptor = suppliedRoot
            ownsRootDescriptor = false
        } else {
            rootDescriptor = try openRootDirectory()
            ownsRootDescriptor = true
        }
        defer { if ownsRootDescriptor { _ = close(rootDescriptor) } }
        let stateDirectory = try openStateDirectory(rootDescriptor: rootDescriptor)
        defer { _ = close(stateDirectory) }
        if let hook = afterOpeningStateDirectory {
            afterOpeningStateDirectory = nil
            hook()
        }
        try validateReachability(
            stateDirectory: stateDirectory,
            rootDescriptor: rootDescriptor,
            allowDetachedRoot: allowDetachedRoot
        )
        return try body(stateDirectory, rootDescriptor)
    }

    private func validateReachability(
        stateDirectory: Int32,
        rootDescriptor: Int32,
        allowDetachedRoot: Bool = false
    ) throws {
        try validatePinnedRootDescriptor(rootDescriptor)
        if !allowDetachedRoot {
            let currentRoot = try openRootDirectory()
            _ = close(currentRoot)
        }
        try validateStateDirectory(
            stateDirectory,
            remainsAt: rootDescriptor
        )
    }

    private func validatePinnedRootDescriptor(_ descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(),
              info.st_mode & mode_t(0o022) == 0,
              rootIdentity.matches(info) else {
            throw corrupt(root.path)
        }
    }

    private func validateStateDirectory(
        _ stateDirectory: Int32,
        remainsAt rootDescriptor: Int32
    ) throws {
        var opened = stat()
        var reachable = stat()
        guard fstat(stateDirectory, &opened) == 0,
              fstatat(
                rootDescriptor,
                Self.stateDirectoryName,
                &reachable,
                AT_SYMLINK_NOFOLLOW
              ) == 0,
              (reachable.st_mode & S_IFMT) == S_IFDIR,
              opened.st_dev == reachable.st_dev,
              opened.st_ino == reachable.st_ino else {
            throw corrupt(stateDirectoryPath)
        }
    }

    private func openLockDirectory() throws -> Int32 {
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL
        let temporaryDescriptor = open(
            temporary.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard temporaryDescriptor >= 0 else { throw corrupt(temporary.path) }
        defer { _ = close(temporaryDescriptor) }
        var info = stat()
        guard fstat(temporaryDescriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(),
              info.st_mode & mode_t(0o022) == 0 else {
            throw corrupt(temporary.path)
        }

        if mkdirat(temporaryDescriptor, Self.lockDirectoryName, S_IRWXU) != 0,
           errno != EEXIST {
            throw PetTravelPromptCoordinatorError.persistenceFailed(statePath)
        }
        let descriptor = openat(
            temporaryDescriptor,
            Self.lockDirectoryName,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw corrupt(lockDirectoryPath) }
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(),
              info.st_mode & mode_t(0o777) == mode_t(0o700) else {
            _ = close(descriptor)
            throw corrupt(lockDirectoryPath)
        }
        return descriptor
    }

    private func openRootDirectory() throws -> Int32 {
        let descriptor = open(
            root.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw corrupt(root.path) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(),
              info.st_mode & mode_t(0o022) == 0,
              rootIdentity.matches(info) else {
            _ = close(descriptor)
            throw corrupt(root.path)
        }
        return descriptor
    }

    private func openStateDirectory(rootDescriptor: Int32) throws -> Int32 {
        var descriptor = openat(
            rootDescriptor,
            Self.stateDirectoryName,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        if descriptor < 0, errno == ENOENT {
            let mkdirResult = mkdirat(rootDescriptor, Self.stateDirectoryName, S_IRWXU)
            let createdStateDirectory = mkdirResult == 0
            guard createdStateDirectory || errno == EEXIST else {
                throw PetTravelPromptCoordinatorError.persistenceFailed(statePath)
            }
            guard rootDirectorySync(rootDescriptor) == 0 else {
                if createdStateDirectory {
                    _ = unlinkat(rootDescriptor, Self.stateDirectoryName, AT_REMOVEDIR)
                }
                throw PetTravelPromptCoordinatorError.persistenceFailed(statePath)
            }
            descriptor = openat(
                rootDescriptor,
                Self.stateDirectoryName,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else { throw corrupt(stateDirectoryPath) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(),
              info.st_mode & mode_t(0o022) == 0 else {
            _ = close(descriptor)
            throw corrupt(stateDirectoryPath)
        }
        return descriptor
    }

    private func openValidatedLock(_ name: String, directory: Int32) throws -> Int32 {
        let descriptor = openat(
            directory,
            name,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw PetTravelPromptCoordinatorError.persistenceFailed(statePath)
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1,
              info.st_uid == geteuid(),
              info.st_mode & mode_t(0o777) == mode_t(0o600) else {
            _ = close(descriptor)
            throw corrupt(lockDirectoryPath + "/" + name)
        }
        return descriptor
    }

    private func acquireDeliveryOwnership() throws -> DeliveryOwnership? {
        let lockDirectory = try openLockDirectory()
        defer { _ = close(lockDirectory) }
        let lockDescriptor = try openValidatedLock(deliveryLockName, directory: lockDirectory)
        guard flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            _ = close(lockDescriptor)
            if code == EWOULDBLOCK { return nil }
            throw PetTravelPromptCoordinatorError.persistenceFailed(statePath)
        }
        do {
            let rootDescriptor = try openRootDirectory()
            return DeliveryOwnership(
                lockDescriptor: lockDescriptor,
                rootDescriptor: rootDescriptor
            )
        } catch {
            _ = flock(lockDescriptor, LOCK_UN)
            _ = close(lockDescriptor)
            throw error
        }
    }

    private func loadEnvelope(
        from stateDirectory: Int32,
        validateReachability: (() throws -> Void)? = nil
    ) throws -> Envelope {
        try validateReachability?()
        guard let data = try store.load(
            from: stateDirectory,
            validateReachability: validateReachability
        ) else { return .empty }
        return try decodeEnvelope(data)
    }

    private func decodeEnvelope(_ data: Data) throws -> Envelope {
        do {
            try StrictJSONPreflight.validate(data)
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            try validate(envelope)
            let originalObject = try JSONSerialization.jsonObject(with: data)
            let decodedData = try encoded(envelope)
            let decodedObject = try JSONSerialization.jsonObject(with: decodedData)
            let originalCanonical = try JSONSerialization.data(withJSONObject: originalObject, options: [.sortedKeys])
            let decodedCanonical = try JSONSerialization.data(withJSONObject: decodedObject, options: [.sortedKeys])
            guard originalCanonical == decodedCanonical else { throw corrupt() }
            return envelope
        } catch let error as PetTravelPromptCoordinatorError {
            throw error
        } catch {
            throw corrupt()
        }
    }

    private func persist(
        _ envelope: Envelope,
        to stateDirectory: Int32,
        validateReachability: (() throws -> Void)? = nil
    ) throws {
        var ignored = false
        try persist(
            envelope,
            to: stateDirectory,
            didInstall: &ignored,
            validateReachability: validateReachability
        )
    }

    private func persist(
        _ envelope: Envelope,
        to stateDirectory: Int32,
        didInstall: inout Bool,
        validateReachability: (() throws -> Void)? = nil
    ) throws {
        try validate(envelope)
        let data = try encoded(envelope)
        guard data.count <= Self.maximumStateBytes else {
            throw PetTravelPromptCoordinatorError.encodingFailed(statePath)
        }
        store.afterBeginningTransaction = afterBeginningPromptTransaction.map { hook in
            { hook(self.stateDirectoryPath) }
        }
        store.beforeCommittingTransaction = beforeCommittingPromptTransaction.map { hook in
            { hook(self.stateDirectoryPath) }
        }
        store.afterCommittingTransaction = afterCommittingPromptTransaction.map { hook in
            { try hook(self.stateDirectoryPath) }
        }
        store.beforeInstallingBootstrap = beforeInstallingPromptBootstrap.map { hook in
            { hook(self.stateDirectoryPath + "/.pet-travel-prompts.sqlite3.bootstrap") }
        }
        afterBeginningPromptTransaction = nil
        beforeCommittingPromptTransaction = nil
        afterCommittingPromptTransaction = nil
        beforeInstallingPromptBootstrap = nil
        try store.commit(
            data,
            in: stateDirectory,
            didInstall: &didInstall,
            validateReachability: validateReachability
        )
    }

    private func encoded(_ envelope: Envelope) throws -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(envelope)
        } catch {
            throw PetTravelPromptCoordinatorError.encodingFailed(statePath)
        }
    }

    private var stateDirectoryPath: String {
        root.appendingPathComponent(Self.stateDirectoryName, isDirectory: true).path
    }

    private var lockDirectoryPath: String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(Self.lockDirectoryName, isDirectory: true)
            .path
    }

    private func corrupt(_ path: String? = nil) -> PetTravelPromptCoordinatorError {
        .corruptValue(path ?? statePath)
    }

    private func clearLocalDeliveryOwnership() {
        inFlight = nil
        if let ownership = deliveryOwnership {
            releaseOwnership(ownership)
            deliveryOwnership = nil
        }
    }

    private func releaseOwnership(_ ownership: DeliveryOwnership) {
        _ = flock(ownership.lockDescriptor, LOCK_UN)
        _ = close(ownership.lockDescriptor)
        _ = close(ownership.rootDescriptor)
    }

    private var lockNamespace: String {
        let digest = SHA256.hash(data: Data(root.path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return ".pet-travel-prompts-" + digest
    }

    private var mutationLockName: String { lockNamespace + ".mutation.lock" }
    private var deliveryLockName: String { lockNamespace + ".delivery.lock" }
}
