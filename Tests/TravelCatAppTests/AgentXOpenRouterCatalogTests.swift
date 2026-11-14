import Foundation
import Testing
import Yams
@testable import TravelCatApp

struct AgentXOpenRouterCatalogTests {
    private static let base = "https://openrouter.ai/api/v1"
    private static let fixture = #"{"data":[{"id":"vendor/text","name":"Text model","context_length":131072,"architecture":{"input_modalities":["text","image"],"output_modalities":["text"]},"supported_parameters":["tools","temperature"],"pricing":{"prompt":"0.000001","completion":"0.000003"}}]}"#

    @Test func refreshPreservesPreferencesAndMissingModelsThenRestoresAvailability() throws {
        let previous = AgentXModelSelection(models: [
            .init(id: "old", enabled: true, favorite: true, name: "Old name"),
            .init(id: "gone", enabled: true, favorite: true)
        ], defaults: ["chat": "gone"])
        let refreshed = try previous.mergingCatalog([
            .init(id: "old", name: "New name", contextLength: 4096, outputModalities: ["text"]),
            .init(id: "new", enabled: true, favorite: true)
        ])
        #expect(refreshed.models.map(\.id) == ["old", "gone", "new"])
        #expect(refreshed.models[0].name == "New name")
        #expect(refreshed.models[0].enabled && refreshed.models[0].favorite)
        #expect(!refreshed.models[1].available)
        #expect(refreshed.models[1].enabled && refreshed.models[1].favorite)
        #expect(!refreshed.models[2].enabled && !refreshed.models[2].favorite)
        #expect(refreshed.defaults == previous.defaults)
        #expect(refreshed.defaultModel(for: .chat) == nil)
        let restored = try refreshed.mergingCatalog([.init(id: "gone", outputModalities: ["text"])])
        #expect(restored.defaultModel(for: .chat) == "gone")
        #expect(restored.models[1].favorite)
    }

    @Test func invalidRefreshNeverProducesDestructiveMerge() throws {
        let selected = AgentXModelSelection(models: [.init(id: "a", enabled: true)])
        for entries: [AgentXCatalogModel] in [[], [.init(id: "a"), .init(id: "a")], [.init(id: " ")]] {
            #expect(throws: (any Error).self) { try selected.mergingCatalog(entries) }
        }
    }

    @Test func canonicalRecognitionRejectsLookalikesAndCustomEndpoints() {
        for address in [Self.base, Self.base + "/", "https://OPENROUTER.ai:443/api/v1"] {
            #expect(AgentXProvider(id: "p", name: "P", baseURL: address, models: []).isOpenRouter)
        }
        for address in ["https://openrouter.ai.evil.test/api/v1", "https://user@openrouter.ai/api/v1", Self.base + "#", Self.base + "?query=1", "http://openrouter.ai/api/v1", "https://openrouter.ai:444/api/v1", Self.base + "/chat/completions#", "https://openrouter.ai/api/%76%31"] {
            #expect(!AgentXProvider(id: "p", name: "P", baseURL: address, models: []).isOpenRouter)
        }
    }

    @Test func rejectsExplicitPaginationAndDuplicateOpenRouterEntries() async {
        for response in [#"{"data":[{"id":"a"}],"total_count":2}"#, #"{"data":[{"id":"a"}],"links":{"next":"https://openrouter.ai/api/v1/models?page=2"}}"#, #"{"data":[{"id":"a"},{"id":"a"}]}"#] {
            let catalog = AgentXProviderCatalog { _ in (Data(response.utf8), 200) }
            await #expect(throws: (any Error).self) { try await catalog.fetchModels(baseURL: Self.base, protocol: .openAICompatible, secret: nil) }
        }
    }

