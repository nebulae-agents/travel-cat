import Darwin
import Foundation
import ImageIO
import TravelCore
import TravelStorage
import TravelUI

struct TravelNarrative: Codable, Sendable {
    let summary: String
    let mood: Mood
    let location: Location?
    let transport: String?
    let continuityReferences: [String]
    let openHook: String?
    let consumedItemID: String?
    let scenePrompt: String?
}

struct TravelEventRequest: Codable, Sendable {
    let claim: DueClaim
    let recentEvents: [TripEvent]
    let phase: TravelPhase
    let carriedSupply: Supply?

    init(claim: DueClaim, recentEvents: [TripEvent], phase: TravelPhase) {
        self.claim = claim
        self.recentEvents = recentEvents
        self.phase = phase
        let startsNewTrip = phase == .preparing && claim.snapshot.phase == .resting
        carriedSupply = SupplyCatalog.loadOrEmpty().first {
            $0.id == claim.snapshot.carriedItemID && (startsNewTrip || !claim.snapshot.usedItemIDs.contains($0.id))
        }
    }
}

@MainActor
protocol TravelContentGenerating {
    func narrative(for request: TravelEventRequest) async throws -> TravelNarrative
    func image(for work: PendingImageWork, in workspace: URL) async throws -> URL
}

struct AutomaticTravelOutcome: Equatable {
    let nextCheckAt: Date
    let message: String
}

private struct AutomaticTravelState: Codable {
    var schemaVersion = 1
    var initialSnapshotDate: Date?
    var initialMode: TravelMode?
    var departureAt: Date?
    var nextAttemptAt: Date?
    var failures = 0
    var lastFailureMessage: String?
    var lastActionWasImage = false
    var observedMode: TravelMode?
    var modeActionAt: Date?
    var modeSnapshotVersion: Int?
    var modeSnapshotDate: Date?
}

@MainActor
final class AutomaticTravelWorker {
    private let repository: TravelRepository
    private let generator: any TravelContentGenerating
    private let clock: () -> Date
    private let calendar: () -> Calendar
    private var stateURL: URL { repository.root.appendingPathComponent("state/automatic-travel.json") }

    init(repository: TravelRepository, generator: any TravelContentGenerating,
         clock: @escaping () -> Date = Date.init, calendar: @escaping () -> Calendar = { .current }) {
        self.repository = repository
        self.generator = generator
        self.clock = clock
        self.calendar = calendar
    }

