import AppKit
import Combine
import Foundation

/// Owns a single wake-up and at most one in-flight operation, independent of window visibility.
@MainActor
final class AutomaticTravelController: ObservableObject {
    @Published private(set) var message = "正在安排下一次旅行"
    @Published private(set) var nextCheckAt: Date?
    @Published private(set) var isRunning = false
    private let isEnabled: () -> Bool
    private let run: () async throws -> AutomaticTravelOutcome
    private var task: Task<Void, Never>?
    private var timer: Timer?
    private var generation = UUID()
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []

    init(isEnabled: @escaping () -> Bool, run: @escaping () async throws -> AutomaticTravelOutcome) {
        self.isEnabled = isEnabled
        self.run = run
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

    func refresh() {
        timer?.invalidate()
        timer = nil
        guard isEnabled() else { pause(); return }
        guard task == nil else { return }
        let token = generation
        isRunning = true
        message = "正在查看旅途消息"
        task = Task { [weak self] in
            guard let self else { return }
            let outcome: AutomaticTravelOutcome
            do { outcome = try await run() }
            catch is CancellationError { return }
            catch { outcome = .init(nextCheckAt: Date().addingTimeInterval(60), message: "旅行数据暂时无法读取，稍后重试") }
            guard !Task.isCancelled, generation == token else { return }
            task = nil
            isRunning = false
            message = outcome.message
            nextCheckAt = outcome.nextCheckAt
            let timer = Timer(timeInterval: max(1, min(60, outcome.nextCheckAt.timeIntervalSinceNow)), repeats: false) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func pause() {
        generation = UUID()
        timer?.invalidate()
        timer = nil
        task?.cancel()
        task = nil
        isRunning = false
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
