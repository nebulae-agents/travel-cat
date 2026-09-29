import CryptoKit
import Foundation
import Darwin
import TravelCore

public struct PostcardBacklogPlan: Codable, Equatable, Sendable {
    public struct Slot: Codable, Equatable, Sendable {
        public let id: UUID
        public var event: TripEvent?
        public var isSupplement: Bool
        public var eventID: UUID? { event?.id }
        public var imageReady: Bool { event?.postcardStatus == .ready }
    }
    public let tripID: UUID
    public var slots: [Slot]

    public static func target(for tripID: UUID) -> Int { 1 + Int(tripID.uuid.0 % 3) }
    public static func slotID(tripID: UUID, index: Int) -> UUID {
        var b = Array(SHA256.hash(data: Data("travel-cat/postcard/\(tripID.uuidString.lowercased())/\(index)".utf8)).prefix(16))
        b[6] = (b[6] & 0x0f) | 0x50
        b[8] = (b[8] & 0x3f) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}

/// Independent supplemental records: never append to or replay the trip state machine.
/// Uses the repository lock so clear/export and image commits share one transaction boundary.
public final class PostcardBacklogStore: @unchecked Sendable {
    private struct State: Codable {
        var schemaVersion = 1
        var plans: [PostcardBacklogPlan] = []
        var supplements: [TripEvent] = []
        var retries = ImageRetryStore()
        var retiredImagePaths: [String]?
    }
    private let repository: TravelRepository
    private let clock: any TravelClock
    private let url: URL
    private let writer = AtomicFileWriter()

    public init(root: URL, clock: any TravelClock = SystemClock()) throws {
        repository = try TravelRepository(root: root, clock: clock)
        self.clock = clock
        url = root.appendingPathComponent("state/postcard-backlog.json")
    }

    public func reconcile(events: [TripEvent]) throws -> [PostcardBacklogPlan] {
        try repository.withExclusiveLock {
            var state = try load()
            var trips: [UUID] = []
            for event in events where !trips.contains(event.tripID) { trips.append(event.tripID) }
            let previousPlans = state.plans
            state.plans = trips.map { trip in
                var remaining = events.filter { $0.tripID == trip && $0.phase == .postcardReady }
                let extras = state.supplements.filter { $0.tripID == trip }
                var slots = (0..<max(PostcardBacklogPlan.target(for: trip), remaining.count + extras.count)).map {
                    PostcardBacklogPlan.Slot(id: PostcardBacklogPlan.slotID(tripID: trip, index: $0), event: nil, isSupplement: false)
                }
                for index in slots.indices {
                    if let match = remaining.firstIndex(where: { $0.id == slots[index].id }) {
                        slots[index].event = remaining.remove(at: match)
                    } else if let supplement = extras.first(where: { $0.id == slots[index].id }) {
                        slots[index].event = supplement
                        slots[index].isSupplement = true
                    }
                }
                for index in slots.indices where slots[index].event == nil && !remaining.isEmpty {
                    slots[index].event = remaining.removeFirst()
                }
                return PostcardBacklogPlan(tripID: trip, slots: slots)
            }
            if state.plans != previousPlans { try save(state) }
            return state.plans
        }
    }

    public func characterProfile(for tripID: UUID) throws -> CharacterProfile {
        try repository.characterProfile(for: tripID)
    }

    public func supplementalEvents() throws -> [TripEvent] {
        try repository.withExclusiveLock { try load().supplements }
    }

    public func publishSupplement(_ event: TripEvent, slotID: UUID) throws {
        try repository.withExclusiveLock {
            var state = try load()
            if let existing = state.supplements.first(where: { $0.id == slotID }) {
                guard try NarrativeHasher.hash(existing) == NarrativeHasher.hash(event) else { throw RepositoryError.invalidImageResult }
                return
            }
            guard event.id == slotID, event.phase == .postcardReady,
                  event.postcardStatus == .pendingImage, event.postcardRelativePath == nil,
                  let plan = state.plans.first(where: { $0.tripID == event.tripID }),
                  plan.slots.contains(where: { $0.id == slotID && $0.eventID == nil }) else {
                throw RepositoryError.invalidImageTransition
            }
            let journal = try repository.readEventsUnlocked()
            guard journal.contains(where: { $0.tripID == event.tripID }) else { throw RepositoryError.invalidImageTransition }
            let profile = try repository.profileForTripUnlocked(event.tripID, events: journal)
            guard event.characterProfile == nil || event.characterProfile == profile else { throw RepositoryError.continuityConflict }
            let cards = journal.filter { $0.tripID == event.tripID && $0.phase == .postcardReady }
            let slotIDs = plan.slots.map(\.id)
            var occupied = Set(state.supplements.filter { $0.tripID == event.tripID }.map(\.id))
            occupied.formUnion(cards.filter { slotIDs.contains($0.id) }.map(\.id))
            for _ in cards.filter({ !slotIDs.contains($0.id) }) {
                if let free = slotIDs.first(where: { !occupied.contains($0) }) { occupied.insert(free) }
            }
            guard !occupied.contains(slotID) else { throw RepositoryError.invalidImageTransition }
            state.supplements.append(event)
            state.retries.entries[key(slotID)] = ImageRetry(attemptCount: 0, retryAt: nil, publishedNarrativeHash: try NarrativeHasher.hash(event))
            try save(state)
        }
    }

