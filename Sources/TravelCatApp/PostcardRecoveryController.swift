import Foundation
import TravelCore
import TravelStorage
import TravelUI

/// User-triggered image retries have their own lifecycle, including while automatic travel
/// is paused. The worker remains the sole owner of model locking and pacing.
@MainActor
final class PostcardRecoveryController {
    private let repository: TravelRepository
    private let model: AppModel
    private let worker: AutomaticTravelWorker
    private let settings: () -> TravelSettings
    private let isReady: () -> Bool
    private let isApplicationEnabled: () -> Bool
    private let applyContents: ((RepositoryContents, [TripEvent], [UUID: PostcardPresentationReference]) -> Void)?
    private let didRefresh: () -> Void
    private let now: () -> Date
    private let sleep: (TimeInterval) async throws -> Void
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var restartAfterDrain: Set<UUID> = []
    private var stopped = false
    private var isApplicationSuspended = false
    private var resumePendingAutomatically = true
    var hasOwnedOperations: Bool { !tasks.isEmpty }
    private var retryNotice: (eventID: UUID, message: String)?

    init(repository: TravelRepository, model: AppModel, worker: AutomaticTravelWorker,
         settings: @escaping () -> TravelSettings, isReady: @escaping () -> Bool,
         isApplicationEnabled: @escaping () -> Bool = { true },
         applyContents: ((RepositoryContents, [TripEvent], [UUID: PostcardPresentationReference]) -> Void)? = nil,
         didRefresh: @escaping () -> Void = {},
         now: @escaping () -> Date = Date.init,
         sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.didRefresh = didRefresh
        self.applyContents = applyContents
        self.repository = repository
        self.model = model
        self.worker = worker
        self.settings = settings
        self.isReady = isReady
        self.isApplicationEnabled = isApplicationEnabled
        self.now = now
        self.sleep = sleep
    }

    func start() {
        guard !isApplicationSuspended, isApplicationEnabled() else { return }
        stopped = false
        resumePendingAutomatically = true
        bindActions()
        refresh()
    }

    func stop() {
        stopped = true
        restartAfterDrain.removeAll()
        tasks.values.forEach { $0.cancel() }
    }

    func suspendAndWait() async {
        isApplicationSuspended = true
        resumePendingAutomatically = false
        stop()
        let pending = Array(tasks.values)
        for operation in pending { await operation.value }
    }

    /// Rebinds manual actions without replaying the saved request queue.
    @discardableResult
    func resumeWithoutRunning() -> Bool {
        guard tasks.isEmpty else { return false }
        restartAfterDrain.removeAll()
        resumePendingAutomatically = false
        isApplicationSuspended = false
        stopped = false
        bindActions()
        return true
    }

    private func bindActions() {
        model.retryPostcardAction = { [weak self] in self?.requestRetry($0) }
        model.postcardOpenedAction = { [weak self] in self?.postcardOpened($0) }
    }

    func refresh() {
        guard !stopped, !isApplicationSuspended, isApplicationEnabled() else { return }
        defer { didRefresh() }
        do {
            let contents = try repository.loadContents()
            let backlog = try PostcardBacklogStore(root: repository.root)
            let plans = try backlog.reconcile(events: contents.events)
            let supplemental = try backlog.supplementalEvents()
            var retries: [UUID: ImageRetry] = [:]
            for slot in plans.flatMap(\.slots) {
                guard let eventID = slot.eventID else { continue }
                retries[eventID] = try slot.isSupplement
                    ? backlog.imageRetry(for: eventID) : repository.imageRetry(for: eventID)
            }
            model.updatePostcardWork(PostcardWorkProjection.items(plans: plans, retries: retries, now: now(), damagedImageIDs: try backlog.damagedReadyImageIDs()),
                                     manualRetryMessage: retryNotice?.message, manualRetryEventID: retryNotice?.eventID)
            let references: [UUID: PostcardPresentationReference] = [:]
            if let applyContents { applyContents(contents, supplemental, references) }
            else {
                model.apply(next: contents.snapshot, events: contents.events + supplemental,
                    presentationReferences: contents.presentationReferences.merging(references) { _, extra in extra },
                    characterProfile: contents.characterProfile)
            }
            // Bootstrap persisted one-shot requests after a restart without enabling
            // automatic travel. Repeated refreshes cannot dispatch the same request.
            let allEvents = contents.events + supplemental
            for event in allEvents where event.postcardStatus == .pendingImage {
                if resumePendingAutomatically, retries[event.id]?.manualRequests.isEmpty == false,
                   try backlog.characterProfile(for: event.tripID) == .defaultBlackCat { schedule(event.id) }
            }
        } catch {
            model.updatePostcardWork(model.postcardWorkItems,
                error: "明信片记录暂时无法读取，原始文件已保留。可在设置中尝试从安全副本恢复；不会清空补发记录。",
                manualRetryMessage: retryNotice?.message, manualRetryEventID: retryNotice?.eventID)
        }
    }

