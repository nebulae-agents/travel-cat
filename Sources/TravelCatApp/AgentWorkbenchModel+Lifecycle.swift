import Foundation

/// One gate covers every extension, including calls resumed after an async preflight.
/// A sealed model is never reused. Cleanup retains its transport until positively acknowledged.
@MainActor
final class AgentWorkbenchRuntimeGate: AgentRuntimeClient {
    let observationGeneration = UUID()
    private let underlying: any AgentRuntimeClient
    private(set) var isSealed = false
    private(set) var positivelyStopped = false
    private var launched = false
    private var runtimeStopped = false
    private var transportShutdown = false
    private var stopping = false
    private var pendingRequests = 0
    var hasOwnedOperations: Bool { (launched || isSealed) && !positivelyStopped || pendingRequests > 0 || stopping }
    var onEvent: (([String: Any]) -> Void)? {
        get { underlying.onEvent }
        set { underlying.onEvent = newValue }
    }
    var onExit: (() -> Void)? {
        get { underlying.onExit }
        set { underlying.onExit = newValue }
    }
    init(_ underlying: any AgentRuntimeClient) { self.underlying = underlying }
    func seal() { isSealed = true }
    func launch(python: String) throws {
        guard !isSealed else { throw WorkbenchFailure("工作台已停用，不能启动执行。") }
        try underlying.launch(python: python)
        launched = true
    }
    func request(_ method: String, _ params: [String: Any], timeout: UInt64) async throws -> [String: Any] {
        let cleanup = ["runtime_quiesce", "native_quiesce", "stop", "probe_cleanup", "cancel", "native_cancel", "native_login_cancel", "native_background_stop", "native_detach", "audit_ack"]
        guard !isSealed || cleanup.contains(method) else { throw WorkbenchFailure("工作台已停用，新的执行请求已阻止。") }
        guard !transportShutdown else { throw WorkbenchFailure("运行服务已关闭。") }
        launched = true // Even a failed transport request leaves ownership unverified.
        pendingRequests += 1
        defer { pendingRequests -= 1 }
        let result = try await underlying.request(method, params, timeout: timeout)
        // Suppress late login URLs/start receipts as well as subsequent RPCs.
        guard !isSealed || cleanup.contains(method) else { throw WorkbenchFailure("工作台已停用，迟到的执行结果已忽略。") }
        return result
    }
    func observeRuntime() async throws -> [String: Any] {
        guard !transportShutdown else { throw AgentXProbeFailure(.notConnected) }
        return try await underlying.observeRuntime()
    }
    func shutdown() {
        seal(); transportShutdown = true; underlying.shutdown()
    }
    func waitForExit(timeout: Duration) async -> Bool { await underlying.waitForExit(timeout: timeout) }

    /// The caller must verify its managed native daemon registry, even when this model never launched.
    func suspendAndWait(verifyNativeExit: @MainActor () async -> Bool, timeout: Duration = .seconds(30)) async throws {
        seal()
        guard !stopping else { throw WorkbenchFailure("正在确认停止，请等待后重试。") }
        stopping = true
        defer { stopping = false }
        positivelyStopped = false
        if launched && !runtimeStopped {
            let receipt = try await request("runtime_quiesce", [:], timeout: 180)
            guard receipt["stopped"] as? Bool == true else { throw WorkbenchFailure("仍有容器、探测或原生任务未确认停止，请清理后重试。") }
            runtimeStopped = true
        }
        guard !Task.isCancelled, await verifyNativeExit() else { throw WorkbenchFailure("原生后台退出尚未确认，请重试停止。") }
        if !transportShutdown { shutdown() }
        guard !Task.isCancelled, await underlying.waitForExit(timeout: timeout) else { throw WorkbenchFailure("运行服务退出尚未确认，请重试停止。") }
        // In-flight callers must finish unwinding before the package writer barrier can pass.
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while pendingRequests > 0 {
            guard !Task.isCancelled, ContinuousClock.now < deadline else { throw WorkbenchFailure("仍有运行请求尚未结束，请重试停止。") }
            try await Task.sleep(for: .milliseconds(10))
        }
        try Task.checkCancellation()
        positivelyStopped = true
    }
}

extension AgentWorkbenchModel {
    var hasOwnedOperations: Bool { client.hasOwnedOperations }
    var positivelyStopped: Bool { client.positivelyStopped }

    func suspendAndWait(verifyNativeExit: @MainActor () async -> Bool, timeout: Duration = .seconds(30)) async throws {
        // Flush current drafts before fencing execution; cleanup and audit storage remain available.
        persist()
        client.seal()
        storageGeneration = UUID(); storageTask?.cancel()
        invalidateAllArtifactReads()
        invalidateAllNativeBackgroundStatus(); nativeBackgroundVisibility.removeAll()
        try await client.suspendAndWait(verifyNativeExit: verifyNativeExit, timeout: timeout)
        hasShutdown = true
    }
}
