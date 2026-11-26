import AppKit
import Darwin
import Foundation
import TravelStorage
@preconcurrency import Network

final class AgentXWriterRootLease {
    private let fd: Int32
    init(root: URL) throws {
        let path = root.path
        guard let canonical = realpath(path, nil) else { throw AgentXError.unsafePath }
        defer { free(canonical) }
        guard String(cString: canonical) == path else { throw AgentXError.unsafePath }
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw AgentXError.unsafePath }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            close(descriptor)
            throw AgentXError.unsafePath
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let busy = errno == EWOULDBLOCK
            close(descriptor)
            if busy { throw AgentXError.invalid("数据目录正在使用，请先退出旧 agentxd 或另一份桌面客户端，再重新打开。") }
            throw AgentXError.unavailable
        }
        fd = descriptor
    }
    deinit { close(fd) }
}

@MainActor
final class AgentXDesktopRunWriter {
    private let lease: AgentXWriterRootLease
    private let root: URL
    private let registered: Set<String>
    private var applications: [String: AgentXDesktopAppRuns] = [:]
    private let reportFailure: () -> Void
    private let listener: NWListener
    private let token = UUID().uuidString + UUID().uuidString
    private var signalSource: DispatchSourceSignal?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var subscriptions: [ObjectIdentifier: AgentXDesktopEventSubscription] = [:]
    private var closing = false
    private var endpoint: URL { root.appendingPathComponent(".agentxd-endpoint.json") }

    init(root: URL, lease: AgentXWriterRootLease, apps: [AgentXPilot.Configuration.Application],
         runtime: any AgentXRunAdapter, credentials: any TravelServiceCredentialStoring,
         configuredApp: @escaping (String) -> AgentXApplication?,
         canCreate: @escaping (String, AgentXPilot.PiBinding) -> Bool, reportFailure: @escaping (String?) -> Void, gatewayState: @escaping () -> AgentXState? = { nil }, gatewayBudget: AgentXGatewayBudget? = nil) throws {
        self.root = root
        self.lease = lease
        self.reportFailure = { reportFailure(nil) }
        registered = Set(apps.map(\.appID))
        guard !apps.isEmpty, registered.count == apps.count else { throw AgentXError.corrupt }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let budget = gatewayBudget ?? AgentXGatewayBudget(root: root)
        for app in apps {
            do {
                applications[app.appID] = try AgentXDesktopAppRuns(root: root, application: app, runtime: runtime,
                    configuredApp: { configuredApp(app.appID) }, credentials: credentials, canCreate: canCreate, reportFailure: { reportFailure(app.appID) }, gatewayState: gatewayState, budget: budget)
            } catch {
                reportFailure(app.appID)
                if apps.count == 1 { throw error }
            }
        }
        guard !applications.isEmpty else { throw AgentXError.unavailable }
        for app in applications.values {
            app.didSave = { [weak self, weak app] id in
                guard let self else { return }
                for subscription in subscriptions.values where subscription.app === app && subscription.runID == id {
                    subscription.drain()
                }
            }
        }
    }

    func start() {
        let app = NSApplication.shared
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { app.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0) }
        signalSource = source
        source.resume()
        listener.stateUpdateHandler = { [self] state in
            MainActor.assumeIsolated {
                switch state {
                case .ready:
                    guard !closing, let port = listener.port else { return }
                    do {
                        let bytes = try JSONSerialization.data(withJSONObject: ["port": Int(port.rawValue), "token": token])
                        try AtomicFileWriter().write(bytes, to: endpoint)
                    } catch { failed() }
                case .failed: failed()
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [self] connection in
            MainActor.assumeIsolated {
                guard !closing, connections.count < 16 else { connection.cancel(); return }
                let id = ObjectIdentifier(connection)
                connections[id] = connection
                connection.stateUpdateHandler = { [weak self] state in
                    MainActor.assumeIsolated {
                        switch state {
                        case .failed, .cancelled:
                            self?.subscriptions.removeValue(forKey: id)?.stop()
                            self?.connections.removeValue(forKey: id)
                        default: break
                        }
                    }
                }
                connection.start(queue: .main)
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                    if self?.subscriptions[id] == nil { connection.cancel() }
                }
                receive(connection, buffered: Data())
            }
        }
        listener.start(queue: .main)
    }