    private func postcardOpened(_ eventID: UUID) {
        guard !stopped, !isApplicationSuspended, isApplicationEnabled() else { return }
        if model.postcardWorkError != nil || !model.postcardWorkItems.contains(where: { $0.eventID == eventID }) {
            refresh()
        }
        guard model.postcardWorkError == nil,
              let item = model.postcardWorkItems.first(where: { $0.eventID == eventID }) else { return }
        if item.status == .manualRequired {
            requestRetry(eventID, whenOpened: true)
        } else if item.hasUserRetryRequest, item.status == .pending || item.status == .generating, canRequestRetry(eventID) {
            // Reconcile the existing lease if its prior owner stopped before publishing a result.
            schedule(eventID)
        }
    }

    private func canRequestRetry(_ eventID: UUID) -> Bool {
        guard !stopped, !isApplicationSuspended, isApplicationEnabled() else { return false }
        guard isReady() else {
            retryNotice = (eventID, "请先完成生成服务配置，再重试图片。")
            refresh()
            return false
        }
        return true
    }

    func requestRetry(_ eventID: UUID, whenOpened: Bool = false) {
        guard canRequestRetry(eventID) else { return }
        do {
            let backlog = try PostcardBacklogStore(root: repository.root)
            let supplemental = try backlog.supplementalEvents()
            let isSupplement = supplemental.contains { $0.id == eventID }
            let allEvents = try repository.events() + supplemental
            guard let event = allEvents.first(where: { $0.id == eventID }),
                  try backlog.characterProfile(for: event.tripID) == .defaultBlackCat else {
                retryNotice = (eventID, "自定义角色暂不支持此生成服务，已保留原记录。")
                refresh()
                return
            }
            let mode = settings().mode
            let queued = try isSupplement
                ? backlog.requestManualImageRetry(eventID: eventID, mode: mode, whenOpened: whenOpened)
                : repository.requestManualImageRetry(eventID: eventID, mode: mode, whenOpened: whenOpened)
            if queued, retryNotice?.eventID == eventID { retryNotice = nil }
            refresh()
            if queued || model.postcardWorkItems.contains(where: { $0.eventID == eventID && $0.isManualQueued }) {
                schedule(eventID)
            }
        } catch {
            retryNotice = (eventID, "无法安排这次重试，请稍后再试。")
            refresh()
        }
    }

    private func schedule(_ eventID: UUID) {
        guard !stopped, !isApplicationSuspended, isApplicationEnabled(), isReady() else { return }
        if let existing = tasks[eventID] {
            // Only explicit start/request paths can reach a cancelled slot after
            // stop; preserve that intent without overlapping the exiting worker.
            if existing.isCancelled { restartAfterDrain.insert(eventID) }
            return
        }
        tasks[eventID] = Task { [weak self] in
            guard let self else { return }
            defer {
                tasks[eventID] = nil
                if restartAfterDrain.remove(eventID) != nil { schedule(eventID) }
            }
            do {
                while !Task.isCancelled && !stopped && !isApplicationSuspended && isApplicationEnabled() && isReady() {
                    let outcome = try await worker.step(settings: settings(), manualEventID: eventID) { stage in
                        guard stage == .imageHandling else { return }
                        if self.retryNotice?.eventID == eventID { self.retryNotice = nil }
                        self.refresh()
                    }
                    guard !Task.isCancelled, !stopped, !isApplicationSuspended, isApplicationEnabled(), isReady() else { return }
                    retryNotice = (eventID, outcome.message)
                    refresh()
                    let backlog = try PostcardBacklogStore(root: repository.root)
                    let events = try repository.events() + backlog.supplementalEvents()
                    guard events.contains(where: { $0.id == eventID && $0.postcardStatus == .pendingImage }) else { return }
                    try await sleep(max(1, min(60, outcome.nextCheckAt.timeIntervalSince(now()))))
                }
            } catch is CancellationError {
                // The persisted lease/request remains available to normal recovery.
            } catch {
                retryNotice = (eventID, "重试暂时无法完成，已保留请求。修复服务或重新打开应用后可继续。")
                refresh()
            }
        }
    }
}
