import Foundation
import Darwin

enum AgentXPiRuntimeError: Error, LocalizedError, Equatable, Sendable {
    case missingRuntime, missingCredential, invalidRequest, processFailed, invalidResponse, timeout
    var errorDescription: String? {
        switch self {
        case .missingRuntime: "应用内置的 Pi 运行时缺失，请重新安装应用。"
        case .missingCredential: "请先为 OpenRouter 配置 API Key。"
        case .invalidRequest: "对话请求无效或超出运行时限制。"
        case .processFailed: "Pi 运行时未能完成请求，请稍后重试。"
        case .invalidResponse: "Pi 运行时未返回完整、有效的回复。"
        case .timeout: "Pi 运行时请求超时，请稍后重试。"
        }
    }
}

/// Each turn reconstructs the official Pi Agent from the host transcript and current model.
/// There is deliberately no PATH, developer checkout, or environment credential fallback.
@MainActor
struct AgentXPiRuntime: AgentXRunAdapter {
    let runtimeCore = "pi-agent-core"
    private let nodeURL: URL?
    private let runnerURL: URL?
    private let timeout: TimeInterval
    private let ledgerRoot: URL?

    init(ledgerRoot: URL? = nil) {
        self.ledgerRoot = ledgerRoot
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" {
            nodeURL = bundle.appendingPathComponent("Contents/Helpers/PiAgent/node")
            runnerURL = bundle.appendingPathComponent("Contents/Resources/PiAgent/runner.mjs")
        } else { nodeURL = nil; runnerURL = nil }
        timeout = 65
    }
    /// Explicit injection supports local process fixtures; production uses the bundled initializer.
    init(nodeURL: URL, runnerURL: URL, timeout: TimeInterval = 65, ledgerRoot: URL? = nil) {
        self.ledgerRoot = ledgerRoot
        self.nodeURL = nodeURL; self.runnerURL = runnerURL
        self.timeout = timeout.isFinite ? max(0.01, min(timeout, 300)) : 65
    }
    var localHealth: String {
        let files = FileManager.default
        func isRegularFile(_ url: URL) -> Bool {
            (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        guard let nodeURL, isRegularFile(nodeURL), files.isExecutableFile(atPath: nodeURL.path),
              let runnerURL else { return "missing_runtime" }

        // These are the two direct imports in runner.mjs and their pinned package manifests.
        let sdk = runnerURL.deletingLastPathComponent().appendingPathComponent("node_modules/@earendil-works")
        let required = [runnerURL, sdk.appendingPathComponent("pi-agent-core/package.json"),
                        sdk.appendingPathComponent("pi-agent-core/dist/index.js"),
                        sdk.appendingPathComponent("pi-ai/package.json"),
                        sdk.appendingPathComponent("pi-ai/dist/api/openai-completions.js")]
        return required.allSatisfy { isRegularFile($0) && files.isReadableFile(atPath: $0.path) }
            ? "ready" : "missing_runtime"
    }

    func capabilities(streaming: Bool) -> [String: Bool] {
        ["start": true, "stop": true, "stream": streaming, "usage": streaming, "tools": false, "step": false]
    }

    func prepare(provider: AgentXProvider, model: String, secret: String?, messages: [AgentXMessage]) throws -> Data {
        if provider.isOpenRouter && (secret?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            throw AgentXPiRuntimeError.missingCredential
        }
        guard provider.serviceProtocol == .openAICompatible, !model.isEmpty, model.utf8.count <= 512,
              !messages.isEmpty, messages.count <= 512, messages.last?.role == "user",
              messages.reduce(0, { $0 + $1.content.utf8.count }) <= PiChildProcess.maximumRequest else {
            throw AgentXPiRuntimeError.invalidRequest
        }
        let metadata = provider.modelSelection?.models.first(where: { $0.id == model })
        let request = Request(version: 1, baseURL: provider.baseURL, model: model, secret: secret ?? "", messages: messages,
                              metadata: .init(contextLength: metadata?.contextLength))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var payload = try encoder.encode(request)
        payload.append(10)
        guard payload.count <= PiChildProcess.maximumRequest else { throw AgentXPiRuntimeError.invalidRequest }
        return payload
    }

    func respond(provider: AgentXProvider, model: String, secret: String?, messages: [AgentXMessage]) async throws -> String {
        let payload = try prepare(provider: provider, model: model, secret: secret, messages: messages)
        return try await respond(payload: payload, secret: secret)
    }

    func respond(payload: Data, secret: String?) async throws -> String {
        try await run(payload: payload, secret: secret, progress: nil)
    }

    func respond(payload: Data, secret: String?, onProgress: @escaping @MainActor @Sendable (AgentXRunProgress) throws -> Void) async throws -> String {
        struct Endpoint: Decodable { let baseURL: String; let secret: String }
        guard (secret ?? "").isEmpty, payload.count <= PiChildProcess.maximumRequest,
              let endpoint = try? JSONDecoder().decode(Endpoint.self, from: payload), endpoint.secret.isEmpty,
              let url = URLComponents(string: endpoint.baseURL), url.scheme?.lowercased() == "http",
              ["127.0.0.1", "[::1]", "::1"].contains(url.host ?? ""), url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { throw AgentXPiRuntimeError.invalidRequest }
        return try await run(payload: payload, secret: secret, progress: onProgress)
    }

    func execute(runID: String, payload: Data, progress: AgentXRunProgressHandler?) async throws -> String {
        try await AgentXPiExecutionContext.$runID.withValue(runID) {
            if let progress {
                return try await respond(payload: payload, secret: nil, onProgress: progress)
            }
            return try await respond(payload: payload, secret: nil)
        }
    }

    func confirmedExit(runID: String) -> Bool {
        guard let ledgerRoot, let owner = AgentXStopProcessIdentity.read(getpid()) else { return false }
        return (try? AgentXPiProcessLedger(root: ledgerRoot).confirmedExited(owner: owner, runID: runID)) == true
    }

    private func run(payload: Data, secret: String?, progress: AgentXRunProgressHandler?) async throws -> String {
        try Task.checkCancellation()
        guard let nodeURL, let runnerURL,
              FileManager.default.isExecutableFile(atPath: nodeURL.path),
              FileManager.default.isReadableFile(atPath: runnerURL.path) else { throw AgentXPiRuntimeError.missingRuntime }
        struct GatewayLimits: Decodable { let gatewayToken: String; let timeoutSeconds: Int; let secret: String; let baseURL: String }
        var executionTimeout = timeout
        if let limits = try? JSONDecoder().decode(GatewayLimits.self, from: payload) {
            guard progress != nil, limits.secret.isEmpty, (1...300).contains(limits.timeoutSeconds),
                  limits.gatewayToken.wholeMatch(of: /[a-f0-9-]{72}/) != nil,
                  let url = URLComponents(string: limits.baseURL), url.scheme == "http", url.host == "127.0.0.1" else { throw AgentXPiRuntimeError.invalidRequest }
            executionTimeout = Double(limits.timeoutSeconds) + 5
        }
        let cancellation = PiCancellation()
        let configuration = PiChildProcess(nodeURL: nodeURL, runnerURL: runnerURL, payload: payload, timeout: executionTimeout, ledgerRoot: ledgerRoot, runID: AgentXPiExecutionContext.runID, progress: progress)
        let output: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try configuration.run(cancellation: cancellation) })
                }
            }
        } onCancel: { cancellation.cancel() }
        try Task.checkCancellation()
        guard let response = try? JSONDecoder().decode(Response.self, from: output), response.version == 1 else {
            throw AgentXPiRuntimeError.invalidResponse
        }
        guard response.ok else {
            switch response.code {
            case "missing_credential": throw AgentXPiRuntimeError.missingCredential
            case "invalid_request": throw AgentXPiRuntimeError.invalidRequest
            case "timeout": throw AgentXPiRuntimeError.timeout
            case "provider_error", "runtime_error", "tools_disabled", "cancelled": throw AgentXPiRuntimeError.processFailed
            default: throw AgentXPiRuntimeError.invalidResponse
            }
        }
        guard let text = response.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 65_536, !(secret.map { !$0.isEmpty && text.contains($0) } ?? false) else {
            throw AgentXPiRuntimeError.invalidResponse
        }
        return text
    }
    private struct Request: Encodable {
        var version: Int; var baseURL: String; var model: String; var secret: String; var messages: [AgentXMessage]
        var metadata: Metadata
        struct Metadata: Encodable { var contextLength: Int? }
    }
    private struct Response: Decodable { var version: Int; var ok: Bool; var text: String?; var code: String? }
}

