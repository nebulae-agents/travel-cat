import Foundation

/// Main-actor ownership for work whose cancellation is not proof of completion.
@MainActor
final class AgentXOwnedTaskScope {
    private(set) var isEnabled = true
    private var tasks: [UUID: Task<Void, Never>] = [:]
    var isIdle: Bool { tasks.isEmpty }
    @discardableResult
    func start(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never>? {
        guard isEnabled else { return nil }
        let id = UUID()
        let task = Task { @MainActor in
            await operation()
            self.tasks[id] = nil
        }
        tasks[id] = task
        return task
    }
    func fence() {
        isEnabled = false
        for task in tasks.values { task.cancel() }
    }
    func suspendAndWait() async {
        fence()
        for task in Array(tasks.values) { await task.value }
    }
    @discardableResult func resumeWithoutRunning() -> Bool { guard isIdle else { return false }; isEnabled = true; return true }
}
