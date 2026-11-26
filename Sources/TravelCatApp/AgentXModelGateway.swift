import Foundation
import TravelStorage
@preconcurrency import Network

private final class AgentXGatewayNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// A disposable, single-submission gateway. The desktop owns its lifetime under the root lease.
@MainActor
final class AgentXModelGateway {
    enum Failure: Error { case unauthorized, invalidRequest, unavailable }
    let token = UUID().uuidString.lowercased() + UUID().uuidString.lowercased()
    let path: String
    private let permission: AgentXExecutionPolicy
    private let runID: String
    private let provider: AgentXProvider
    private let binding: AgentXGatewayConfiguration.Binding
    private let credential: () throws -> String?
    private let now: () -> Date
    private let beforeSubmit: () throws -> Void
    private let onUsage: (Int, Int) throws -> Void
    private let onComplete: (Bool) throws -> Void
    private let onClose: () throws -> Void
    private(set) var budgetFailure: String?
    private let expires: Date
    private let listener: NWListener
    private let session: URLSession
    private var used = false
    private var closed = false
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var transfers: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var deadline: Task<Void, Never>?
    private var readiness: CheckedContinuation<String, Error>?
    private var responseSecret = ""

    init(appID: String, runID: String, provider: AgentXProvider, binding: AgentXGatewayConfiguration.Binding, permission: AgentXExecutionPolicy,
         credential: @escaping () throws -> String?, now: @escaping () -> Date = { Date() },
         beforeSubmit: @escaping () throws -> Void = {}, onUsage: @escaping (Int, Int) throws -> Void = { _, _ in },
         onComplete: @escaping (Bool) throws -> Void = { _ in }, onClose: @escaping () throws -> Void = {}) throws {
        guard permission.appID == appID else { throw Failure.invalidRequest }
        self.permission = permission; self.runID = runID
        try AgentXPackageFiles.validateID(appID); try AgentXPackageFiles.validateID(runID)
        guard binding.providerID == provider.id, provider.serviceProtocol == .openAICompatible,
              let url = URLComponents(string: provider.baseURL),
              url.scheme == "https" || (url.scheme == "http" && ["127.0.0.1", "[::1]"].contains(url.host)),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, !provider.baseURL.contains("\\"),
              !provider.baseURL.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw Failure.invalidRequest }
        self.beforeSubmit = beforeSubmit; self.onUsage = onUsage; self.onComplete = onComplete; self.onClose = onClose
        self.provider = provider; self.binding = binding; self.credential = credential; self.now = now
        expires = now().addingTimeInterval(Double(binding.timeoutSeconds))
        path = "/v1/apps/\(appID)/runs/\(runID)/chat/completions"
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Double(binding.timeoutSeconds)
        configuration.timeoutIntervalForResource = Double(binding.timeoutSeconds)
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false; configuration.urlCredentialStorage = nil
        configuration.connectionProxyDictionary = [:]
        session = URLSession(configuration: configuration, delegate: AgentXGatewayNoRedirect(), delegateQueue: nil)
    }

    func start() async throws -> String {
        try Task.checkCancellation()
        guard !closed, now() < expires else { throw Failure.unavailable }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                readiness = continuation
                listener.stateUpdateHandler = { [self] state in
                    MainActor.assumeIsolated {
                        switch state {
                        case .ready:
                            if let port = listener.port, let continuation = readiness {
                                readiness = nil
                                continuation.resume(returning: "http://127.0.0.1:\(port.rawValue)" + String(path.dropLast("/chat/completions".count)))
                            }
                        case .failed, .cancelled: close()
                        default: break
                        }
                    }
                }
                listener.newConnectionHandler = { [self] connection in
                    MainActor.assumeIsolated {
                        guard !closed, connections.count < 4 else { connection.cancel(); return }
                        let id = ObjectIdentifier(connection)
                        connections[id] = connection
                        connection.stateUpdateHandler = { [weak self] state in
                            MainActor.assumeIsolated {
                                switch state {
                                case .cancelled, .failed:
                                    self?.transfers.removeValue(forKey: id)?.cancel()
                                    self?.connections.removeValue(forKey: id)
                                default: break
                                }
                            }
                        }
                        connection.start(queue: .main)
                        receive(connection, buffer: Data())
                    }
                }
                listener.start(queue: .main)
                let duration = max(0, expires.timeIntervalSince(now()))
                deadline = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(duration))
                    if !Task.isCancelled { self?.close() }
                }
            }
        } onCancel: { Task { @MainActor in self.close() } }
    }

    func close() {
        guard !closed else { return }
        closed = true; used = true; responseSecret = ""
        let continuation = readiness; readiness = nil
        continuation?.resume(throwing: Failure.unavailable)
        deadline?.cancel(); deadline = nil
        listener.stateUpdateHandler = nil; listener.newConnectionHandler = nil; listener.cancel()
        session.invalidateAndCancel()
        for task in transfers.values { task.cancel() }; transfers.removeAll()
        for connection in connections.values { connection.cancel() }; connections.removeAll()
        do { try onClose() } catch { rememberBudgetFailure(error) }
    }

    private func rememberBudgetFailure(_ error: Error) {
        budgetFailure = (error as? AgentXBudgetFailure)?.errorDescription ?? AgentXBudgetFailure.unavailable.errorDescription
    }

    /// Called without suspension: reservation and credential resolution cannot race another request.
    func upstreamRequest(path: String, token: String, body: Data) throws -> URLRequest {
        guard !closed, !used, now() < expires, path == self.path, token == self.token else { throw Failure.unauthorized }
        guard body.count <= binding.maxRequestBytes,
              let fields = try? StrictJSONPreflight.objectMembers(body),
              Set(fields.keys).isSubset(of: ["model", "messages", "stream", "stream_options", "max_tokens", "max_completion_tokens", "temperature", "top_p", "store"]),
              let input = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              input["model"] as? String == binding.model, fields["stream"] == Data("true".utf8),
              let messages = input["messages"] as? [[String: Any]], !messages.isEmpty, messages.count <= 512,
              messages.allSatisfy({ message in
                  Set(message.keys).isSubset(of: ["role", "content"]) && ["system", "developer", "user", "assistant"].contains(message["role"] as? String ?? "")
              }) else { throw Failure.invalidRequest }
        // Reconstruct the provider request; caller-selected headers, URL, tools and model never pass through.
        let normalized: [String: Any] = ["model": binding.model, "messages": messages, "stream": true,
            "stream_options": ["include_usage": true], "max_tokens": binding.maxOutputTokens]
        let encoded = try JSONSerialization.data(withJSONObject: normalized)
        guard encoded.count <= binding.maxRequestBytes else { throw Failure.invalidRequest }
        // Trusted denial is durable before credentials, budget or URLSession submission.
        try permission.requireNetwork(provider.baseURL, runID: runID)
        used = true
        let secret = try credential() ?? ""
        guard secret.utf8.count <= 8192, !secret.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              !provider.isOpenRouter || !secret.isEmpty else { throw Failure.unavailable }
        responseSecret = secret
        guard let url = URL(string: provider.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions") else { throw Failure.invalidRequest }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.httpBody = encoded
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if !secret.isEmpty { request.setValue("Bearer " + secret, forHTTPHeaderField: "Authorization") }
        // The reservation must be durably committed before URLSession can submit.
        do { try beforeSubmit() } catch { rememberBudgetFailure(error); throw error }
        return request
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [self] bytes, _, done, error in
            MainActor.assumeIsolated {
                guard !closed, error == nil, let bytes, !bytes.isEmpty else { connection.cancel(); return }
                let buffer = buffer + bytes
                do {
                    guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                        if buffer.count > 8192 || done { reject(connection, code: 400) }
                        else { receive(connection, buffer: buffer) }
                        return
                    }
                    guard separator.lowerBound <= 8192, let text = String(data: buffer[..<separator.lowerBound], encoding: .ascii) else { throw Failure.invalidRequest }
                    let lines = text.components(separatedBy: "\r\n")
                    let line = lines[0].split(separator: " ")
                    guard line.count == 3, line[0] == "POST", line[2] == "HTTP/1.1" else { throw Failure.invalidRequest }
                    var fields: [String: String] = [:]
                    for line in lines.dropFirst() {
                        let pair = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                        guard pair.count == 2, fields.updateValue(pair[1].trimmingCharacters(in: .whitespaces), forKey: pair[0].lowercased()) == nil else { throw Failure.invalidRequest }
                    }
                    guard fields["authorization"] == "Bearer " + token, String(line[1]) == path, !used else { throw Failure.unauthorized }
                    guard fields["transfer-encoding"] == nil, let raw = fields["content-length"],
                          raw.wholeMatch(of: /[0-9]{1,8}/) != nil, let length = Int(raw), length <= binding.maxRequestBytes else { throw Failure.invalidRequest }
                    let body = Data(buffer[separator.upperBound...])
                    if body.count < length {
                        if done { throw Failure.invalidRequest }; receive(connection, buffer: buffer); return
                    }
                    guard body.count == length else { throw Failure.invalidRequest }
                    let request = try upstreamRequest(path: String(line[1]), token: token, body: body)
                    let id = ObjectIdentifier(connection)
                    transfers[id] = Task { await forward(request, connection: connection) }
                    // A disconnected child must cancel the upstream even while no output is arriving.
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, _, _ in
                        Task { @MainActor in self?.transfers[id]?.cancel() }
                    }
                } catch Failure.unauthorized { reject(connection, code: 401) }
                catch { reject(connection, code: 400) }
            }
        }
    }

    private func reject(_ connection: NWConnection, code: Int) {
        let message = "HTTP/1.1 \(code) Error\r\nContent-Length: 2\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n{}"
        connection.send(content: Data(message.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
    private func send(_ data: Data, connection: NWConnection) async throws {
        try Task.checkCancellation()
        if data.isEmpty { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
    private func forward(_ request: URLRequest, connection: NWConnection) async {
        var started = false
        defer { connection.cancel(); responseSecret = "" }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  http.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("text/event-stream") == true else { throw Failure.unavailable }
            try await send(Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8), connection: connection)
            started = true
            var stream = AgentXGatewaySSE(secret: responseSecret)
            var observed: AgentXGatewaySSE.Usage?
            for try await byte in bytes {
                try Task.checkCancellation()
                let output = try stream.append(byte)
                do {
                    if let usage = stream.reportedUsage, usage != observed {
                        try onUsage(usage.input, usage.output)
                        observed = usage
                    }
                    if stream.finished { try onComplete(stream.reportedUsage != nil && stream.usageIsFinal) }
                } catch { rememberBudgetFailure(error); throw error }
                try await send(output, connection: connection)
                if stream.finished { break }
            }
            guard stream.finished else { throw Failure.unavailable }
        } catch {
            if !started { reject(connection, code: 502) }
            // An incomplete SSE stream cannot be mistaken for a successful model response.
        }
    }
}