    public func imageRetry(for eventID: UUID) throws -> ImageRetry? {
        try repository.withExclusiveLock { try load().retries.entries[key(eventID)] }
    }

    @discardableResult
    public func requestManualImageRetry(eventID: UUID, mode: TravelMode) throws -> Bool {
        try repository.withExclusiveLock {
            var state = try load()
            guard let i = state.supplements.firstIndex(where: { $0.id == eventID }),
                  var retry = state.retries.entries[key(eventID)] else { throw RepositoryError.eventNotFound(eventID) }
            if state.supplements[i].postcardStatus == .pendingImage { return false }
            let event = state.supplements[i]
            let damagedReady = event.postcardStatus == .ready && !readyImageIsValid(event, retry: retry)
            guard event.postcardStatus == .imageUnavailable || damagedReady else { throw RepositoryError.invalidImageTransition }
            if damagedReady, let path = event.postcardRelativePath {
                let original = try JSONEncoder.travelCat.encode(state)
                let history = url.deletingLastPathComponent().appendingPathComponent("postcard-backlog.recovery-\(UUID().uuidString.lowercased()).ready.json")
                try writer.write(original, to: history)
                guard try Data(contentsOf: history) == original else { throw RepositoryError.malformedImageRetryState }
                state.retiredImagePaths = Array(Set((state.retiredImagePaths ?? []) + [path]))
            }
            retry.queueManual(now: clock.now)
            state.retries.entries[key(eventID)] = retry
            state.supplements[i].postcardStatus = .pendingImage
            state.supplements[i].postcardRelativePath = nil
            try save(state)
            return true
        }
    }

    public func pendingImages(mode: TravelMode, matchingCharacterProfile: CharacterProfile? = nil, matching: (TripEvent) -> Bool = { _ in true }) throws -> [PendingImageWork] {
        try pendingImages(mode: mode, manualEventID: nil, matchingCharacterProfile: matchingCharacterProfile, matching: matching)
    }

    public func pendingManualImage(eventID: UUID, mode: TravelMode, matchingCharacterProfile: CharacterProfile? = nil) throws -> PendingImageWork? {
        try pendingImages(mode: mode, manualEventID: eventID, matchingCharacterProfile: matchingCharacterProfile).first
    }

    private func pendingImages(mode: TravelMode, manualEventID: UUID?, matchingCharacterProfile: CharacterProfile? = nil, matching: (TripEvent) -> Bool = { _ in true }) throws -> [PendingImageWork] {
        try repository.withExclusiveLock {
            var state = try load()
            for i in state.supplements.indices where state.supplements[i].postcardStatus == .pendingImage {
                let event = state.supplements[i]
                let journal = try repository.readEventsUnlocked()
                guard journal.contains(where: { $0.tripID == event.tripID }) else { throw RepositoryError.invalidImageTransition }
                let profile = try repository.profileForTripUnlocked(event.tripID, events: journal)
                guard profile == .defaultBlackCat, matchingCharacterProfile == nil || profile == matchingCharacterProfile else { continue }
                guard matching(event) else { continue }
                guard var retry = state.retries.entries[key(event.id)] else { throw RepositoryError.malformedImageRetryState }
                if let manualEventID, event.id != manualEventID || retry.manualRequests.isEmpty { continue }
                guard retry.retryAt.map({ $0 <= clock.now }) ?? true,
                      retry.leaseExpiresAt.map({ $0 <= clock.now }) ?? true else { continue }
                if retry.activeAttemptToken != nil {
                    let status = retry.recordFailure(now: clock.now, mode: mode, resultHash: nil, reason: "Image generation lease expired")
                    state.supplements[i].postcardStatus = status
                    if status == .imageUnavailable { retry.terminalStatus = status }
                    state.retries.entries[key(event.id)] = retry
                    try save(state)
                    continue
                }
                retry.activeAttemptToken = UUID().uuidString.lowercased()
                retry.leaseExpiresAt = clock.now.addingTimeInterval(mode == .fast ? 1_800 : 3_600)
                state.retries.entries[key(event.id)] = retry
                try save(state)
                return [PendingImageWork(event: event, retry: retry, characterProfile: profile)]
            }
            return []
        }
    }

