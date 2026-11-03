import Foundation
import TravelCore
import TravelStorage

/// Both backends feed the same validated repository boundary in AutomaticTravelWorker.
@MainActor
final class ConfiguredTravelContentGenerator: TravelContentGenerating {
    private let configuration: () -> TravelGenerationConfiguration
    private let credentials: any TravelServiceCredentialStoring
    private let codex: any TravelContentGenerating
    private let client: OpenAICompatibleTravelClient
    private let providerResolver: AgentXProviderResolver?
    private let catalog: AgentXProviderCatalog

    init(configuration: @escaping () -> TravelGenerationConfiguration,
         credentials: any TravelServiceCredentialStoring, codex: any TravelContentGenerating,
         client: OpenAICompatibleTravelClient = OpenAICompatibleTravelClient(),
         providerResolver: AgentXProviderResolver? = nil, catalog: AgentXProviderCatalog = .init()) {
        self.configuration = configuration
        self.credentials = credentials
        self.codex = codex
        self.client = client
        self.providerResolver = providerResolver
        self.catalog = catalog
    }

    func narrative(for request: TravelEventRequest) async throws -> TravelNarrative {
        let config = configuration()
        guard config.onboardingCompleted else { throw GenerationSetupError.incomplete }
        let service = config.narrative
        if service.agentXProviderID == nil && service.kind == .codex { return try await codex.narrative(for: request) }
        try service.validate()
        let data = try JSONEncoder.travelCat.encode(request)
        let schema = try String(contentsOf: resource("narrative.schema.json"), encoding: .utf8)
        let prompt = TravelGenerationPrompts.narrative(embeddedRequest: true)
            + "\nOUTPUT SCHEMA:\n" + schema + "\nREQUEST JSON:\n" + String(decoding: data, as: UTF8.self)
        let output = try await generateText(service: service, prompt: prompt)
        try Task.checkCancellation()
        return try JSONDecoder.travelCat.decode(TravelNarrative.self, from: output)
    }

    func image(for work: PendingImageWork, in workspace: URL) async throws -> URL {
        let config = configuration()
        guard config.onboardingCompleted else { throw GenerationSetupError.incomplete }
        let service = config.image
        if service.agentXProviderID == nil && service.kind == .codex { return try await codex.image(for: work, in: workspace) }
        let event = try JSONEncoder.travelCat.encode(work.event)
        let data = try await generateImage(service: service, scene: String(decoding: event, as: UTF8.self), event: work.event)
        try Task.checkCancellation()
        let target = workspace.appendingPathComponent("postcard.png")
        try data.write(to: target, options: .atomic)
        return target
    }

    func generateText(service: TravelServiceConfiguration, prompt: String, apiKey: String? = nil,
                      useStoredCredential: Bool = true) async throws -> Data {
        try service.validate()
        if service.agentXProviderID != nil {
            guard let providerResolver else { throw AgentXProviderResolutionError.unavailable }
            let resolved = try providerResolver.resolve(service, category: .chat)
            let output = try await catalog.respond(baseURL: resolved.provider.baseURL,
                protocol: resolved.provider.serviceProtocol, model: resolved.model,
                secret: providerResolver.secret(for: resolved.provider), messages: [.init(role: "user", content: prompt)])
            return Data(output.utf8)
        }
        return try await client.text(baseURL: service.validatedBaseURL(), model: service.model,
            apiKey: useStoredCredential ? credentials.read(id: service.credentialID) : apiKey,
            prompt: prompt, jsonMode: service.jsonMode)
    }

    func generateImage(service: TravelServiceConfiguration, scene: String, apiKey: String? = nil,
                       useStoredCredential: Bool = true, event: TripEvent? = nil) async throws -> Data {
        try service.validate()
        var service = service
        let key: String?
        if service.agentXProviderID != nil {
            guard let providerResolver else { throw AgentXProviderResolutionError.unavailable }
            let resolved = try providerResolver.resolve(service, category: .image)
            service.baseURL = resolved.provider.baseURL
            service.model = resolved.model
            key = try providerResolver.secret(for: resolved.provider)
        } else {
            key = useStoredCredential ? try credentials.read(id: service.credentialID) : apiKey
        }
        let references = service.useImageEdits ? try ["front.png", "side.png", "sitting.png"].map(resource) : []
        let imagePrompt = event.map { TravelGenerationPrompts.image(for: $0) } ?? TravelGenerationPrompts.image
        return try await client.image(baseURL: service.validatedBaseURL(), model: service.model, apiKey: key,
                                      prompt: (service.useImageEdits ? imagePrompt : imagePrompt.replacingOccurrences(of: "Preserve the attached cat identity.", with: "Follow this cat description consistently.")) + "\nSCENE JSON:\n" + scene,
                                      referenceImages: references, useEdits: service.useImageEdits)
    }

    private func resource(_ name: String) throws -> URL {
        guard let root = CodexTravelContentGenerator.generationResourceRoot() else { throw CocoaError(.fileNoSuchFile) }
        return root.appendingPathComponent(name)
    }
}

enum GenerationSetupError: LocalizedError {
    case incomplete, newEndpointNeedsCredentialChoice, invalidProbe
    var errorDescription: String? {
        switch self {
        case .incomplete: "请先完成模型与连接配置。"
        case .newEndpointNeedsCredentialChoice: "服务地址已变更，请重新填写密钥，或选择无需密钥。"
        case .invalidProbe: "服务返回的内容未通过检查，请确认模型和接口设置。"
        }
    }
}
