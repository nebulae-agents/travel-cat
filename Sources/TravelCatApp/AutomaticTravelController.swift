import AppKit
import Combine
import Foundation

/// Owns a single wake-up and at most one in-flight operation, independent of window visibility.
@MainActor
final class AutomaticTravelController: ObservableObject {
    @Published private(set) var message = "正在安排下一次旅行"
    @Published private(set) var nextCheckAt: Date?
    @Published private(set) var isRunning = false
    @Published private(set) var progress: AutomaticTravelProgress?
    @Published private(set) var lastSuccessDate: Date?
    @Published private(set) var failure: AutomaticTravelFailure?
    var canRetryFailure: Bool { isEnabled() && !isRunning && task == nil && failure != nil && retry != nil }
    func retryFailure() {
        guard canRetryFailure else { return }
        refresh(retryingFailure: true)
    }
    private let retry: ((@escaping AutomaticTravelProgressHandler) async throws -> AutomaticTravelOutcome)?
    private let isEnabled: () -> Bool
    private let readLastSuccessDate: () -> Date?
    private let run: (@escaping AutomaticTravelProgressHandler) async throws -> AutomaticTravelOutcome
    private var task: Task<Void, Never>?
    private var timer: Timer?
    private var executionToken: UUID?
    private var failureRequiresFreshRun = false
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []

    convenience init(isEnabled: @escaping () -> Bool, run: @escaping () async throws -> AutomaticTravelOutcome,
                     retry: (() async throws -> AutomaticTravelOutcome)? = nil) {
        self.init(isEnabled: isEnabled, runWithProgress: { _ in try await run() },
                  retryWithProgress: retry.map { operation in { _ in try await operation() } })
    }

    init(isEnabled: @escaping () -> Bool,
         runWithProgress: @escaping (@escaping AutomaticTravelProgressHandler) async throws -> AutomaticTravelOutcome,
         retryWithProgress: ((@escaping AutomaticTravelProgressHandler) async throws -> AutomaticTravelOutcome)? = nil,
         lastSuccessDate: Date? = nil, readLastSuccessDate: @escaping () -> Date? = { nil }) {
        self.isEnabled = isEnabled
        self.run = runWithProgress; self.retry = retryWithProgress
        self.lastSuccessDate = lastSuccessDate
        self.readLastSuccessDate = readLastSuccessDate
    }

    /// Shared-worker manual image publication can complete while this controller is paused.
    func refreshSuccessfulPublicationDate() {
        if let success = readLastSuccessDate() { lastSuccessDate = success }
    }

    func start() {
        guard observers.isEmpty else { refresh(); return }
        for name in [NSNotification.Name.NSSystemClockDidChange, NSNotification.Name.NSSystemTimeZoneDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.refresh() } })
        refresh()
    }

    func settingsDidChange() {
        pause()
        refresh()
    }

    func refresh(retryingFailure: Bool = false) {
        timer?.invalidate()
        timer = nil
        guard isEnabled() else { pause(); return }
        guard task == nil else { return }
        let operation = retryingFailure && !failureRequiresFreshRun ? (retry ?? run) : run
        let token = UUID()
        executionToken = token
        nextCheckAt = nil
        isRunning = true
        message = "正在查看旅途消息"
        progress = .loadingPlanning
        task = Task { [weak self] in
            guard let self else { return }
            let outcome: AutomaticTravelOutcome
            var requiresFreshRun = false
            do {
                outcome = try await operation { [weak self] stage in
                    guard let self, self.executionToken == token, self.isRunning,
                          self.isEnabled(), !Task.isCancelled else { return }
                    self.progress = stage
                }
            }
            catch is CancellationError {
                outcome = .init(nextCheckAt: Date().addingTimeInterval(60), message: "旅行操作已取消，稍后重试")
            }
            catch {
                requiresFreshRun = true
                outcome = .init(nextCheckAt: Date().addingTimeInterval(60), message: "旅行数据暂时无法读取，稍后重试",
                    failure: AutomaticTravelFailure(error: error, recordedAt: Date()))
            }
            // A paused/replaced execution cannot finalize the current run or install its timer.
            guard executionToken == token else { return }
            guard isEnabled() else { pause(); return }
            task = nil
            isRunning = false
            progress = nil
            if let success = outcome.lastSuccessDate { lastSuccessDate = success }
            message = outcome.message
            failure = outcome.failure
            // A thrown error may occur before the worker persists a retryable failure.
            failureRequiresFreshRun = requiresFreshRun
            nextCheckAt = outcome.nextCheckAt
            let timer = Timer(timeInterval: max(1, min(60, outcome.nextCheckAt.timeIntervalSinceNow)), repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.executionToken == token, self.task == nil else { return }
                    self.refresh()
                }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func pause() {
        executionToken = nil
        timer?.invalidate()
        timer = nil
        task?.cancel()
        task = nil
        isRunning = false
        progress = nil
        nextCheckAt = nil
        message = "自动旅行已暂停"
    }

    func stop() {
        pause()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        workspaceObservers.removeAll()
    }
}
