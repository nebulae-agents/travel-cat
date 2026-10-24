import Foundation

@MainActor
protocol AgentRuntimeClient: AnyObject {
    var onEvent: (([String: Any]) -> Void)? { get set }
    var onExit: (() -> Void)? { get set }
    func launch(python: String) throws
    func request(_ method: String, _ params: [String: Any], timeout: UInt64) async throws -> [String: Any]
    func shutdown()
}
extension AgentRuntimeClient {
    func request(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        try await request(method, params, timeout: 120)
    }
}

/// All messages are delivered on MainActor. The child receives secrets only via its private stdin.
@MainActor
final class AgentSidecarClient: AgentRuntimeClient {
    var onEvent: (([String: Any]) -> Void)?
    var onExit: (() -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var diagnostics: FileHandle?
    private var buffer = Data()
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]
    private var deadlines: [String: Task<Void, Never>] = [:]
    private var generation = UUID()

    func launch(python: String) throws {
        if process?.isRunning == true { return }
        guard python.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: python),
              let script = Bundle.module.url(forResource: "sidecar", withExtension: "py", subdirectory: "AgentRuntime") else {
            throw WorkbenchFailure("缺少 Python 3.11+ 或 AgentRuntime 资源，请检查 Python 路径。")
        }
        let token = UUID(); generation = token
        let child = Process(), stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        child.executableURL = URL(fileURLWithPath: python)
        child.arguments = ["-I", "-B", "-u", script.path]
        // No inherited model credentials, PYTHONPATH or startup hooks.
        child.environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path, "LANG": "en_US.UTF-8"]
        child.standardInput = stdinPipe; child.standardOutput = stdoutPipe; child.standardError = stderrPipe
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.receive(data)
            }
        }
        // Drain diagnostics without persisting raw subprocess output.
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        child.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.disconnected()
            }
        }
        process = child; input = stdinPipe.fileHandleForWriting
        output = stdoutPipe.fileHandleForReading; diagnostics = stderrPipe.fileHandleForReading
        do { try child.run() } catch { disconnected(); throw WorkbenchFailure("无法启动隔离运行服务，请检查 Python 版本和路径。") }
    }

    func request(_ method: String, _ params: [String: Any] = [:], timeout: UInt64 = 120) async throws -> [String: Any] {
        guard process?.isRunning == true, let input else { throw WorkbenchFailure("运行服务未连接。") }
        let id = UUID().uuidString
        let payload = try Self.encodeRequest(id: id, method: method, params: params)
        let response: Data = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            deadlines[id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled, let self else { return }
                self.pending.removeValue(forKey: id)?.resume(throwing: WorkbenchFailure("操作超时，请核实任务状态；未自动重试。"))
                self.deadlines.removeValue(forKey: id)
            }
            do { try input.write(contentsOf: payload) }
            catch {
                deadlines.removeValue(forKey: id)?.cancel()
                pending.removeValue(forKey: id)?.resume(throwing: WorkbenchFailure("无法向运行服务发送消息。"))
            }
        }
        return (try JSONSerialization.jsonObject(with: response)) as? [String: Any] ?? [:]
    }

    static func encodeRequest(id: String, method: String, params: [String: Any]) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params], options: [.withoutEscapingSlashes]) + Data([10])
        guard data.count <= 6 * 1024 * 1024 else { throw WorkbenchFailure("请求超过 6 MiB，请减少附件或文字；其他任务未受影响。") }
        return data
    }

    func shutdown() {
        // EOF lets the sidecar stop only containers it owns.
        try? input?.close(); input = nil
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        guard buffer.count <= 8 * 1024 * 1024 else { process?.terminate(); disconnected(); return }
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer[..<end]; buffer.removeSubrange(...end)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                process?.terminate(); disconnected(); return
            }
            if let id = object["id"] as? String, let continuation = pending.removeValue(forKey: id) {
                deadlines.removeValue(forKey: id)?.cancel()
                if let error = object["error"] as? String { continuation.resume(throwing: WorkbenchFailure(error, taskRetained: object["taskRetained"] as? Bool)) }
                else { continuation.resume(returning: (try? JSONSerialization.data(withJSONObject: object["result"] as? [String: Any] ?? [:])) ?? Data("{}".utf8)) }
            } else if object["event"] is String { onEvent?(object) }
        }
    }
    private func disconnected() {
        generation = UUID()
        output?.readabilityHandler = nil; diagnostics?.readabilityHandler = nil
        try? input?.close(); input = nil; output = nil; diagnostics = nil; process = nil; buffer.removeAll()
        deadlines.values.forEach { $0.cancel() }; deadlines.removeAll()
        let waiting = pending.values; pending.removeAll()
        waiting.forEach { $0.resume(throwing: WorkbenchFailure("运行服务已断开；未自动重发任务。")) }
        onExit?()
    }
}
