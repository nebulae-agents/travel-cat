import Foundation

extension AgentXPilot {
    /// Read a contiguous event range. The caller holds a fresh snapshot for cursor reset.
    func replay(id: String, after: Int, through: Int) async throws {
        struct Event: Decodable { let runId: String; let revision: Int; let eventId: String }
        struct Endpoint: Decodable { let port: Int; let token: String }
        try AgentXPackageFiles.validateID(id)
        let path = try AgentXPackageFiles.safeURL(".agentxd-endpoint.json", root: URL(fileURLWithPath: root))
        let endpoint = try JSONDecoder().decode(Endpoint.self, from: Data(contentsOf: path))
        guard after >= 0, through > after, (1...65535).contains(endpoint.port),
              let url = URL(string: "ws://127.0.0.1:\(endpoint.port)/v1/apps/\(appID)/runs/\(id)/events?after=\(after)") else {
            throw AgentXError.corrupt
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer " + endpoint.token, forHTTPHeaderField: "Authorization")
        let socket = Self.session.webSocketTask(with: request)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        try await withTaskCancellationHandler {
            for revision in (after + 1)...through {
                guard case let .string(text) = try await socket.receive() else { throw AgentXError.corrupt }
                let event = try JSONDecoder().decode(Event.self, from: Data(text.utf8))
                guard event.runId == id, event.revision == revision,
                      event.eventId == "\(id):\(revision)" else { throw AgentXError.corrupt }
                #if DEBUG
                if Bundle.main.bundleIdentifier == AgentXAcceptanceLaunch.bundleIdentifier {
                    let receipt: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
                        "after": after, "consumed": event.eventId, "revision": revision]
                    var bytes = try JSONSerialization.data(withJSONObject: receipt)
                    bytes.append(0x0A)
                    try FileHandle.standardError.write(contentsOf: bytes)
                }
                #endif
            }
        } onCancel: { socket.cancel(with: .goingAway, reason: nil) }
    }
}