private final class PiCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Streaming stdout uses one JSON object per line, ending with the existing response envelope.
private struct PiProgressFrames {
    private var partial = Data()
    private var visible = ""
    private var visibleBytes = 0
    private var receivedUsage = false
    private var totalBytes = 0
    private(set) var terminal: Data?

    private struct Frame: Decodable {
        var event: String?
        var text: String?
        var input: Int?
        var output: Int?
        var version: Int?
        var ok: Bool?
    }

    mutating func append(_ bytes: ArraySlice<UInt8>, deliver: (AgentXRunProgress) throws -> Void) throws {
        totalBytes += bytes.count
        guard totalBytes <= 2_097_152 else { throw AgentXPiRuntimeError.invalidResponse }
        var remaining = bytes
        while !remaining.isEmpty {
            guard terminal == nil else { throw AgentXPiRuntimeError.invalidResponse }
            let newline = remaining.firstIndex(of: 10)
            let end = newline ?? remaining.endIndex
            guard partial.count + remaining.distance(from: remaining.startIndex, to: end) <= 131_072 else {
                throw AgentXPiRuntimeError.invalidResponse
            }
            partial.append(contentsOf: remaining[..<end])
            guard let newline else { break }
            guard let frame = try? JSONDecoder().decode(Frame.self, from: partial) else { throw AgentXPiRuntimeError.invalidResponse }
            switch frame.event {
            case "text":
                guard let delta = frame.text, !delta.isEmpty, delta.utf8.count <= 4096 else {
                    throw AgentXPiRuntimeError.invalidResponse
                }
                visibleBytes += delta.utf8.count
                guard visibleBytes <= 65_536 else { throw AgentXPiRuntimeError.invalidResponse }
                visible += delta
                try deliver(.text(delta))
            case "usage":
                guard !receivedUsage, let input = frame.input, let output = frame.output, input >= 0, output >= 0 else {
                    throw AgentXPiRuntimeError.invalidResponse
                }
                receivedUsage = true
                try deliver(.usage(input: input, output: output))
            case nil:
                guard frame.version == 1, let ok = frame.ok, !ok || frame.text?.utf8.elementsEqual(visible.utf8) == true else {
                    throw AgentXPiRuntimeError.invalidResponse
                }
                terminal = partial
            default:
                throw AgentXPiRuntimeError.invalidResponse
            }
            partial.removeAll(keepingCapacity: true)
            remaining = remaining[remaining.index(after: newline)...]
        }
    }
}

