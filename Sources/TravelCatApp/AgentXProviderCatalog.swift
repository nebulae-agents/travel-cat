import Foundation

enum AgentXServiceProtocol: String, Codable, CaseIterable, Sendable {
    case openAICompatible = "openai-compatible"
    case responses = "responses"
    case anthropicMessages = "anthropic-messages"

    static func parse(_ value: String) throws -> Self {
        guard let result = Self(rawValue: value) else { throw AgentXCatalogError.unsupportedProtocol }
        return result
    }
    var title: String {
        switch self {
        case .openAICompatible: "OpenAI Compatible"
        case .responses: "OpenAI Responses"
        case .anthropicMessages: "Anthropic Messages"
        }
    }
    /// Describes implemented operations, never a claim about an individual server.
    var capabilities: [String] { ["models", "text-generation"] }
    fileprivate var endpoint: String {
        switch self {
        case .openAICompatible: "chat/completions"
        case .responses: "responses"
        case .anthropicMessages: "messages"
        }
    }
}

enum AgentXModelCategory: String, Codable, CaseIterable, Sendable {
    case chat, image, embedding, audio, rerank
}
struct AgentXCatalogModel: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var enabled = false
    var favorite = false
    var available = true
    var name: String? = nil
    var contextLength: Int? = nil
    var inputModalities: [String]? = nil
    var outputModalities: [String]? = nil
    var supportedParameters: [String]? = nil
    /// Provider prices remain exact decimal strings, denominated per token where applicable.
    var pricing: [String: String]? = nil
    /// Base rates do not describe the full bill when conditional tiers exist.
    var hasTieredPricing = false
    var supportsTextOutput: Bool { outputModalities?.contains("text") ?? true }

    private enum CodingKeys: String, CodingKey {
        case id, enabled, favorite, available, name, contextLength, inputModalities, outputModalities, supportedParameters, pricing, hasTieredPricing
    }
    init(id: String, enabled: Bool = false, favorite: Bool = false, available: Bool = true,
         name: String? = nil, contextLength: Int? = nil, inputModalities: [String]? = nil,
         outputModalities: [String]? = nil, supportedParameters: [String]? = nil, pricing: [String: String]? = nil, hasTieredPricing: Bool = false) {
        self.id = id; self.enabled = enabled; self.favorite = favorite; self.available = available
        self.name = name; self.contextLength = contextLength; self.inputModalities = inputModalities
        self.outputModalities = outputModalities; self.supportedParameters = supportedParameters; self.pricing = pricing
        self.hasTieredPricing = hasTieredPricing
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        available = try c.decodeIfPresent(Bool.self, forKey: .available) ?? true
        name = try c.decodeIfPresent(String.self, forKey: .name)
        contextLength = try c.decodeIfPresent(Int.self, forKey: .contextLength)
        inputModalities = try c.decodeIfPresent([String].self, forKey: .inputModalities)
        outputModalities = try c.decodeIfPresent([String].self, forKey: .outputModalities)
        supportedParameters = try c.decodeIfPresent([String].self, forKey: .supportedParameters)
        pricing = try c.decodeIfPresent([String: String].self, forKey: .pricing)
        hasTieredPricing = try c.decodeIfPresent(Bool.self, forKey: .hasTieredPricing) ?? false
    }
}
struct AgentXModelSelection: Codable, Equatable, Sendable {
    var models: [AgentXCatalogModel]
    var defaults: [String: String] = [:]
    mutating func setEnabled(_ id: String, enabled: Bool) throws {
        let index = try index(id)
        models[index].enabled = enabled
        if !enabled { defaults = defaults.filter { $0.value != id } }
    }
    mutating func setFavorite(_ id: String, favorite: Bool) throws {
        models[try index(id)].favorite = favorite
    }
    mutating func setDefault(_ id: String, category: AgentXModelCategory) throws {
        let model = models[try index(id)]
        guard model.enabled, model.available, category != .chat || model.supportsTextOutput else { throw AgentXCatalogError.invalidSelection }
        defaults[category.rawValue] = id
    }
    func defaultModel(for category: AgentXModelCategory) -> String? {
        guard let id = defaults[category.rawValue], models.contains(where: { $0.id == id && $0.enabled && $0.available && (category != .chat || $0.supportsTextOutput) }) else { return nil }
        return id
    }
    /// Refresh directory facts without changing user choices or deleting historical references.
    func mergingCatalog(_ refreshed: [AgentXCatalogModel]) throws -> Self {
        guard !refreshed.isEmpty,
              refreshed.allSatisfy({ !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              Set(refreshed.map(\.id)).count == refreshed.count,
              Set(models.map(\.id)).count == models.count else { throw AgentXCatalogError.invalidResponse }
        let incoming = Dictionary(uniqueKeysWithValues: refreshed.map { ($0.id, $0) })
        let previousIDs = Set(models.map(\.id))
        var merged = models.map { previous in
            guard var current = incoming[previous.id] else {
                var missing = previous
                missing.available = false
                return missing
            }
            current.enabled = previous.enabled
            current.favorite = previous.favorite
            current.available = true
            return current
        }
        merged += refreshed.filter { !previousIDs.contains($0.id) }.map { entry in
            var discovered = entry
            discovered.enabled = false
            discovered.favorite = false
            discovered.available = true
            return discovered
        }
        return .init(models: merged, defaults: defaults)
    }

    private func index(_ id: String) throws -> Int {
        guard models.filter({ $0.id == id }).count == 1, let index = models.firstIndex(where: { $0.id == id }) else { throw AgentXCatalogError.invalidSelection }
        return index
    }
}

enum AgentXCatalogError: LocalizedError {
    case unsupportedProtocol, invalidSelection, invalidResponse, tooLarge, http(Int), transport
    var errorDescription: String? {
        switch self {
        case .unsupportedProtocol: "尚不支持该服务协议。"
        case .invalidSelection: "模型不存在、重复或尚未启用。"
        case .invalidResponse: "服务返回的模型或文本格式无法识别。"
        case .tooLarge: "服务响应超出大小限制。"
        case let .http(status): "服务返回 HTTP \(status)。"
        case .transport: "无法连接模型服务，请检查地址和网络。"
        }
    }
}

private final class AgentXCatalogNoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

struct AgentXProviderCatalog: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)
    private let transport: Transport
    private static let sizeLimit = 2 * 1_024 * 1_024
    private static let catalogSizeLimit = 16 * 1_024 * 1_024

