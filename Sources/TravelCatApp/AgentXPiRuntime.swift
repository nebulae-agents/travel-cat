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
struct AgentXPiRuntime {
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
    func respond(provider: AgentXProvider, model: String, secret: String?, messages: [AgentXMessage]) async throws -> String {
        try Task.checkCancellation()
        if provider.isOpenRouter && (secret?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            throw AgentXPiRuntimeError.missingCredential
        }
        guard provider.serviceProtocol == .openAICompatible, !model.isEmpty, model.utf8.count <= 512,
              !messages.isEmpty, messages.count <= 512, messages.last?.role == "user",
              messages.reduce(0, { $0 + $1.content.utf8.count }) <= PiChildProcess.maximumRequest else {
            throw AgentXPiRuntimeError.invalidRequest
        }
        guard let nodeURL, let runnerURL,
              FileManager.default.isExecutableFile(atPath: nodeURL.path),
              FileManager.default.isReadableFile(atPath: runnerURL.path) else { throw AgentXPiRuntimeError.missingRuntime }
        let metadata = provider.modelSelection?.models.first(where: { $0.id == model })
        let request = Request(version: 1, baseURL: provider.baseURL, model: model, secret: secret ?? "", messages: messages,
                              metadata: .init(contextLength: metadata?.contextLength))
        var payload = try JSONEncoder().encode(request)
        payload.append(10)
        guard payload.count <= PiChildProcess.maximumRequest else { throw AgentXPiRuntimeError.invalidRequest }
        let cancellation = PiCancellation()
        let configuration = PiChildProcess(nodeURL: nodeURL, runnerURL: runnerURL, payload: payload, timeout: timeout, ledgerRoot: ledgerRoot, runID: AgentXPiExecutionContext.runID)
        let output: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try configuration.run(cancellation: cancellation) })
                }
            }
        } onCancel: { cancellation.cancel() }
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

/// A dedicated worker owns the process and all pipe descriptors until it is reaped.
/// Nonblocking reads/writes prevent a large request or noisy stderr from deadlocking.
private struct PiChildProcess: Sendable {
    static let maximumRequest = 1_048_576
    private static let maximumOutput = 131_072
    var nodeURL: URL; var runnerURL: URL; var payload: Data; var timeout: TimeInterval
    var ledgerRoot: URL?; var runID: String?

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
        process.arguments = [runnerURL.path]
        process.currentDirectoryURL = runnerURL.deletingLastPathComponent()
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "TMPDIR": "/private/tmp"]
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
                            if received.count + count > Self.maximumOutput { failure = AgentXPiRuntimeError.invalidResponse }
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
                    return received
                }
            }
            // Poll without blocking the main actor. The maximum cancellation latency is 10 ms.
            usleep(10_000)
        }
    }
}