    // One bounded HTTP request per connection, optionally upgraded to an event stream.
    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [self] data, _, done, error in
            MainActor.assumeIsolated {
                guard !closing, error == nil, let data, !data.isEmpty else { connection.cancel(); return }
                let bytes = buffered + data
                do {
                    if let (status, body) = try exchange(bytes, on: connection) {
                        let reason = HTTPURLResponse.localizedString(forStatusCode: status)
                        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
                    } else if subscriptions[ObjectIdentifier(connection)] != nil { return }
                    else if done { connection.cancel() }
                    else { receive(connection, buffered: bytes) }
                } catch {
                    connection.cancel()
                }
            }
        }
    }

    private func exchange(_ bytes: Data, on connection: NWConnection) throws -> (Int, Data)? {
        let empty = Data("{}".utf8)
        guard let separator = bytes.range(of: Data("\r\n\r\n".utf8)) else {
            return bytes.count > 8192 ? (400, empty) : nil
        }
        guard separator.lowerBound <= 8192, let header = String(data: bytes[..<separator.lowerBound], encoding: .ascii) else { return (400, empty) }
        let lines = header.components(separatedBy: "\r\n")
        let request = lines[0].split(separator: " ")
        guard request.count == 3, request[2] == "HTTP/1.1" else { return (400, empty) }
        var fields = [String: String]()
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, fields.updateValue(pair[1].trimmingCharacters(in: .whitespaces), forKey: pair[0].lowercased()) == nil else {
                return (400, empty)
            }
        }
        guard fields["authorization"] == "Bearer " + token else { return (401, empty) }
        let path = request[1].split(separator: "/", omittingEmptySubsequences: false)
        guard path.count >= 5, path[0].isEmpty, path[1] == "v1", path[2] == "apps",
              path[4] == "runs" || (path.count == 5 && path[4] == "runtime"),
              registered.contains(String(path[3])) else { return (404, empty) }
        guard let app = applications[String(path[3])] else { return (503, empty) }
        let rawLength = fields["content-length"] ?? "0"
        let limit = path.count == 5 && request[0] == "POST" ? 640_000 : 1024
        guard fields["transfer-encoding"] == nil, rawLength.wholeMatch(of: /[0-9]{1,8}/) != nil,
              let length = Int(rawLength), length <= limit else { return (400, empty) }
        let body = bytes[separator.upperBound...]
        guard body.count >= length else { return nil }
        guard body.count == length else { return (400, empty) }
        if path[4] == "runtime" {
            guard request[0] == "GET" else { return (405, empty) }
            guard body.isEmpty else { return (400, empty) }
            return try app.runtimeReport()
        }
        if path.count == 7, path[6] == "audit", request[0] == "GET" {
            return try app.readAudit(runID: String(path[5]))
        }
        do {
            if path.count == 7, request[0] == "GET", path[6].prefix(while: { $0 != "?" }) == "events" {
                guard let match = path[6].wholeMatch(of: /events\?after=([0-9]{1,19})/),
                      let cursor = UInt64(match.1) else {
                    return (400, Data(#"{"error":"invalid_cursor"}"#.utf8))
                }
                let id = String(path[5])
                let batch = app.events(id, after: cursor)
                guard fields["upgrade"]?.lowercased() == "websocket", case .available = batch else {
                    return try batch.response()
                }
                guard body.isEmpty, let handshake = AgentXDesktopEventSubscription.handshake(fields) else { return (400, empty) }
                // Leave capacity for HTTP mutations and clients recovering a snapshot.
                guard subscriptions.count < 8 else { return (503, empty) }
                let subscription = AgentXDesktopEventSubscription(connection: connection, app: app, runID: id, cursor: cursor)
                subscriptions[ObjectIdentifier(connection)] = subscription
                subscription.start(handshake)
                return nil
            }
            if path.count == 6 {
                let id = String(path[5])
                switch request[0] {
                case "GET": return try app.lookup(id)
                case "PATCH": return try app.setRead(id, body: Data(body))
                default: return (404, empty)
                }
            }
            if path.count == 7, path[6] == "stop", request[0] == "POST" {
                if !body.isEmpty {
                    do {
                        guard try StrictJSONPreflight.objectMembers(Data(body))?.isEmpty == true else { return (404, empty) }
                    } catch { return (400, empty) }
                }
                return try app.stop(String(path[5]), key: fields["idempotency-key"])
            }
            guard path.count == 5 else { return (404, empty) }
            switch request[0] {
            case "GET": return (200, try app.list())
            case "POST": return try app.create(key: fields["idempotency-key"], body: Data(body))
            default: return (405, empty)
            }
        } catch { return (500, empty) }
    }

    private func failed() {
        guard !closing else { return }
        reportFailure()
        Task { await shutdown() }
    }

    func shutdown() async {
        if !closing {
            closing = true
            listener.cancel()
            for connection in connections.values { connection.cancel() }
            try? FileManager.default.removeItem(at: endpoint)
            for app in applications.values { app.cancelForShutdown() }
        }
        for app in applications.values { await app.waitForExit() }
    }
}
