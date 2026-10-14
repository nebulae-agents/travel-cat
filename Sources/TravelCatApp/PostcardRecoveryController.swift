import Foundation
import TravelCore
import TravelStorage
import TravelUI

/// Manual image requests have their own lifecycle, including while automatic travel
/// is paused. The worker remains the sole owner of model locking and pacing.
@MainActor
final class PostcardRecoveryController {
    private let repository: TravelRepository
    private let model: AppModel
    private let worker: AutomaticTravelWorker
    private let settings: () -> TravelSettings
    private let isReady: () -> Bool
    private let applyContents: ((RepositoryContents, [TripEvent], [UUID: PostcardPresentationReference]) -> Void)?
    private let didRefresh: () -> Void
    private let now: () -> Date
    private let sleep: (TimeInterval) async throws -> Void
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var stopped = false
    private var manualMessage: String?

    init(repository: TravelRepository, model: AppModel, worker: AutomaticTravelWorker,
         settings: @escaping () -> TravelSettings, isReady: @escaping () -> Bool,
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
        self.now = now
        self.sleep = sleep
    }

    func start() {
        stopped = false
        model.retryPostcardAction = { [weak self] in self?.requestRetry($0) }
        refresh()
    }

    func stop() {
        stopped = true
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
    }

    func refresh() {
        guard !stopped else { return }
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
                                     manualRetryMessage: manualMessage)
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
                if retries[event.id]?.manualRequests.isEmpty == false,
                   try backlog.characterProfile(for: event.tripID) == .defaultBlackCat { schedule(event.id) }
            }
        } catch {
            model.updatePostcardWork(model.postcardWorkItems,
                error: "明信片记录暂时无法读取，原始文件已保留。可在设置中尝试从安全副本恢复；不会清空补发记录。",
                manualRetryMessage: manualMessage)
        }
    }

    private func requestRetry(_ eventID: UUID) {
        guard isReady() else {
            manualMessage = "请先完成生成服务配置，再手动重试。"
            refresh()
            return
        }
        do {
            let backlog = try PostcardBacklogStore(root: repository.root)
            let allEvents = try repository.events() + backlog.supplementalEvents()
            guard let event = allEvents.first(where: { $0.id == eventID }),
                  try backlog.characterProfile(for: event.tripID) == .defaultBlackCat else {
                manualMessage = "自定义角色暂不支持此生成服务，已保留原记录。"
                refresh()
                return
            }
            if try backlog.supplementalEvents().contains(where: { $0.id == eventID }) {
                _ = try backlog.requestManualImageRetry(eventID: eventID, mode: settings().mode)
            } else {
                _ = try repository.requestManualImageRetry(eventID: eventID, mode: settings().mode)
            }
            manualMessage = "已安排一次手动重试；失败后仍会停止。"
            refresh()
            schedule(eventID)
        } catch {
            manualMessage = "无法安排这次重试，请稍后再试。"
            refresh()
        }
    }

    private func schedule(_ eventID: UUID) {
        guard !stopped, isReady(), tasks[eventID] == nil else { return }
        tasks[eventID] = Task { [weak self] in
            guard let self else { return }
            defer { tasks[eventID] = nil }
            do {
                while !Task.isCancelled && !stopped && isReady() {
                    let outcome = try await worker.step(settings: settings(), manualEventID: eventID)
                    manualMessage = outcome.message
                    refresh()
                    let backlog = try PostcardBacklogStore(root: repository.root)
                    let events = try repository.events() + backlog.supplementalEvents()
                    guard events.contains(where: { $0.id == eventID && $0.postcardStatus == .pendingImage }) else { return }
                    try await sleep(max(1, min(60, outcome.nextCheckAt.timeIntervalSince(now()))))
                }
            } catch is CancellationError {
                // The persisted lease/request remains available to normal recovery.
            } catch {
                manualMessage = "手动重试暂时无法完成，已保留请求；修复服务或重新打开应用后继续。"
                refresh()
            }
        }
    }
}