    func step(settings: TravelSettings) async throws -> AutomaticTravelOutcome {
        let now = clock()
        guard settings.automaticTravelEnabled else {
            return .init(nextCheckAt: now.addingTimeInterval(60), message: "自动旅行已暂停")
        }
        guard let ownership = SingleInstanceLock.acquire(at: repository.root.appendingPathComponent(".automatic-travel.lock")) else {
            return .init(nextCheckAt: now.addingTimeInterval(60), message: "正在处理上一封旅途来信")
        }
        defer { withExtendedLifetime(ownership) {} }
        var state = try loadState()
        do {
            let contents = try repository.loadContents()
            guard contents.characterProfile == .defaultBlackCat,
                  contents.selectedCharacterProfile == .defaultBlackCat else {
                return .init(nextCheckAt: now.addingTimeInterval(60), message: "自定义角色的自动旅行暂未启用")
            }
            var dueAt = contents.snapshot.nextActionAt
            if let previousMode = state.observedMode, previousMode != settings.mode {
                state.modeActionAt = TripScheduler(mode: settings.mode).nextAction(
                    after: now, phase: contents.snapshot.phase, seed: UInt64.random(in: 1...UInt64.max), calendar: calendar())
                state.modeSnapshotVersion = contents.snapshot.stateVersion
                state.modeSnapshotDate = contents.snapshot.lastUpdatedAt
                state.nextAttemptAt = nil
                state.failures = 0
            }
            state.observedMode = settings.mode
            if state.modeSnapshotVersion == contents.snapshot.stateVersion,
               state.modeSnapshotDate == contents.snapshot.lastUpdatedAt, let adjusted = state.modeActionAt {
                dueAt = adjusted
            }
            try save(state)
            if contents.snapshot.stateVersion == 0 {
                if state.initialSnapshotDate != contents.snapshot.lastUpdatedAt || state.initialMode != settings.mode || state.departureAt == nil {
                    state.initialSnapshotDate = contents.snapshot.lastUpdatedAt
                    state.initialMode = settings.mode
                    state.departureAt = TripScheduler(mode: settings.mode).nextDeparture(
                        after: now, seed: UInt64.random(in: 1...UInt64.max), calendar: calendar())
                    try save(state)
                }
                dueAt = state.departureAt!
            }
            // A missed departure is rescheduled into a local daytime window. In-flight travel
            // continues from its last confirmed event even when the app was closed for days.
            if contents.snapshot.phase == .resting, settings.mode == .daily, dueAt <= now {
                let hour = calendar().component(.hour, from: now)
                if hour < 8 || hour >= 20 {
                    if state.departureAt.map({ $0 > now }) != true {
                        state.departureAt = TripScheduler(mode: .daily).nextDeparture(
                            after: now, seed: UInt64.random(in: 1...UInt64.max), calendar: calendar())
                        try save(state)
                    }
                    dueAt = state.departureAt!
                } else if let planned = state.departureAt, planned > now {
                    dueAt = planned
                }
            }
            let waitingForRetry = state.nextAttemptAt.map { $0 > now } ?? false
            let eventDue = dueAt <= now && !waitingForRetry
            if !eventDue || !state.lastActionWasImage {
                if let work = try repository.pendingImages(mode: settings.mode, matchingCharacterProfile: .defaultBlackCat).first {
                    state.lastActionWasImage = true
                    try save(state)
                    let imageOutcome = try await completeImage(work, mode: settings.mode)
                    return .init(nextCheckAt: clock().addingTimeInterval(15), message: imageOutcome.message)
                }
            }
            guard eventDue else {
                if waitingForRetry, let retry = state.nextAttemptAt {
                    return .init(nextCheckAt: min(retry, now.addingTimeInterval(60)), message: state.lastFailureMessage ?? "暂时无法续写旅程，稍后自动重试")
                }
                let hasPending = contents.events.contains { $0.postcardStatus == .pendingImage }
                return .init(nextCheckAt: hasPending ? min(dueAt, now.addingTimeInterval(60)) : dueAt,
                             message: contents.snapshot.phase == .resting ? "等待下一次随机出发" : "正在旅行，等待下一封来信")
            }
            let request = TravelEventRequest(
                claim: DueClaim(due: true, snapshot: contents.snapshot, previousEvent: contents.events.last, characterProfile: contents.characterProfile),
                recentEvents: Array(contents.events.suffix(12)),
                phase: Self.nextPhase(contents: contents, now: now))
            state.lastActionWasImage = false
            try save(state)
            let narrative = try await generator.narrative(for: request)
            try Task.checkCancellation()
            let occurredAt = clock()
            if request.phase == .preparing, settings.mode == .daily {
                let hour = calendar().component(.hour, from: occurredAt)
                if hour < 8 || hour >= 20 {
                    state.departureAt = TripScheduler(mode: .daily).nextDeparture(
                        after: occurredAt, seed: UInt64.random(in: 1...UInt64.max), calendar: calendar())
                    try save(state)
                    return .init(nextCheckAt: state.departureAt!, message: "今晚先休息，明天再出发")
                }
            }
            let candidate = AgentEventEnvelope(
                eventId: UUID(),
                tripId: request.phase == .preparing ? UUID() : (contents.snapshot.tripID ?? UUID()),
                previousEventId: contents.snapshot.lastEventID,
                occurredAt: occurredAt,
                phase: request.phase,
                location: narrative.location,
                transport: narrative.transport,
                summary: narrative.summary,
                mood: narrative.mood,
                continuityReferences: narrative.continuityReferences,
                openHook: narrative.openHook,
                consumedItemId: narrative.consumedItemID,
                postcard: PostcardRequest(required: request.phase == .postcardReady, scenePrompt: narrative.scenePrompt))
            // Reuse the exact structural and continuity boundary used by the CLI. The model
            // cannot choose event identity, timestamps, state versions, or storage paths.
            let checked = try AgentEventEnvelope.decode(JSONEncoder.travelCat.encode(candidate))
            let envelope = try checked.validatedProjection(previous: contents.snapshot,
                existingEventIDs: Set(contents.events.map(\.id)), mode: settings.mode, calendar: calendar(), now: occurredAt)
            try Task.checkCancellation()
            _ = try repository.publish(event: envelope.event, next: envelope.next, expectedSnapshot: contents.snapshot, expectedCharacterProfile: .defaultBlackCat)
            state.departureAt = nil
            state.modeActionAt = nil
            state.lastActionWasImage = false
            state.failures = 0
            state.lastFailureMessage = nil
            state.nextAttemptAt = nil
            try save(state)
            return .init(nextCheckAt: request.phase == .postcardReady ? occurredAt.addingTimeInterval(15) : envelope.next.nextActionAt,
                         message: "旅程已更新")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            state.failures = min(8, state.failures + 1)
            let delay = min(3_600.0, (settings.mode == .fast ? 15.0 : 60.0) * pow(2, Double(state.failures - 1)))
            state.nextAttemptAt = clock().addingTimeInterval(delay)
            state.lastFailureMessage = (error as? CodexTravelExecutor.Failure)?.errorDescription
                ?? "暂时无法续写旅程，稍后自动重试"
            try save(state)
            return .init(nextCheckAt: state.nextAttemptAt!, message: state.lastFailureMessage!)
        }
    }