    @Test func nestedPricingTiersDoNotRejectDirectoryOrBecomeFlatPrices() async throws {
        let response = #"{"data":[{"id":"tiered","pricing":{"prompt":"0.000001","completion":"0.000002","custom_future_rate":"0.000003","discount":0.1,"overrides":[{"min_prompt_tokens":200000,"prompt":"0.000004"}]}}]}"#
        let catalog = AgentXProviderCatalog { _ in (Data(response.utf8), 200) }
        let models = try await catalog.fetchModels(baseURL: Self.base, protocol: .openAICompatible, secret: nil)
        #expect(models[0].pricing == ["prompt": "0.000001", "completion": "0.000002", "custom_future_rate": "0.000003"])
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(models[0])) as? [String: Any])
        #expect(json["hasTieredPricing"] as? Bool == true)
    }

    @Test func nonStringPricingExtensionsPreserveKnownRatesDuringLoadAndSave() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentXOpenRouter-Extensions-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = AgentXRepository(root: root)
        try repository.save(AgentXState())
        let path = root.appendingPathComponent("manager/providers/router.yaml")
        let original = """
        name: router
        display: Router
        base_url: https://openrouter.ai/api/v1
        models:
          - id: text
            enabled: true
            pricing:
              prompt: '0.000001'
              completion: '0.000002'
              custom_number: 7
              custom_object: {note: keep}
        """
        try Data(original.utf8).write(to: path)
        let state = try repository.load()
        #expect(state.providers[0].modelSelection?.models[0].pricing == ["prompt": "0.000001", "completion": "0.000002"])
        try repository.save(state)
        let saved = try #require(Yams.load(yaml: String(contentsOf: path, encoding: .utf8)) as? [String: Any])
        let models = try #require(saved["models"] as? [[String: Any]])
        let pricing = try #require(models[0]["pricing"] as? [String: Any])
        #expect(pricing["prompt"] as? String == "0.000001")
        #expect(pricing["completion"] as? String == "0.000002")
        #expect(pricing["custom_number"] as? Int == 7)
        #expect(pricing["custom_object"] as? [String: String] == ["note": "keep"])
        #expect(try repository.load() == state)
    }

    @Test func refreshedPricingRemovesStaleRatesButKeepsUserExtensions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentXOpenRouter-Prices-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = AgentXRepository(root: root)
        var state = AgentXState()
        state.providers = [.init(id: "router", name: "Router", baseURL: Self.base, models: ["text"],
            modelSelection: .init(models: [.init(id: "text", enabled: true,
                pricing: ["prompt": "0.000001", "completion": "0.000002", "input_cache_write_1h": "0.000003", "custom_price": "keep"])]) )]
        try repository.save(state)
        state.providers[0].modelSelection = try state.providers[0].modelSelection?.mergingCatalog([.init(id: "text", pricing: ["prompt": "0.000004"])])
        try repository.save(state)
        let prices = try repository.load().providers[0].modelSelection?.models[0].pricing
        #expect(prices?["prompt"] == "0.000004")
        #expect(prices?["completion"] == nil)
        #expect(prices?["input_cache_write_1h"] == nil)
        #expect(prices?["custom_price"] == "keep")
    }

    @Test func absentRefreshedPricingRemovesEveryKnownPriceButKeepsUserExtensions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentXOpenRouter-NoPrices-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = AgentXRepository(root: root)
        var state = AgentXState()
        state.providers = [.init(id: "router", name: "Router", baseURL: Self.base, models: ["text"],
            modelSelection: .init(models: [.init(id: "text", enabled: true,
                pricing: ["prompt": "0.1", "completion": "0.2", "request": "0.3", "image": "0.4", "web_search": "0.5", "internal_reasoning": "0.6", "input_cache_read": "0.7", "input_cache_write": "0.8", "input_cache_write_1h": "0.9", "audio": "1.0", "audio_output": "1.1", "image_output": "1.2", "image_token": "1.3", "input_audio_cache": "1.4", "custom_price": "keep"])]) )]
        try repository.save(state)
        state.providers[0].modelSelection = try state.providers[0].modelSelection?.mergingCatalog([.init(id: "text")])
        try repository.save(state)
        #expect(try repository.load().providers[0].modelSelection?.models[0].pricing == ["custom_price": "keep"])
    }

    @Test func authenticatedCatalogUsesUserFilteredEndpoint() throws {
        let request = try AgentXProviderCatalog.modelsRequest(baseURL: Self.base, protocol: .openAICompatible, secret: "fixture-only")
        #expect(request.url?.absoluteString == Self.base + "/models/user")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-only")
        let publicRequest = try AgentXProviderCatalog.modelsRequest(baseURL: Self.base, protocol: .openAICompatible, secret: nil)
        #expect(publicRequest.url?.absoluteString == Self.base + "/models")
    }

    @Test func catalogMetadataSurvivesCodable() async throws {
        let catalog = AgentXProviderCatalog { _ in (Data(Self.fixture.utf8), 200) }
        let models = try await catalog.fetchModels(baseURL: Self.base, protocol: .openAICompatible, secret: nil)
        #expect(models.count == 1)
        #expect(models.first?.enabled == false)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(models[0])) as? [String: Any])
        #expect(json["name"] as? String == "Text model")
        #expect(json["contextLength"] as? Int == 131072)
        #expect(json["inputModalities"] as? [String] == ["text", "image"])
        #expect(json["outputModalities"] as? [String] == ["text"])
        #expect(json["supportedParameters"] as? [String] == ["tools", "temperature"])
        #expect((json["pricing"] as? [String: String])?["prompt"] == "0.000001")
        #expect(json["available"] as? Bool == true)
    }

    @Test func rejectsEmptyMalformedAndIncompleteCatalogs() async {
        for response in [#"{"data":[]}"#, #"{"data":[{"id":"a"}],"has_more":true}"#, #"{"data":[{"id":"a","architecture":{"output_modalities":"text"}}]}"#, #"{"data":[{"id":"a","context_length":"many"}]}"#, #"{"data":[{"id":"a"},{"name":"missing id"}]}"#, #"{"data":[{"id":"a"}]"#] {
            let catalog = AgentXProviderCatalog { _ in (Data(response.utf8), 200) }
            await #expect(throws: (any Error).self) { try await catalog.fetchModels(baseURL: Self.base, protocol: .openAICompatible, secret: nil) }
        }
    }

    @Test func realDirectorySizedResponsesAreAcceptedButBounded() async throws {
        let large = Data(("{\"padding\":\"" + String(repeating: "x", count: 3 * 1_024 * 1_024) + "\",\"data\":[{\"id\":\"a\"}]}").utf8)
        let catalog = AgentXProviderCatalog { _ in (large, 200) }
        #expect(try await catalog.fetchModels(baseURL: Self.base, protocol: .openAICompatible, secret: nil).map(\.id) == ["a"])
        let excessive = Data(repeating: 32, count: 16 * 1_024 * 1_024 + 1)
        let oversized = AgentXProviderCatalog { _ in (excessive, 200) }
        await #expect(throws: (any Error).self) { try await oversized.fetchModels(baseURL: Self.base, protocol: .openAICompatible, secret: nil) }
    }

    @Test func unavailableAndNonTextModelsRemainStoredButCannotResolve() throws {
        let models = try JSONDecoder().decode([AgentXCatalogModel].self, from: Data(#"[{"id":"gone","enabled":true,"favorite":true,"available":false},{"id":"image","enabled":true,"favorite":false,"outputModalities":["image"]},{"id":"text","enabled":true,"favorite":false}]"#.utf8))
        var selection = AgentXModelSelection(models: models, defaults: ["chat": "gone"])
        let provider = AgentXProvider(id: "router", name: "OpenRouter", baseURL: Self.base, models: models.map(\.id), modelSelection: selection)
        #expect(provider.enabledModels == ["text"])
        #expect(selection.defaultModel(for: .chat) == nil)
        #expect(throws: (any Error).self) { try selection.setDefault("gone", category: .chat) }
        #expect(throws: (any Error).self) { try selection.setDefault("image", category: .chat) }
        #expect(selection.defaults["chat"] == "gone")
    }

    @Test func legacyMinimalModelDecodesAsAvailableTextCompatible() throws {
        let model = try JSONDecoder().decode(AgentXCatalogModel.self, from: Data(#"{"id":"legacy"}"#.utf8))
        #expect(model.id == "legacy")
        #expect(model.enabled == false)
    }

    @Test func freshCatalogMetadataAndRefreshTimestampRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentXOpenRouter-Fresh-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = AgentXRepository(root: root)
        var state = AgentXState()
        state.providers = [.init(id: "router", name: "Router", baseURL: Self.base, models: ["text"],
            modelSelection: .init(models: [.init(id: "text", enabled: true, favorite: true, available: false,
                name: "Text", contextLength: 4096, inputModalities: ["text", "image"], outputModalities: ["text"],
                supportedParameters: ["tools"], pricing: ["prompt": "0.0000001", "completion": "0.0000002"], hasTieredPricing: true)], defaults: ["chat": "text"]),
            catalogRefreshedAt: Date(timeIntervalSince1970: 1_789_000_000.123456))]
        state.definitions = [.init(id: "writer", name: "Writer", prompt: "Write.")]
        state.instances = [.init(id: "writer", name: "Writer", appID: "blackcat", definitionID: "writer", providerID: "router", model: "text")]
        try repository.save(state)
        let restored = try repository.load()
        #expect(restored.providers[0].modelSelection == state.providers[0].modelSelection)
        #expect(restored.providers[0].catalogRefreshedAt?.timeIntervalSince1970 == state.providers[0].catalogRefreshedAt?.timeIntervalSince1970)
        #expect(restored.definitions == state.definitions)
        #expect(restored.instances == state.instances)
        #expect(restored == state)
        #expect(restored.providers[0].enabledModels.isEmpty)
    }

    @Test func authenticatedFailureDoesNotRetryPublicDirectory() async {
        let calls = OpenRouterRequestRecorder()
        let catalog = AgentXProviderCatalog { request in
            await calls.record(request.url?.path ?? "")
            return (Data(), 403)
        }
        await #expect(throws: (any Error).self) { try await catalog.fetchModels(baseURL: Self.base, protocol: .openAICompatible, secret: "fixture-only") }
        #expect(await calls.paths == ["/api/v1/models/user"])
    }

    @Test func yamlMetadataRoundTripPreservesUnknownFieldsAndUnavailableInstances() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentXOpenRouter-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = AgentXRepository(root: root)
        try repository.save(AgentXState())
        let path = root.appendingPathComponent("manager/providers/router.yaml")
        let original = """
        name: router
        display: OpenRouter
        base_url: https://openrouter.ai/api/v1
        catalog_refreshed_at: '2026-11-05T01:02:03Z'
        custom_provider: keep
        defaults: {chat: vendor/text}
        models:
          - id: vendor/text
            enabled: true
            favorite: true
            available: false
            name: Text model
            context_length: 131072
            input_modalities: [text, image]
            output_modalities: [text]
            supported_parameters: [tools]
            pricing: {prompt: '0.000001', completion: '0.000003', custom_price: keep}
            custom_model: keep
        """
        try Data(original.utf8).write(to: path)
        let state = try repository.load()
        #expect(state.providers.first?.enabledModels == [])
        try repository.save(state)
        let saved = try #require(Yams.load(yaml: String(contentsOf: path, encoding: .utf8)) as? [String: Any])
        #expect(saved["catalog_refreshed_at"] as? String == "2026-11-05T01:02:03Z")
        #expect(saved["custom_provider"] as? String == "keep")
        let model = try #require((saved["models"] as? [[String: Any]])?.first)
        #expect(model["custom_model"] as? String == "keep")
        #expect((model["pricing"] as? [String: String])?["custom_price"] == "keep")
        #expect(try repository.load() == state)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(state.providers[0])) as? [String: Any])
        #expect(json["catalogRefreshedAt"] != nil)
    }
}

private actor OpenRouterRequestRecorder {
    var paths: [String] = []
    func record(_ path: String) { paths.append(path) }
}
