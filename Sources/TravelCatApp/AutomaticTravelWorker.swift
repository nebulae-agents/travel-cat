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
    let isSupplemental: Bool
    let homeLocation: HomeLocation?

    init(claim: DueClaim, recentEvents: [TripEvent], phase: TravelPhase, isSupplemental: Bool = false, homeLocation: HomeLocation? = nil) {
        self.claim = claim
        self.recentEvents = recentEvents
        self.phase = phase
        self.isSupplemental = isSupplemental
        self.homeLocation = homeLocation
        let startsNewTrip = phase == .preparing && claim.snapshot.phase == .resting
        carriedSupply = SupplyCatalog.loadOrEmpty().first {
            $0.id == claim.snapshot.carriedItemID && (startsNewTrip || !claim.snapshot.usedItemIDs.contains($0.id))
        }
    }

    private enum CodingKeys: String, CodingKey {
        case claim, recentEvents, phase, carriedSupply, isSupplemental, homeLocation
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        claim = try values.decode(DueClaim.self, forKey: .claim)
        recentEvents = try values.decode([TripEvent].self, forKey: .recentEvents)
        phase = try values.decode(TravelPhase.self, forKey: .phase)
        carriedSupply = try values.decodeIfPresent(Supply.self, forKey: .carriedSupply)
        isSupplemental = try values.decodeIfPresent(Bool.self, forKey: .isSupplemental) ?? false
        homeLocation = try values.decodeIfPresent(HomeLocation.self, forKey: .homeLocation)
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
    var postcardPlan: TripPostcardPlan?
    var nextModelActionAt: Date?
}

@MainActor
final class AutomaticTravelWorker {
    private let repository: TravelRepository
    private let generator: any TravelContentGenerating
    private let clock: () -> Date
    private let calendar: () -> Calendar
    private let didChange: () -> Void
    private var stateURL: URL { repository.root.appendingPathComponent("state/automatic-travel.json") }

    init(repository: TravelRepository, generator: any TravelContentGenerating,
         clock: @escaping () -> Date = Date.init, calendar: @escaping () -> Calendar = { .current },
         didChange: @escaping () -> Void = {}) {
        self.repository = repository
        self.generator = generator
        self.clock = clock
        self.calendar = calendar
        self.didChange = didChange
    }

