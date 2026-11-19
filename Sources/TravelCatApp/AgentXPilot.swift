import Foundation

/// Persistent ownership is independent of the short-lived endpoint and its token.
struct AgentXPilot: Decodable {
    struct PiBinding: Decodable {
        let instanceID: String
        let providerID: String
        let model: String
    }

    let appID: String
    let root: String
    let pi: PiBinding?

    static func configured(at directory: URL) throws -> Self? {
        let marker = try AgentXPackageFiles.safeURL(".agentxd-pilot.json", root: directory)
        let bytes: Data
        do { bytes = try Data(contentsOf: marker) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        let pilot = try JSONDecoder().decode(Self.self, from: bytes)
        try AgentXPackageFiles.validateID(pilot.appID)
        let declared = URL(fileURLWithPath: pilot.root).resolvingSymlinksInPath().standardizedFileURL
        guard !["blackcat", "workbench"].contains(pilot.appID), pilot.root.hasPrefix("/"),
              declared.path == directory.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw AgentXError.invalid("试点归属与数据目录不匹配，请检查隔离副本。")
        }
        return Self(appID: pilot.appID, root: directory.path, pi: pilot.pi)
    }

    static func requireDesktopOwnership(_ app: String, at root: URL) throws {
        if try configured(at: root)?.appID == app {
            throw AgentXError.invalid("试点应用的运行由 agentxd 管理，暂不支持此操作。")
        }
    }

    private struct Endpoint: Decodable { let port: Int; let token: String }
    private struct CreateRun: Encodable { let instanceId: String; let prompt: String }
    private struct ReadFlag: Encodable { let expectedRevision: Int; let isRead: Bool }

    private final class LoopbackOnly: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
    static let session = makeSession(request: 3, resource: 5)
    // A stop can queue behind one bounded audit call and then append its own event.
    static let commandSession = makeSession(request: 30, resource: 30)
    private static func makeSession(request: TimeInterval, resource: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = request
        config.timeoutIntervalForResource = resource
        return URLSession(configuration: config, delegate: LoopbackOnly(), delegateQueue: nil)
    }

    private func request(_ method: String = "GET", id: String? = nil, stop: Bool = false,
                         key: String? = nil, body: Data? = nil) async throws -> (Data, Int) {
        let path = try AgentXPackageFiles.safeURL(".agentxd-endpoint.json", root: URL(fileURLWithPath: root))
        let endpoint = try JSONDecoder().decode(Endpoint.self, from: Data(contentsOf: path))
        guard (1...65535).contains(endpoint.port), !endpoint.token.isEmpty else { throw AgentXError.corrupt }
        var url = URL(string: "http://127.0.0.1:\(endpoint.port)")!.appendingPathComponent("v1/apps/\(appID)/runs")
        if let id {
            guard !id.isEmpty, id.utf8.count <= 100,
                  id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { throw AgentXError.unsafePath }
            url.appendPathComponent(id)
        }
        if stop { url.appendPathComponent("stop") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let key { request.setValue(key, forHTTPHeaderField: "Idempotency-Key") }
        request.setValue("Bearer " + endpoint.token, forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let session = method == "POST" ? Self.commandSession : Self.session
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AgentXError.corrupt }
        switch http.statusCode {
        case 200...299: break
        case 409 where method == "PATCH": break  // Body contains the latest run for a read-flag conflict.
        case 409: throw AgentXError.invalid("提交发生冲突，请查看该成员已有的运行和停止状态。")
        case 422: throw AgentXError.invalid("请求与本机 Pi 服务的实例绑定不一致，请核对成员和模型。")
        case 503: throw AgentXError.invalid("本机 Pi 服务暂不可用。请检查服务，恢复后可重试。")
        default: throw AgentXError.invalid("试点服务未能处理请求，请刷新后重试。")
        }
        return (data, http.statusCode)
    }

    func runs() async throws -> [AgentXRun] {
        let (bytes, _) = try await request()
        let runs = try JSONDecoder().decode([AgentXRun].self, from: bytes)
        guard runs.allSatisfy({ $0.appID == appID && ($0.revision ?? -1) >= 0 }),
              Set(runs.map(\.id)).count == runs.count else { throw AgentXError.corrupt }
        return runs
    }

    private func decodeRun(_ bytes: Data, id: String? = nil) throws -> AgentXRun {
        let run = try JSONDecoder().decode(AgentXRun.self, from: bytes)
        guard run.appID == appID, (id == nil || run.id == id), (run.revision ?? -1) >= 0 else { throw AgentXError.corrupt }
        return run
    }

    func create(prompt: String, instanceID: String, key: String) async throws -> AgentXRun {
        let body = try JSONEncoder().encode(CreateRun(instanceId: instanceID, prompt: prompt))
        let (bytes, _) = try await request("POST", key: key, body: body)
        let run = try decodeRun(bytes)
        guard run.instanceID == instanceID, run.prompt == prompt else { throw AgentXError.corrupt }
        return run
    }

    func stop(id: String) async throws -> AgentXRun {
        let (bytes, _) = try await request("POST", id: id, stop: true, key: id, body: Data("{}".utf8))
        return try decodeRun(bytes, id: id)
    }

    func setRead(_ value: Bool, id: String, expected: Int) async throws -> (run: AgentXRun, conflict: Bool) {
        let body = try JSONEncoder().encode(ReadFlag(expectedRevision: expected, isRead: value))
        let (bytes, status) = try await request("PATCH", id: id, body: body)
        return (try decodeRun(bytes, id: id), status == 409)
    }
}
