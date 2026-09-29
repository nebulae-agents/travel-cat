import Darwin
import Foundation
import TravelStorage

enum TravelServiceKind: String, Codable, CaseIterable, Sendable {
    case codex, openAICompatible
}

enum TravelServiceConfigurationError: LocalizedError {
    case invalidURL, missingModel, invalidCredentialID, unsupportedVersion

    var errorDescription: String? {
        switch self {
        case .invalidURL: "服务地址无效：请使用 HTTPS，或本机回环地址的 HTTP；地址不能含凭据、查询参数或片段。"
        case .missingModel: "请填写模型名称。"
        case .invalidCredentialID: "服务凭据标识无效。"
        case .unsupportedVersion: "服务配置版本不受支持。"
        }
    }
}

struct TravelServiceConfiguration: Codable, Equatable, Sendable {
    var kind: TravelServiceKind
    var baseURL: String
    var model: String
    var credentialID: String
    var jsonMode: Bool
    var useImageEdits: Bool

    init(kind: TravelServiceKind = .codex, baseURL: String = "https://api.openai.com/v1",
         model: String = "", credentialID: String = UUID().uuidString,
         jsonMode: Bool = true, useImageEdits: Bool = true) {
        self.kind = kind
        self.baseURL = baseURL
        self.model = model
        self.credentialID = credentialID
        self.jsonMode = jsonMode
        self.useImageEdits = useImageEdits
    }

    func validatedBaseURL() throws -> URL {
        guard baseURL == baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
              let parts = URLComponents(string: baseURL),
              let scheme = parts.scheme?.lowercased(),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              let url = parts.url,
              (parts.port == nil || (1...65535).contains(parts.port!)),
              scheme == "https" || (scheme == "http" && Self.isLoopback(host)) else {
            throw TravelServiceConfigurationError.invalidURL
        }
        return url
    }

    private static func isLoopback(_ host: String) -> Bool {
        if host == "localhost" || host == "[::1]" || host == "::1" { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets[0] == "127" && octets.allSatisfy {
            guard !$0.isEmpty, $0.allSatisfy({ $0.isASCII && $0.isNumber }),
                  $0.count == 1 || $0.first != "0", let value = UInt16($0) else { return false }
            return value <= 255
        }
    }

    func validate() throws {
        guard UUID(uuidString: credentialID) != nil else {
            throw TravelServiceConfigurationError.invalidCredentialID
        }
        guard kind == .openAICompatible else { return }
        _ = try validatedBaseURL()
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TravelServiceConfigurationError.missingModel
        }
    }
}

struct TravelGenerationConfiguration: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var onboardingCompleted = false
    var narrative = TravelServiceConfiguration()
    var image = TravelServiceConfiguration()
}

struct TravelGenerationConfigurationStore {
    let root: URL
    private let writeConfiguration: (Data, URL) throws -> Void

    init(root: URL, writeConfiguration: @escaping (Data, URL) throws -> Void = { data, url in
        // AtomicFileWriter creates its temporary file with 0600 before rename.
        try AtomicFileWriter().write(data, to: url)
    }) {
        self.root = root
        self.writeConfiguration = writeConfiguration
    }

    var configurationURL: URL { root.appendingPathComponent("state/generation-services.json") }

    func load(hasExistingHistory: Bool) throws -> TravelGenerationConfiguration {
        guard FileManager.default.fileExists(atPath: configurationURL.path) else {
            var configuration = TravelGenerationConfiguration()
            configuration.onboardingCompleted = hasExistingHistory
            return configuration
        }
        let configuration = try JSONDecoder().decode(TravelGenerationConfiguration.self,
                                                     from: Data(contentsOf: configurationURL))
        try validate(configuration)
        return configuration
    }

    func save(_ configuration: TravelGenerationConfiguration) throws {
        try validate(configuration)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writeConfiguration(encoder.encode(configuration), configurationURL)
    }

    private func validate(_ configuration: TravelGenerationConfiguration) throws {
        guard configuration.schemaVersion == 1 else { throw TravelServiceConfigurationError.unsupportedVersion }
        for service in [configuration.narrative, configuration.image] {
            guard UUID(uuidString: service.credentialID) != nil else {
                throw TravelServiceConfigurationError.invalidCredentialID
            }
            if configuration.onboardingCompleted { try service.validate() }
        }
    }
}