/// A dedicated worker owns the process and all pipe descriptors until it is reaped.
/// Nonblocking reads/writes prevent a large request or noisy stderr from deadlocking.
private struct PiChildProcess: Sendable {
    static let maximumRequest = 1_048_576
    private static let maximumOutput = 131_072
    var nodeURL: URL; var runnerURL: URL; var payload: Data; var timeout: TimeInterval
    var ledgerRoot: URL?; var runID: String?
    var progress: AgentXRunProgressHandler?

    func run(cancellation: PiCancellation) throws -> Data {
        if cancellation.isCancelled { throw CancellationError() }
        let ledger = ledgerRoot.map { AgentXPiProcessLedger(root: $0) }
        var receipt: UUID?
        if let ledger {
            guard let runID, let owner = AgentXStopProcessIdentity.read(getpid()) else { throw AgentXPiRuntimeError.processFailed }
            receipt = try ledger.begin(owner: owner, runID: runID)
        }
        let process = Process()
        var didLaunch = false
        var didReap = false
        let input = Pipe(), output = Pipe(), diagnostic = Pipe()
        process.executableURL = nodeURL
        process.arguments = progress == nil ? [runnerURL.path] : [runnerURL.path, "--stream-loopback"]
        process.currentDirectoryURL = runnerURL.deletingLastPathComponent()
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "TMPDIR": "/private/tmp",
                               "AGENTX_PI_OWNER_PID": String(getpid())]
        process.standardInput = input; process.standardOutput = output; process.standardError = diagnostic
        defer {
            if didLaunch && !didReap {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                didReap = true
            }
            // A failed launch created no child; otherwise record only explicit reaping.
            if (!didLaunch || didReap), let ledger, let receipt { try? ledger.reaped(id: receipt) }
            for handle in [input.fileHandleForReading, input.fileHandleForWriting, output.fileHandleForReading,
                           output.fileHandleForWriting, diagnostic.fileHandleForReading, diagnostic.fileHandleForWriting] {
                try? handle.close()
            }
        }
        do { try process.run(); didLaunch = true } catch { throw AgentXPiRuntimeError.processFailed }
        if let ledger, let receipt {
            if let child = AgentXStopProcessIdentity.read(process.processIdentifier) {
                try ledger.launched(id: receipt, child: child)
            } else if !process.isRunning {
                process.waitUntilExit()
                didReap = true
            } else { throw AgentXPiRuntimeError.processFailed }
        }
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? diagnostic.fileHandleForWriting.close()
        let writeFD = input.fileHandleForWriting.fileDescriptor
        let readFD = output.fileHandleForReading.fileDescriptor
        let errorFD = diagnostic.fileHandleForReading.fileDescriptor
        for descriptor in [writeFD, readFD, errorFD] {
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw AgentXPiRuntimeError.processFailed }
        }
        guard fcntl(writeFD, F_SETNOSIGPIPE, 1) == 0 else { throw AgentXPiRuntimeError.processFailed }
        let started = ProcessInfo.processInfo.systemUptime
        var sent = 0; var inputClosed = false; var outputEOF = false; var errorEOF = false
        var received = Data()
        var frames = PiProgressFrames()
        var failure: (any Error)?
        var terminatedAt: TimeInterval?
        var didKill = false
        while true {
            let now = ProcessInfo.processInfo.systemUptime
            if failure == nil {
                if cancellation.isCancelled { failure = CancellationError() }
                else if now - started >= timeout { failure = AgentXPiRuntimeError.timeout }
            }
            if failure != nil, process.isRunning {
                if terminatedAt == nil { process.terminate(); terminatedAt = now }
                else if !didKill && now - terminatedAt! >= 0.2 { kill(process.processIdentifier, SIGKILL); didKill = true }
            }
            if !inputClosed {
                if failure == nil, sent < payload.count {
                    let count = payload.withUnsafeBytes { bytes in
                        Darwin.write(writeFD, bytes.baseAddress!.advanced(by: sent), min(8192, payload.count - sent))
                    }
                    if count > 0 { sent += count }
                    else if count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                        failure = AgentXPiRuntimeError.processFailed
                    }
                }
                if sent == payload.count || failure != nil || !process.isRunning { try? input.fileHandleForWriting.close(); inputClosed = true }
            }
            // Limit work per iteration so cancellation cannot be starved by a noisy child.
            for (descriptor, isOutput) in [(readFD, true), (errorFD, false)] {
                for _ in 0..<16 {
                    var buffer = [UInt8](repeating: 0, count: 8192)
                    let count = Darwin.read(descriptor, &buffer, buffer.count)
                    if count > 0 {
                        if isOutput, failure == nil {
                            if let progress {
                                do {
                                    try frames.append(buffer.prefix(count)) { event in
                                        // The pipe worker waits for each callback, including any journal write.
                                        // This preserves order and propagates callback failures before the next record.
                                        try DispatchQueue.main.sync {
                                            guard !cancellation.isCancelled else { throw CancellationError() }
                                            try MainActor.assumeIsolated { try progress(event) }
                                        }
                                    }
                                } catch { failure = error }
                            } else if received.count + count > Self.maximumOutput { failure = AgentXPiRuntimeError.invalidResponse }
                            else { received.append(contentsOf: buffer.prefix(count)) }
                        }
                    } else {
                        if count == 0 { if isOutput { outputEOF = true } else { errorEOF = true } }
                        else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { failure = AgentXPiRuntimeError.processFailed }
                        break
                    }
                }
            }
            if !process.isRunning {
                process.waitUntilExit()
                didReap = true
                if failure != nil || (outputEOF && errorEOF) {
                    if cancellation.isCancelled { throw CancellationError() }
                    if let failure { throw failure }
                    guard process.terminationReason == .exit && process.terminationStatus == 0 else { throw AgentXPiRuntimeError.processFailed }
                    if progress != nil {
                        guard let terminal = frames.terminal else { throw AgentXPiRuntimeError.invalidResponse }
                        return terminal
                    }
                    return received
                }
            }
            // Poll without blocking the main actor. The maximum cancellation latency is 10 ms.
            usleep(10_000)
        }
    }
}