    @discardableResult
    public func markImage(_ result: ImageResultEnvelope, mode: TravelMode) throws -> MarkImageAcknowledgement {
        try repository.withExclusiveLock {
            try result.requireValidFields()
            // Supplemental cards currently use the source image directly; never accept an unvalidated presentation.
            guard result.presentation == nil else { throw RepositoryError.invalidImageResult }
            var state = try load()
            guard let i = state.supplements.firstIndex(where: { $0.id == result.eventId }),
                  var retry = state.retries.entries[key(result.eventId)] else { throw RepositoryError.eventNotFound(result.eventId) }
            let journal = try repository.readEventsUnlocked()
            guard journal.contains(where: { $0.tripID == state.supplements[i].tripID }),
                  try repository.profileForTripUnlocked(state.supplements[i].tripID, events: journal) == .defaultBlackCat else {
                throw RepositoryError.invalidImageResult
            }
            let hash = try NarrativeHasher.hash(result)
            guard !retry.manualPriorResultHashes.contains(hash) else { throw RepositoryError.invalidImageResult }
            guard result.publishedNarrativeHash == retry.publishedNarrativeHash else { throw RepositoryError.invalidImageResult }
            if retry.terminalResultHash == hash || retry.lastResultHash == hash {
                return MarkImageAcknowledgement(eventID: result.eventId, status: state.supplements[i].postcardStatus)
            }
            guard state.supplements[i].postcardStatus == .pendingImage,
                  retry.activeAttemptToken == result.attemptToken, retry.attemptCount == result.attemptCount,
                  retry.leaseExpiresAt.map({ $0 > clock.now }) == true else { throw RepositoryError.invalidImageResult }
            if result.status == .ready {
                guard !(state.retiredImagePaths ?? []).contains(result.relativePath ?? "") else { throw RepositoryError.invalidImageResult }
                let image = try repository.validateReadyImage(result.relativePath, tripID: state.supplements[i].tripID)
                defer { image.closeAll() }
                guard image.hasPostcardAspectRatio else { throw RepositoryError.invalidImageResult }
                try repository.requireUnchanged(image)
                try Task.checkCancellation()
                retry.terminalStatus = .ready
                retry.terminalResultHash = hash
                retry.imageContentHash = image.contentHash
                retry.terminalRelativePath = result.relativePath
                retry.retryAt = nil
                retry.activeAttemptToken = nil
                retry.leaseExpiresAt = nil
                state.supplements[i].postcardStatus = .ready
                state.supplements[i].postcardRelativePath = result.relativePath
            } else {
                let status = retry.recordFailure(now: clock.now, mode: mode, resultHash: hash, reason: result.reason)
                state.supplements[i].postcardStatus = status
                if status == .imageUnavailable { retry.terminalStatus = status; retry.terminalResultHash = hash }
            }
            state.retries.entries[key(result.eventId)] = retry
            try save(state)
            return MarkImageAcknowledgement(eventID: result.eventId, status: state.supplements[i].postcardStatus)
        }
    }

    private func key(_ id: UUID) -> String { id.uuidString.lowercased() }
    /// Asset damage is local to its card; it must not disable unrelated work.
    public func damagedReadyImageIDs() throws -> Set<UUID> {
        try repository.withExclusiveLock {
            let state = try load()
            return Set(state.supplements.filter { event in
                event.postcardStatus == .ready && !readyImageIsValid(event, retry: state.retries.entries[key(event.id)]!)
            }.map(\.id))
        }
    }

    private func readyImageIsValid(_ event: TripEvent, retry: ImageRetry) -> Bool {
        do {
            let image = try repository.validateReadyImage(event.postcardRelativePath, tripID: event.tripID)
            defer { image.closeAll() }
            guard image.hasPostcardAspectRatio, image.contentHash == retry.imageContentHash else { return false }
            try repository.requireUnchanged(image)
            return true
        } catch { return false }
    }

