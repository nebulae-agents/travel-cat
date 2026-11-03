import Foundation

enum AgentXProviderResolutionError: LocalizedError {
    case unavailable, missingModel, unsupportedImage
    var errorDescription: String? {
        switch self {
        case .unavailable: "统一模型服务不存在、已停用或尚未连接，请在 AgentX 模型服务中检查。"
        case .missingModel: "请选择该服务已启用的模型，或先设置对应类别的默认模型。"
        case .unsupportedImage: "该服务协议尚未接入明信片图片生成，请选择支持 OpenAI 图片接口的统一服务。"
        }
    }
}

/// Holds only a live state source and a credential-store boundary. Consumers persist
/// provider IDs, never copied provider secrets or a second catalog snapshot.
@MainActor
final class AgentXProviderResolver {
    struct Resolution {
        let provider: AgentXProvider
        let model: String
    }
    private let state: () throws -> AgentXState
    private let credentials: any TravelServiceCredentialStoring
    private var profileResolver: AgentXCredentialProfiles?
    private var profileSnapshot: [AgentXCredentialProfile] = []

    init(state: @escaping () throws -> AgentXState, credentials: any TravelServiceCredentialStoring) {
        self.state = state
        self.credentials = credentials
    }

    func providers(category: AgentXModelCategory) throws -> [AgentXProvider] {
        try state().providers.filter { $0.enabled && (category != .image || $0.serviceProtocol == .openAICompatible) }
    }

    /// Validate before any keychain read or network operation. Empty model follows
    /// the category default; explicit models must still be enabled at execution.
    func resolve(_ service: TravelServiceConfiguration, category: AgentXModelCategory) throws -> Resolution {
        guard let id = service.agentXProviderID else { throw AgentXProviderResolutionError.unavailable }
        let matches = try state().providers.filter { $0.id == id }
        guard matches.count == 1, let provider = matches.first, provider.enabled else { throw AgentXProviderResolutionError.unavailable }
        if category == .image && provider.serviceProtocol != .openAICompatible { throw AgentXProviderResolutionError.unsupportedImage }
        _ = try AgentXProviderCatalog.modelsRequest(baseURL: provider.baseURL, protocol: provider.serviceProtocol, secret: nil)
        let model = service.model.isEmpty ? provider.modelSelection?.defaultModel(for: category) : service.model
        guard let model, provider.enabledModels.contains(model) else { throw AgentXProviderResolutionError.missingModel }
        return Resolution(provider: provider, model: model)
    }

    func secret(for provider: AgentXProvider) throws -> String? {
        guard let profile = provider.credentialProfile else { return try credentials.read(id: provider.credentialID) }
        let profiles = try state().credentialProfiles ?? []
        if profileResolver == nil || profiles != profileSnapshot {
            profileResolver = AgentXCredentialProfiles(profiles: profiles, store: credentials)
            profileSnapshot = profiles
        }
        guard let profileResolver else { throw AgentXCredentialProfileError.invalidProfile }
        return try profileResolver.nextSecret(profile: profile)
    }
}
