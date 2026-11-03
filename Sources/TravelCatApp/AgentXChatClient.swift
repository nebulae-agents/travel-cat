import Foundation

struct AgentXMessage: Codable, Sendable { var role: String; var content: String }

/// One protocol-aware transport shared by foreground conversations and discovery.
struct AgentXChatClient: Sendable {
    private let catalog: AgentXProviderCatalog
    init(session: URLSession? = nil) { catalog = AgentXProviderCatalog(session: session) }
    init(catalog: AgentXProviderCatalog) { self.catalog = catalog }

    static func request(provider: AgentXProvider, model: String, secret: String?, messages: [AgentXMessage]) throws -> URLRequest {
        try AgentXProviderCatalog.generationRequest(baseURL: provider.baseURL, protocol: provider.serviceProtocol,
            model: model, secret: secret, messages: messages)
    }

    func respond(provider: AgentXProvider, model: String, secret: String?, messages: [AgentXMessage]) async throws -> String {
        try await catalog.respond(baseURL: provider.baseURL, protocol: provider.serviceProtocol,
            model: model, secret: secret, messages: messages)
    }
}