    /// Explicit local recovery only. Unknown records are never reconstructed as empty.
    /// All pending work is stopped because an external result may already exist.
    @discardableResult
    public func recoverFromBackup() throws -> URL {
        try repository.withExclusiveLock {
            if (try? load()) != nil { throw RepositoryError.invalidImageTransition }
            guard let backup = try readData(named: "postcard-backlog.backup.json") else {
                throw RepositoryError.malformedImageRetryState
            }
            let damaged = try readData(named: "postcard-backlog.json") ?? Data()
            var state = try decode(backup)
            let preserved = url.deletingLastPathComponent().appendingPathComponent("postcard-backlog.recovery-\(UUID().uuidString.lowercased()).json")
            let preservedBackup = preserved.deletingPathExtension().appendingPathExtension("source.json")
            try writer.write(backup, to: preservedBackup)
            guard try Data(contentsOf: preservedBackup) == backup else { throw RepositoryError.malformedImageRetryState }
            try writer.write(damaged, to: preserved)
            guard try Data(contentsOf: preserved) == damaged else { throw RepositoryError.malformedImageRetryState }
            for i in state.supplements.indices where state.supplements[i].postcardStatus == .pendingImage {
                let id = key(state.supplements[i].id)
                var retry = state.retries.entries[id]!
                retry.activeAttemptToken = nil
                retry.leaseExpiresAt = nil
                retry.retryAt = nil
                retry.terminalStatus = .imageUnavailable
                retry.lastFailureAt = clock.now
                retry.lastFailureReason = "恢复安全副本后暂停；上次生成结果未知，请手动重试一次。"
                state.retries.entries[id] = retry
                state.supplements[i].postcardStatus = .imageUnavailable
            }
            // Plans are projections. Refresh their event values without losing bindings.
            for p in state.plans.indices {
                for i in state.plans[p].slots.indices where state.plans[p].slots[i].isSupplement {
                    if let event = state.supplements.first(where: { $0.id == state.plans[p].slots[i].eventID }) {
                        state.plans[p].slots[i].event = event
                    }
                }
            }
            try save(state)
            return preserved
        }
    }

    private func load() throws -> State {
        guard let data = try readData(named: "postcard-backlog.json") else {
            // A missing main file with a recovery copy is not a new installation.
            guard try readData(named: "postcard-backlog.backup.json") == nil else { throw RepositoryError.malformedImageRetryState }
            return State()
        }
        return try decode(data)
    }

    private func readData(named filename: String) throws -> Data? {
        let rootFD = open(repository.root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard rootFD >= 0 else { throw RepositoryError.malformedImageRetryState }
        defer { _ = close(rootFD) }
        let stateFD = openat(rootFD, "state", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard stateFD >= 0 else { throw RepositoryError.malformedImageRetryState }
        defer { _ = close(stateFD) }
        let descriptor = openat(stateFD, filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw RepositoryError.malformedImageRetryState
        }
        defer { _ = close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1, info.st_size >= 0, info.st_size <= 64 * 1_024 * 1_024 else {
            throw RepositoryError.malformedImageRetryState
        }
        let data = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).readToEnd() ?? Data()
        return data
    }

    private func decode(_ data: Data) throws -> State {
        let state = try JSONDecoder.travelCat.decode(State.self, from: data)
        guard state.schemaVersion == 1, Set(state.supplements.map(\.id)).count == state.supplements.count else { throw RepositoryError.malformedImageRetryState }
        _ = try state.retries.validated()
        guard Set(state.retries.entries.keys) == Set(state.supplements.map { key($0.id) }) else { throw RepositoryError.malformedImageRetryState }
        for event in state.supplements {
            guard let retry = state.retries.entries[key(event.id)],
                  try NarrativeHasher.hash(event) == retry.publishedNarrativeHash else { throw RepositoryError.malformedImageRetryState }
            switch event.postcardStatus {
            case .ready:
                guard retry.terminalStatus == .ready, retry.terminalRelativePath == event.postcardRelativePath else { throw RepositoryError.malformedImageRetryState }
                try TravelRepository.validateReadyImagePath(event.postcardRelativePath, tripID: event.tripID)
            case .pendingImage:
                guard retry.terminalStatus == nil, retry.attemptCount < 3, event.postcardRelativePath == nil else { throw RepositoryError.malformedImageRetryState }
            case .imageUnavailable:
                guard retry.terminalStatus == .imageUnavailable, event.postcardRelativePath == nil else { throw RepositoryError.malformedImageRetryState }
            default: throw RepositoryError.malformedImageRetryState
            }

        }
        return state
    }
    private func save(_ state: State) throws {
        _ = try state.retries.validated()
        let data = try JSONEncoder.travelCat.encode(state)
        _ = try decode(data)
        let backupURL = url.deletingLastPathComponent().appendingPathComponent("postcard-backlog.backup.json")
        // Write-ahead mirror: it can be ahead of the main file after a crash, never
        // behind a successfully committed mutation. Recovery fences all leases.
        try writer.write(data, to: backupURL)
        guard try readData(named: "postcard-backlog.backup.json") == data else { throw RepositoryError.malformedImageRetryState }
        try writer.write(data, to: url)
    }
}
