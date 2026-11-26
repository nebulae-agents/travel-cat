import Foundation
import Darwin
import TravelStorage

/// Persistent ownership is independent of the short-lived endpoint and its token.
struct AgentXPilot: Sendable {
    struct PiBinding: Sendable {
        let instanceID: String
        let providerID: String
        let model: String
        var baseURL = ""
        var systemPrompt = ""
    }

    struct Configuration {
        struct Application {
            let appID: String
            let pi: PiBinding?
            var usesEventJournal = false
        }

        fileprivate(set) var root: String
        fileprivate let isVersioned: Bool
        let usesDesktopWriter: Bool
        let apps: [Application]
        var appIDs: Set<String> { Set(apps.map(\.appID)) }
        var clients: [AgentXPilot] { apps.map(client) }

        init(data: Data) throws {
            guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let root = manifest["root"] as? String, root.hasPrefix("/"), !root.contains("\0") else {
                throw AgentXError.corrupt
            }
            guard manifest["writer"] == nil || manifest["writer"] as? String == "desktop" else { throw AgentXError.corrupt }
            usesDesktopWriter = manifest["writer"] != nil
            self.root = root
            let versioned = manifest["version"] != nil || manifest["apps"] != nil
            isVersioned = versioned
            let entries: [[String: Any]]
            if versioned {
                guard Set(manifest.keys).subtracting(["writer"]) == ["root", "version", "apps"],
                      let version = manifest["version"] as? NSNumber, version.intValue == 2,
                      !["f", "d"].contains(String(cString: version.objCType)),
                      let applications = manifest["apps"] as? [[String: Any]], !applications.isEmpty else {
                    throw AgentXError.corrupt
                }
                entries = applications
            } else {
                entries = [manifest]
            }
            let parsed = try entries.map { try Self.parseApplication($0, strict: versioned) }
            guard Set(parsed.map(\.appID)).count == parsed.count else { throw AgentXError.corrupt }
            apps = parsed
        }

        private static func parseApplication(_ entry: [String: Any], strict: Bool) throws -> Application {
            guard !strict || Set(entry.keys).isSubset(of: ["appID", "pi", "runStore"]),
                  let appID = entry["appID"] as? String else { throw AgentXError.corrupt }
            try AgentXPackageFiles.validateID(appID)
            guard !["blackcat", "workbench"].contains(appID) else { throw AgentXError.unsafePath }
            guard entry["runStore"] == nil || entry["runStore"] as? String == "events-v1" else { throw AgentXError.corrupt }
            let useJournal = entry["runStore"] != nil
            guard let rawBinding = entry["pi"], strict || !(rawBinding is NSNull) else {
                return Application(appID: appID, pi: nil, usesEventJournal: useJournal)
            }
            guard let binding = rawBinding as? [String: Any],
                  let instanceID = binding["instanceID"] as? String,
                  let providerID = binding["providerID"] as? String,
                  let model = binding["model"] as? String else { throw AgentXError.corrupt }
            if strict {
                guard Set(binding.keys) == ["instanceID", "providerID", "model", "baseURL", "systemPrompt"],
                      binding["baseURL"] is String,
                      let prompt = binding["systemPrompt"] as? String, prompt.utf8.count <= 100_000,
                      instanceID.wholeMatch(of: /[A-Za-z0-9_-]{1,100}/) != nil,
                      providerID.wholeMatch(of: /[A-Za-z0-9_-]{1,100}/) != nil else {
                    throw AgentXError.corrupt
                }
            }
            return Application(appID: appID, pi: PiBinding(instanceID: instanceID, providerID: providerID, model: model,
                    baseURL: binding["baseURL"] as? String ?? "", systemPrompt: binding["systemPrompt"] as? String ?? ""),
                    usesEventJournal: useJournal)
        }

        func client(for appID: String) -> AgentXPilot? {
            apps.first(where: { $0.appID == appID }).map(client)
        }

        private func client(_ app: Application) -> AgentXPilot {
            AgentXPilot(appID: app.appID, root: root, pi: app.pi)
        }
    }

    let appID: String
    let root: String
    let pi: PiBinding?

    private static let markerLimit = 2 * 1024 * 1024

    private static func markerData(at directory: URL) throws -> Data? {
        let marker = try AgentXPackageFiles.safeURL(".agentxd-pilot.json", root: directory)
        let limit = markerLimit
        let descriptor = open(marker.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw AgentXError.unsafePath
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_size >= 0, info.st_size <= limit else {
            throw AgentXError.unsafePath
        }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let bytes = try file.read(upToCount: limit + 1), bytes.count == info.st_size else {
            throw AgentXError.corrupt
        }
        return bytes
    }

    static func readMarker(at directory: URL) throws -> Configuration? {
        try markerData(at: directory).map(Configuration.init(data:))
    }

    static func configured(at directory: URL) throws -> Configuration? {
        guard let configuration = try readMarker(at: directory) else { return nil }
        return try validate(configuration, at: directory)
    }

    private static func validate(_ parsed: Configuration, at directory: URL) throws -> Configuration {
        var configuration = parsed
        let matchesRoot: Bool
        if configuration.isVersioned {
            guard let physical = realpath(directory.path, nil) else { throw AgentXError.unsafePath }
            defer { free(physical) }
            matchesRoot = configuration.root == String(cString: physical)
        } else {
            let declared = URL(fileURLWithPath: configuration.root).resolvingSymlinksInPath().standardizedFileURL.path
            matchesRoot = declared == directory.resolvingSymlinksInPath().standardizedFileURL.path
        }
        guard matchesRoot else { throw AgentXError.invalid("试点归属与数据目录不匹配，请检查隔离副本。") }
        configuration.root = directory.path
        return configuration
    }

    /// Mark an old root only while holding the same lease used by the reference service.
    static func takeDesktopLease(at directory: URL) throws -> AgentXWriterRootLease {
        let lease = try AgentXWriterRootLease(root: directory)
        guard let bytes = try markerData(at: directory) else { throw AgentXError.corrupt }
        let configuration = try validate(Configuration(data: bytes), at: directory)
        if !configuration.usesDesktopWriter {
            guard var marker = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw AgentXError.corrupt }
            marker["writer"] = "desktop"
            let data = try JSONSerialization.data(withJSONObject: marker, options: [.sortedKeys, .withoutEscapingSlashes])
            guard data.count <= markerLimit else { throw AgentXError.invalid("旧配置加入桌面归属后超出 2 MiB，请精简配置后重试。") }
            let target = try AgentXPackageFiles.safeURL(".agentxd-pilot.json", root: directory)
            try AtomicFileWriter().write(data, to: target)
        }
        return lease
    }

    static func requireDesktopOwnership(_ appID: String, at root: URL) throws {
        if let configuration = try configured(at: root), configuration.appIDs.contains(appID) {
            throw AgentXError.invalid("试点应用的运行由桌面运行接口管理，暂不支持此操作。")
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
        guard let fields = try JSONSerialization.jsonObject(with: bytes) as? [[String: Any]] else { throw AgentXError.corrupt }
        let runs = try fields.map(AgentXRun.serviceProjection)
        guard runs.allSatisfy({ $0.appID == appID && ($0.revision ?? -1) >= 0 }),
              Set(runs.map(\.id)).count == runs.count else { throw AgentXError.corrupt }
        return runs
    }

    private func decodeRun(_ bytes: Data, id: String? = nil) throws -> AgentXRun {
        guard let fields = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw AgentXError.corrupt }
        let run = try AgentXRun.serviceProjection(fields)
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