    static func isOpenRouter(baseURL: String) -> Bool {
        guard let parts = URLComponents(string: baseURL), parts.scheme?.lowercased() == "https",
              parts.host?.lowercased() == "openrouter.ai", parts.port == nil || parts.port == 443,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else { return false }
        return parts.percentEncodedPath == "/api/v1" || parts.percentEncodedPath == "/api/v1/"
    }

    init(transport: @escaping Transport) { self.transport = transport }
    init(session: URLSession? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForResource = 180
        let session = session ?? URLSession(configuration: config, delegate: AgentXCatalogNoRedirect(), delegateQueue: nil)
        transport = { request in
            let (bytes, response) = try await session.bytes(for: request, delegate: AgentXCatalogNoRedirect())
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse else { throw AgentXCatalogError.transport }
            guard (200..<300).contains(http.statusCode) else { throw AgentXCatalogError.http(http.statusCode) }
            let limit = request.httpMethod == "GET" ? Self.catalogSizeLimit : Self.sizeLimit
            guard response.expectedContentLength <= limit else { throw AgentXCatalogError.tooLarge }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < limit else { throw AgentXCatalogError.tooLarge }
                data.append(byte)
            }
            return (data, http.statusCode)
        }
    }

    static func modelsRequest(baseURL: String, protocol kind: AgentXServiceProtocol, secret: String?) throws -> URLRequest {
        var result = try request(baseURL: baseURL, kind: kind, secret: secret, models: true)
        if kind == .openAICompatible, isOpenRouter(baseURL: baseURL), let secret, !secret.isEmpty {
            result.url?.appendPathComponent("user")
        }
        return result
    }
    static func generationRequest(baseURL: String, protocol kind: AgentXServiceProtocol, model: String, secret: String?, messages: [AgentXMessage]) throws -> URLRequest {
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              messages.allSatisfy({ ["user", "assistant", "system", "developer"].contains($0.role) }) else { throw OpenAICompatibleTravelError.invalidRequest }
        var result = try request(baseURL: baseURL, kind: kind, secret: secret, models: false)
        result.httpMethod = "POST"
        var body: [String: Any] = ["model": model, "stream": false]
        let input = messages.map { ["role": $0.role, "content": $0.content] }
        switch kind {
        case .openAICompatible: body["messages"] = input
        case .responses: body["input"] = input
        case .anthropicMessages:
            body["messages"] = input.filter { $0["role"] == "user" || $0["role"] == "assistant" }
            let system = messages.filter { $0.role == "system" || $0.role == "developer" }.map(\.content).joined(separator: "\n\n")
            if !system.isEmpty { body["system"] = system }
            guard (body["messages"] as? [[String: String]])?.isEmpty == false else { throw OpenAICompatibleTravelError.invalidRequest }
            body["max_tokens"] = 1024
        }
        result.httpBody = try JSONSerialization.data(withJSONObject: body)
        return result
    }

    func fetchModels(baseURL: String, protocol kind: AgentXServiceProtocol, secret: String?) async throws -> [AgentXCatalogModel] {
        var request = try Self.modelsRequest(baseURL: baseURL, protocol: kind, secret: secret)
        var models: [AgentXCatalogModel] = []
        var seen: Set<String> = []
        var cursors: Set<String> = []
        for _ in 0..<100 {
            let data = try await perform(request, sizeLimit: Self.catalogSizeLimit)
            if kind == .openAICompatible, Self.isOpenRouter(baseURL: baseURL) {
                return try Self.openRouterModels(data)
            }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entries = object["data"] as? [[String: Any]] else { throw AgentXCatalogError.invalidResponse }
            for entry in entries {
                guard let id = entry["id"] as? String, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AgentXCatalogError.invalidResponse }
                if seen.insert(id).inserted { models.append(.init(id: id)) }
                guard models.count <= 10_000 else { throw AgentXCatalogError.tooLarge }
            }
            guard kind == .anthropicMessages, object["has_more"] as? Bool == true else { return models }
            guard let cursor = object["last_id"] as? String, !cursor.isEmpty, cursors.insert(cursor).inserted,
                  let url = request.url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw AgentXCatalogError.invalidResponse }
            components.queryItems = [URLQueryItem(name: "after_id", value: cursor)]
            request.url = components.url
        }
        throw AgentXCatalogError.tooLarge
    }

    func respond(baseURL: String, protocol kind: AgentXServiceProtocol, model: String, secret: String?, messages: [AgentXMessage]) async throws -> String {
        let request = try Self.generationRequest(baseURL: baseURL, protocol: kind, model: model, secret: secret, messages: messages)
        return try Self.responseText(await perform(request), protocol: kind)
    }

    static func responseText(_ data: Data, protocol kind: AgentXServiceProtocol) throws -> String {
        guard data.count <= sizeLimit else { throw AgentXCatalogError.tooLarge }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AgentXCatalogError.invalidResponse }
        let text: String
        switch kind {
        case .openAICompatible:
            guard let choices = object["choices"] as? [[String: Any]], let message = choices.first?["message"] as? [String: Any],
                  message["tool_calls"] == nil, message["function_call"] == nil,
                  let content = message["content"] as? String else { throw AgentXCatalogError.invalidResponse }
            text = content
        case .responses:
            guard let output = object["output"] as? [[String: Any]],
                  output.allSatisfy({ ["message", "reasoning"].contains($0["type"] as? String ?? "") }) else { throw AgentXCatalogError.invalidResponse }
            let content = output.filter { $0["type"] as? String == "message" }.compactMap { $0["content"] as? [[String: Any]] }.flatMap { $0 }
            guard content.allSatisfy({ $0["type"] as? String == "output_text" }) else { throw AgentXCatalogError.invalidResponse }
            text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        case .anthropicMessages:
            guard let content = object["content"] as? [[String: Any]], content.allSatisfy({ $0["type"] as? String == "text" }) else { throw AgentXCatalogError.invalidResponse }
            text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        guard !text.isEmpty else { throw AgentXCatalogError.invalidResponse }
        return text
    }

    private struct OpenRouterDirectory: Decodable {
        struct Entry: Decodable {
            struct Architecture: Decodable {
                let input_modalities: [String]?
                let output_modalities: [String]?
            }
            let id: String
            let name: String?
            let context_length: Int?
            let architecture: Architecture?
            let supported_parameters: [String]?
            struct Pricing: Decodable {
                private struct Key: CodingKey {
                    var stringValue: String
                    var intValue: Int? { nil }
                    init?(stringValue: String) { self.stringValue = stringValue }
                    init?(intValue: Int) { return nil }
                }
                private struct Tier: Decodable {
                    init(from decoder: Decoder) throws {
                        // Retain only the existence of tiers; never apply an unrecognized condition.
                        _ = try decoder.container(keyedBy: Key.self)
                    }
                }
                var rates: [String: String] = [:]
                var hasTiers = false
                init(from decoder: Decoder) throws {
                    let values = try decoder.container(keyedBy: Key.self)
                    for key in values.allKeys {
                        switch key.stringValue {
                        case "overrides": hasTiers = !(try values.decodeIfPresent([Tier].self, forKey: key) ?? []).isEmpty
                        case "discount": _ = try values.decodeIfPresent(Double.self, forKey: key)
                        default: rates[key.stringValue] = try values.decode(String.self, forKey: key)
                        }
                    }
                }
            }
            let pricing: Pricing?
        }
        struct Links: Decodable { let next: String? }
        let data: [Entry]
        let total_count: Int?
        let has_more: Bool?
        let links: Links?
    }

    private static func openRouterModels(_ data: Data) throws -> [AgentXCatalogModel] {
        guard let directory = try? JSONDecoder().decode(OpenRouterDirectory.self, from: data),
              !directory.data.isEmpty, directory.has_more != true, directory.links?.next == nil,
              directory.total_count == nil || directory.total_count == directory.data.count else { throw AgentXCatalogError.invalidResponse }
        guard directory.data.count <= 10_000 else { throw AgentXCatalogError.tooLarge }
        var ids = Set<String>()
        return try directory.data.map { entry in
            guard !entry.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  ids.insert(entry.id).inserted,
                  entry.context_length == nil || entry.context_length! >= 0 else { throw AgentXCatalogError.invalidResponse }
            return .init(id: entry.id, name: entry.name, contextLength: entry.context_length,
                         inputModalities: entry.architecture?.input_modalities, outputModalities: entry.architecture?.output_modalities,
                         supportedParameters: entry.supported_parameters, pricing: entry.pricing?.rates, hasTieredPricing: entry.pricing?.hasTiers ?? false)
        }
    }

    private func perform(_ request: URLRequest, sizeLimit: Int = Self.sizeLimit) async throws -> Data {
        do {
            let (data, status) = try await transport(request)
            try Task.checkCancellation()
            guard (200..<300).contains(status) else { throw AgentXCatalogError.http(status) }
            guard data.count <= sizeLimit else { throw AgentXCatalogError.tooLarge }
            return data
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            if let known = error as? AgentXCatalogError { throw known }
            throw AgentXCatalogError.transport
        }
    }

    private static func request(baseURL: String, kind: AgentXServiceProtocol, secret: String?, models: Bool) throws -> URLRequest {
        let exact = baseURL.hasSuffix("#")
        let address = exact ? String(baseURL.dropLast()) : baseURL
        guard let parts = URLComponents(string: address), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.scheme == "https" || (parts.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)),
              var endpoint = parts.url else { throw OpenAICompatibleTravelError.invalidAddress }
        guard secret?.contains(where: { $0.isNewline || $0 == "\0" }) != true else { throw OpenAICompatibleTravelError.invalidRequest }
        if exact && models {
            // An exact custom generation endpoint has no reliable discovery sibling.
            let suffix = "/" + kind.endpoint
            guard endpoint.path.hasSuffix(suffix) else { throw OpenAICompatibleTravelError.invalidAddress }
            for _ in kind.endpoint.split(separator: "/") { endpoint.deleteLastPathComponent() }
            endpoint.appendPathComponent("models")
        } else if !exact {
            if endpoint.path.isEmpty || endpoint.path == "/" { endpoint.appendPathComponent("v1") }
            endpoint.appendPathComponent(models ? "models" : kind.endpoint)
        }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if kind == .anthropicMessages {
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            if let secret, !secret.isEmpty { request.setValue(secret, forHTTPHeaderField: "x-api-key") }
        } else if let secret, !secret.isEmpty { request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization") }
        return request
    }
}