    func step(settings: TravelSettings, manualEventID: UUID? = nil) async throws -> AutomaticTravelOutcome {
        let now = clock()
        guard settings.automaticTravelEnabled || manualEventID != nil else {
            return .init(nextCheckAt: now.addingTimeInterval(60), message: "自动旅行已暂停")
        }
        guard let ownership = SingleInstanceLock.acquire(at: repository.root.appendingPathComponent(".automatic-travel.lock")) else {
            return .init(nextCheckAt: now.addingTimeInterval(60), message: "正在处理上一封旅途来信")
        }
        defer { withExtendedLifetime(ownership) {} }
        let catchUpGap: TimeInterval = settings.mode == .fast ? 15 : 60
        var state = try loadState(recoveryGap: catchUpGap)
        var startedModelAction = false
        var progressPlans: [PostcardBacklogPlan] = []
        do {
            let contents = try repository.loadContents()
            // Home lookup belongs to application/settings lifecycle. Story work only
            // reads the cache and never guesses a home from historical destinations.
            let homeLocation = try? HomeLocationStore(root: repository.root).load().location
            let backlog = try PostcardBacklogStore(root: repository.root, clock: WorkerClock(read: clock))
            let plans = try backlog.reconcile(events: contents.events)
            progressPlans = plans
            let supportedPlans = try plans.filter { try backlog.characterProfile(for: $0.tripID) == .defaultBlackCat }
            let historical = supportedPlans.flatMap { plan in
                plan.slots.filter { slot in
                    slot.eventID == nil && (plan.tripID != contents.snapshot.tripID
                        || contents.snapshot.phase == .resting || contents.snapshot.phase == .returning)
                }.map { (tripID: plan.tripID, slotID: $0.id) }
            }.first
            let supplemental = try backlog.supplementalEvents()
            if let manualEventID {
                if let cooldown = state.nextModelActionAt, cooldown > now {
                    return .init(nextCheckAt: cooldown, message: "手动重试已排队，等待生成间隔")
                }
                let isSupplement = supplemental.contains { $0.id == manualEventID }
                let work = try isSupplement ? backlog.pendingManualImage(eventID: manualEventID, mode: settings.mode, matchingCharacterProfile: .defaultBlackCat)
                    : repository.pendingManualImage(eventID: manualEventID, mode: settings.mode, matchingCharacterProfile: .defaultBlackCat)
                guard let work else {
                    return .init(nextCheckAt: now.addingTimeInterval(catchUpGap), message: "这次手动重试已完成或正在处理中")
                }
                state.nextModelActionAt = now.addingTimeInterval(catchUpGap)
                startedModelAction = true
                try save(state)
                let outcome = try await completeImage(work, mode: settings.mode, backlog: isSupplement ? backlog : nil)
                state.nextModelActionAt = clock().addingTimeInterval(catchUpGap)
                try save(state)
                return .init(nextCheckAt: state.nextModelActionAt!, message: outcome.message)
            }
            guard contents.characterProfile == .defaultBlackCat,
                  contents.selectedCharacterProfile == .defaultBlackCat else {
                return .init(nextCheckAt: now.addingTimeInterval(60), message: "自定义角色的自动旅行暂未启用")
            }
            var dueAt = contents.snapshot.nextActionAt
            if contents.snapshot.phase != .resting, let tripID = contents.snapshot.tripID {
                if state.postcardPlan?.tripID != tripID {
                    state.postcardPlan = TripPostcardPlan(tripID: tripID)
                }
                state.postcardPlan?.reconcile(events: contents.events)
                // A substantially missed in-flight action starts bounded catch-up. Keep
                // this intent across wakes; newly projected dates must not erase the debt.
                if dueAt.addingTimeInterval(settings.mode == .fast ? 60 : 3_600) < now {
                    state.postcardPlan?.catchingUp = true
                }
                if state.postcardPlan?.catchingUp == true {
                    dueAt = state.postcardPlan?.nextCatchUpAt ?? dueAt
                }
            }
            if let previousMode = state.observedMode, previousMode != settings.mode {
                let owesCurrentAction = contents.snapshot.phase != .resting && (dueAt <= now || state.postcardPlan?.catchingUp == true)
                state.modeActionAt = owesCurrentAction ? dueAt : TripScheduler(mode: settings.mode).nextAction(
                    after: now, phase: contents.snapshot.phase, seed: UInt64.random(in: 1...UInt64.max), calendar: calendar())
                state.modeSnapshotVersion = contents.snapshot.stateVersion
                state.modeSnapshotDate = contents.snapshot.lastUpdatedAt
                state.nextAttemptAt = nil
                state.failures = 0
                if state.postcardPlan?.catchingUp == true {
                    state.postcardPlan?.nextCatchUpAt = state.modeActionAt
                }
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
            if let cooldown = state.nextModelActionAt, cooldown > now,
               eventDue || historical != nil || (contents.events + supplemental).contains(where: { $0.postcardStatus == .pendingImage }) {
                return .init(nextCheckAt: cooldown, message: progressMessage("正在依次处理明信片", plans: progressPlans))
            }
            if (!eventDue && historical == nil) || !state.lastActionWasImage {
                let journalWork = try repository.pendingImages(mode: settings.mode, matchingCharacterProfile: .defaultBlackCat).first
                let supplementWork = try journalWork == nil ? backlog.pendingImages(mode: settings.mode, matchingCharacterProfile: .defaultBlackCat).first : nil
                if let work = journalWork ?? supplementWork {
                    state.lastActionWasImage = true
                    state.nextModelActionAt = now.addingTimeInterval(catchUpGap)
                    startedModelAction = true
                    try save(state)
                    let imageOutcome = try await completeImage(work, mode: settings.mode, backlog: supplementWork == nil ? nil : backlog)
                    state.postcardPlan?.reconcile(events: try repository.events())
                    progressPlans = try backlog.reconcile(events: try repository.events())
                    state.nextModelActionAt = clock().addingTimeInterval(catchUpGap)
                    try save(state)
                    return .init(nextCheckAt: clock().addingTimeInterval(catchUpGap),
                                 message: progressMessage(imageOutcome.message, plans: progressPlans))
                }
            }
            if let historical, !waitingForRetry {
                let tripEvents = contents.events.filter { $0.tripID == historical.tripID }
                guard let previous = tripEvents.last else { throw CocoaError(.fileReadCorruptFile) }
                // This temporary projection validates a retrospective postcard only. It
                // is never published to the journey state machine or the old journal.
                let context = TripSnapshot(stateVersion: tripEvents.count, tripID: historical.tripID,
                    lastEventID: previous.id, phase: .exploring, nextActionAt: now,
                    lastUpdatedAt: previous.occurredAt, usedItemIDs: Set(tripEvents.compactMap(\.consumedItemID)),
                    visitedPlaces: [], mood: previous.mood, openHook: previous.openHook)
                let request = TravelEventRequest(claim: DueClaim(due: true, snapshot: context, previousEvent: previous),
                    recentEvents: Array(tripEvents.suffix(12)), phase: .postcardReady, isSupplemental: true, homeLocation: homeLocation)
                state.lastActionWasImage = false
                state.nextModelActionAt = now.addingTimeInterval(catchUpGap)
                startedModelAction = true
                try save(state)
                let narrative = try await generator.narrative(for: request)
                try Task.checkCancellation()
                let generatedAt = clock()
                state.nextModelActionAt = generatedAt.addingTimeInterval(catchUpGap)
                let candidate = AgentEventEnvelope(eventId: historical.slotID, tripId: historical.tripID,
                    previousEventId: previous.id, occurredAt: generatedAt, phase: .postcardReady,
                    location: narrative.location, transport: narrative.transport, summary: narrative.summary,
                    mood: narrative.mood, continuityReferences: narrative.continuityReferences,
                    openHook: narrative.openHook, consumedItemId: nil,
                    postcard: PostcardRequest(required: true, scenePrompt: narrative.scenePrompt))
                let checked = try AgentEventEnvelope.decode(JSONEncoder.travelCat.encode(candidate))
                let projected = try checked.validatedProjection(previous: context,
                    existingEventIDs: Set((contents.events + supplemental).map(\.id)),
                    mode: settings.mode, calendar: calendar(), now: generatedAt)
                // A concurrent explicit history reset invalidates the source trip.
                guard try repository.events().filter({ $0.tripID == historical.tripID }) == tripEvents else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                try backlog.publishSupplement(projected.event, slotID: historical.slotID)
                state.failures = 0
                state.nextAttemptAt = nil
                state.lastFailureMessage = nil
                try save(state)
                return .init(nextCheckAt: state.nextModelActionAt!, message: "已补发一封旧旅程来信，等待生成照片")
            }
            guard eventDue else {
                if waitingForRetry, let retry = state.nextAttemptAt {
                    return .init(nextCheckAt: min(retry, now.addingTimeInterval(60)), message: progressMessage(state.lastFailureMessage ?? "暂时无法续写旅程，稍后自动重试", plans: progressPlans))
                }
                let hasPending = contents.events.contains { $0.postcardStatus == .pendingImage }
                return .init(nextCheckAt: hasPending ? min(dueAt, now.addingTimeInterval(60)) : dueAt,
                             message: progressMessage(contents.snapshot.phase == .resting ? "等待下一次随机出发" : "正在旅行，等待下一封来信", plans: progressPlans))
            }
            let request = TravelEventRequest(
                claim: DueClaim(due: true, snapshot: contents.snapshot, previousEvent: contents.events.last, characterProfile: contents.characterProfile),
                recentEvents: Array(contents.events.suffix(12)),
                phase: Self.nextPhase(contents: contents, now: now), homeLocation: homeLocation)
            // Allocate the new itinerary before model work; failure and restart retain
            // its trip/slot identities. Existing trips have already reconciled above.
            if request.phase == .preparing {
                if state.postcardPlan == nil || state.postcardPlan?.tripID == contents.snapshot.tripID {
                    state.postcardPlan = TripPostcardPlan(tripID: UUID())
                }
            }
            state.lastActionWasImage = false
            state.nextModelActionAt = now.addingTimeInterval(catchUpGap)
            startedModelAction = true
            try save(state)
            let narrative = try await generator.narrative(for: request)
            try Task.checkCancellation()
            let occurredAt = clock()
            state.nextModelActionAt = occurredAt.addingTimeInterval(catchUpGap)
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
                eventId: request.phase == .postcardReady ? (state.postcardPlan?.nextEventID ?? UUID()) : UUID(),
                tripId: request.phase == .preparing ? state.postcardPlan!.tripID : (contents.snapshot.tripID ?? UUID()),
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
            state.postcardPlan?.reconcile(events: try repository.events())
            progressPlans = try backlog.reconcile(events: try repository.events())
            if state.postcardPlan?.catchingUp == true {
                state.postcardPlan?.nextCatchUpAt = occurredAt.addingTimeInterval(catchUpGap)
            }
            if request.phase == .resting {
                state.postcardPlan?.catchingUp = false
                state.postcardPlan?.nextCatchUpAt = nil
            }
            try save(state)
            let nextCheck = state.postcardPlan?.catchingUp == true
                ? occurredAt.addingTimeInterval(catchUpGap) : envelope.next.nextActionAt
            return .init(nextCheckAt: request.phase == .postcardReady ? occurredAt.addingTimeInterval(catchUpGap) : nextCheck,
                         message: progressMessage("旅程已更新", plans: progressPlans))
        } catch is CancellationError {
            if startedModelAction {
                state.nextModelActionAt = clock().addingTimeInterval(catchUpGap)
                try save(state)
            }
            throw CancellationError()
        } catch {
            if startedModelAction { state.nextModelActionAt = clock().addingTimeInterval(catchUpGap) }
            state.failures = min(8, state.failures + 1)
            let delay = min(3_600.0, (settings.mode == .fast ? 15.0 : 60.0) * pow(2, Double(state.failures - 1)))
            state.nextAttemptAt = clock().addingTimeInterval(delay)
            state.lastFailureMessage = (error as? CodexTravelExecutor.Failure)?.errorDescription
                ?? "暂时无法续写旅程，稍后自动重试"
            try save(state)
            return .init(nextCheckAt: state.nextAttemptAt!, message: progressMessage(state.lastFailureMessage!, plans: progressPlans))
        }
    }

    static func nextPhase(contents: RepositoryContents, now: Date) -> TravelPhase {
        let postcards = contents.events.filter { $0.tripID == contents.snapshot.tripID && $0.phase == .postcardReady }
        let target = contents.snapshot.tripID.map(TripPostcardPlan.target(for:)) ?? 1
        switch contents.snapshot.phase {
        case .resting: return .preparing
        case .preparing: return .transit
        case .transit: return .exploring
        case .exploring: return postcards.count >= target ? .returning : .postcardReady
        case .returning: return .resting
        case .postcardReady:
            return postcards.count >= target ? .returning : .exploring
        }
    }

    private func progressMessage(_ message: String, plans: [PostcardBacklogPlan]) -> String {
        let slots = plans.flatMap(\.slots)
        let waiting = slots.filter { $0.event == nil || $0.event?.postcardStatus == .pendingImage }.count
        let manual = slots.filter { $0.event?.postcardStatus == .imageUnavailable }.count
        var parts = [message]
        if waiting > 0 { parts.append("\(waiting) 张等待自动处理") }
        if manual > 0 { parts.append("\(manual) 张已停止自动重试，可在旅行册手动重试") }
        return parts.joined(separator: " · ")
    }

    private func completeImage(_ work: PendingImageWork, mode: TravelMode, backlog: PostcardBacklogStore? = nil) async throws -> (ready: Bool, message: String) {
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
            let result = ImageResultEnvelope(eventId: work.event.id, status: .failed,
                attemptedAt: clock(), relativePath: nil, reason: reason, attemptToken: work.attemptToken,
                attemptCount: work.imageAttemptCount, publishedNarrativeHash: work.publishedNarrativeHash)
            let acknowledgement = try backlog.map { try $0.markImage(result, mode: mode) }
                ?? repository.markImage(result, mode: mode)
            return (false, acknowledgement.status == .imageUnavailable
                ? "照片生成失败，自动重试已停止；可在旅行册手动重试" : reason)
        }
        // Once handed to markImage, a failed write can already have committed the ready intent.
        // Keep the generated file for repository recovery; never overwrite that intent with failed.
        let result = ImageResultEnvelope(eventId: work.event.id, status: .ready,
            attemptedAt: clock(), relativePath: path, reason: nil, attemptToken: work.attemptToken,
            attemptCount: work.imageAttemptCount, publishedNarrativeHash: work.publishedNarrativeHash)
        _ = try backlog.map { try $0.markImage(result, mode: mode) } ?? repository.markImage(result, mode: mode)
        return (true, "收到一张新照片")
    }

    private func loadState(recoveryGap: TimeInterval) throws -> AutomaticTravelState {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return AutomaticTravelState() }
        let data = try Data(contentsOf: stateURL)
        do {
            let state = try JSONDecoder.travelCat.decode(AutomaticTravelState.self, from: data)
            guard state.schemaVersion == 1 else { throw CocoaError(.fileReadCorruptFile) }
            return state
        } catch {
            // Preserve exact bytes before replacing a damaged scheduling cache. The
            // journal and independent postcard backlog remain the recovery authority.
            let backup = stateURL.deletingLastPathComponent().appendingPathComponent("automatic-travel.corrupt-\(UUID().uuidString).json")
            try AtomicFileWriter().write(data, to: backup)
            var rebuilt = AutomaticTravelState()
            rebuilt.nextModelActionAt = clock().addingTimeInterval(recoveryGap)
            try save(rebuilt)
            return rebuilt
        }
    }

    private func save(_ state: AutomaticTravelState) throws {
        try AtomicFileWriter().write(JSONEncoder.travelCat.encode(state), to: stateURL)
        didChange()
    }
}

private struct WorkerClock: TravelClock, @unchecked Sendable {
    let read: () -> Date
    var now: Date { read() }
}
