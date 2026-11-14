import Foundation

/// Host-owned lifecycle evidence, separate from persisted app preferences.
@MainActor
final class AgentXHostRuntimeLifecycle {
    struct Runtime {
        var fence: () -> Void
        var drain: () async throws -> Void
        var isIdle: () -> Bool
        var hasExited: () -> Bool
        var resume: () -> Void
    }
    private let controller: AgentXController
    private var runtimes: [String: Runtime] = [:]
    private var generations: [String: UUID] = [:]
    private var enabled: [String: Bool] = [:]
    init(controller: AgentXController) {
        self.controller = controller
        controller.externalRuntimeStop = { [weak self] id in
            guard let self else { throw AgentXStopFailure.unavailable }
            try await self.stop(id)
        }
        controller.externalRuntimeHasOwnedWork = { [weak self] id in
            guard let runtime = self?.runtimes[id] else { return nil }
            return !runtime.isIdle()
        }
        controller.externalRuntimeGeneration = { [weak self] id in self?.generations[id] }
        controller.externalRuntimeIsStopped = { [weak self] id in
            guard let self else { return false }
            if let runtime = self.runtimes[id] { return runtime.isIdle() && runtime.hasExited() }
            return self.controller.state.apps.first(where: { $0.id == id })?.kind == .chat
        }
    }
    func register(_ id: String, runtime: Runtime) {
        runtimes[id] = runtime
        generations[id] = UUID()
        controller.invalidateRuntimeStopEvidence(id)
        enabled[id] = controller.isLoaded && AgentXApplicationPolicy.isEnabled(id, in: controller.state)
        if enabled[id] != true { runtime.fence() }
        if controller.stopOperations[id]?.status == .unverified {
            Task { [weak controller] in try? await controller?.setApplicationEnabled(id, enabled: false) }
        }
    }
    /// Invoked synchronously from controller.didChange, before another MainActor task runs.
    func synchronize() {
        for (id, runtime) in runtimes {
            let next = controller.isLoaded && AgentXApplicationPolicy.isEnabled(id, in: controller.state)
            if !next { runtime.fence() }
            else if enabled[id] == false { runtime.resume() }
            enabled[id] = next
        }
    }
    func stop(_ id: String) async throws {
        if let runtime = runtimes[id] {
            let generation = generations[id]
            runtime.fence()
            try await runtime.drain()
            guard generations[id] == generation else { throw AgentXStopFailure.replacedRuntime }
            guard runtime.isIdle(), runtime.hasExited() else { throw AgentXStopFailure.activeWork }
        } else if controller.state.apps.first(where: { $0.id == id })?.kind != .chat {
            throw AgentXStopFailure.unregistered
        }
    }
    func requireIdle(_ id: String) throws {
        try controller.requirePackageSnapshotIdle()
        if let runtime = runtimes[id] {
            guard runtime.isIdle(), runtime.hasExited() else {
                throw AgentXError.invalid("目标应用任务或外部执行器尚未确认全部退出，不能更改应用包。")
            }
        } else if let application = controller.state.apps.first(where: { $0.id == id }), application.kind != .chat {
            throw AgentXError.invalid("目标应用未注册运行器停止验证，不能更改应用包。")
        }
        // A new ID or a text-only app has no external runtime in this host.
        // Workbench's registered runtime owns its native registry verification.
    }
    func applicationService() -> AgentXManagedApplicationService {
        AgentXManagedApplicationService(controller: controller, requireIdle: { [weak self] id in
            guard let self else { throw AgentXError.unavailable }
            try self.requireIdle(id)
        })
    }
}