    static func nextPhase(contents: RepositoryContents, now: Date) -> TravelPhase {
        switch contents.snapshot.phase {
        case .resting: return .preparing
        case .preparing: return .transit
        case .transit: return .exploring
        case .exploring: return .postcardReady
        case .returning: return .resting
        case .postcardReady:
            let trip = contents.events.filter { $0.tripID == contents.snapshot.tripID }
            let count = trip.filter { $0.phase == .postcardReady }.count
            let target = 1 + Int((contents.snapshot.tripID?.uuid.0 ?? 0) % 3)
            let elapsed = now.timeIntervalSince(trip.first?.occurredAt ?? now)
            return count >= target || elapsed >= 20 * 3_600 ? .returning : .exploring
        }
    }

    private func completeImage(_ work: PendingImageWork, mode: TravelMode) async throws -> (ready: Bool, message: String) {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("travelcat-image-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: workspace) }
        let path = "postcards/\(work.event.tripID.uuidString.lowercased())/\(work.event.id.uuidString.lowercased())-\(work.attemptToken).png"
        do {
            let source = try await generator.image(for: work, in: workspace)
            try Task.checkCancellation()
            guard source.standardizedFileURL == workspace.appendingPathComponent("postcard.png").standardizedFileURL else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            var info = stat()
            guard lstat(source.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_nlink == 1, info.st_size > 0, info.st_size <= 15 * 1_024 * 1_024 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            guard let image = CGImageSourceCreateWithURL(source as CFURL, nil),
                  CGImageSourceGetType(image) as String? == "public.png",
                  let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  height >= 768, width <= 8_192, height <= 8_192,
                  Int64(width) * Int64(height) <= 16_000_000,
                  abs(Double(width) - Double(height) * 1.5) <= 1,
                  CGImageSourceCreateImageAtIndex(image, 0, nil) != nil else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let target = repository.root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: target)
        } catch {
            try Task.checkCancellation()
            let reason = (error as? CodexTravelExecutor.Failure)?.errorDescription
                ?? (error as? TravelImageGenerationFailure)?.errorDescription ?? "照片尚未完成，已安排重试"
            _ = try repository.markImage(ImageResultEnvelope(eventId: work.event.id, status: .failed,
                attemptedAt: clock(), relativePath: nil, reason: reason, attemptToken: work.attemptToken,
                attemptCount: work.imageAttemptCount, publishedNarrativeHash: work.publishedNarrativeHash), mode: mode)
            return (false, reason)
        }
        // Once handed to markImage, a failed write can already have committed the ready intent.
        // Keep the generated file for repository recovery; never overwrite that intent with failed.
        _ = try repository.markImage(ImageResultEnvelope(eventId: work.event.id, status: .ready,
            attemptedAt: clock(), relativePath: path, reason: nil, attemptToken: work.attemptToken,
            attemptCount: work.imageAttemptCount, publishedNarrativeHash: work.publishedNarrativeHash), mode: mode)
        return (true, "收到一张新照片")
    }

    private func loadState() throws -> AutomaticTravelState {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return AutomaticTravelState() }
        let state = try JSONDecoder.travelCat.decode(AutomaticTravelState.self, from: Data(contentsOf: stateURL))
        guard state.schemaVersion == 1 else { throw CocoaError(.fileReadCorruptFile) }
        return state
    }

    private func save(_ state: AutomaticTravelState) throws {
        try AtomicFileWriter().write(JSONEncoder.travelCat.encode(state), to: stateURL)
    }
}
