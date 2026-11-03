import Foundation
import Testing
@testable import TravelCatApp

struct AgentXProviderCatalogTests {
    @Test func protocolRequests() throws {
        for (kind, suffix) in [(AgentXServiceProtocol.openAICompatible, "chat/completions"), (.responses, "responses"), (.anthropicMessages, "messages")] {
            let request = try AgentXProviderCatalog.generationRequest(baseURL: "https://example.com", protocol: kind, model: "m", secret: "fixture", messages: [.init(role: "user", content: "hello")])
            #expect(request.url?.path == "/v1/\(suffix)")
            #expect(request.httpMethod == "POST")
            if kind == .anthropicMessages { #expect(request.value(forHTTPHeaderField: "x-api-key") == "fixture") }
            else { #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture") }
        }
        #expect(throws: (any Error).self) { try AgentXServiceProtocol.parse("unknown") }
        #expect(throws: (any Error).self) { try AgentXProviderCatalog.modelsRequest(baseURL: "http://example.com", protocol: .responses, secret: nil) }
    }
    @Test func protocolBodiesAndExactEndpoints() throws {
        let messages: [AgentXMessage] = [.init(role: "system", content: "rules"), .init(role: "user", content: "question")]
        let request = try AgentXProviderCatalog.generationRequest(baseURL: "https://example.com/custom/messages#", protocol: .anthropicMessages, model: "m", secret: nil, messages: messages)
        #expect(request.url?.path == "/custom/messages")
        let bodyData = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(body["system"] as? String == "rules")
        #expect(body["max_tokens"] as? Int == 1024)
        #expect((body["messages"] as? [[String: Any]])?.count == 1)
        let models = try AgentXProviderCatalog.modelsRequest(baseURL: "https://example.com/v1/chat/completions#", protocol: .openAICompatible, secret: nil)
        #expect(models.url?.path == "/v1/models")
        let responseRequest = try AgentXProviderCatalog.generationRequest(baseURL: "https://example.com", protocol: .responses, model: "m", secret: nil, messages: messages)
        let responseData = try #require(responseRequest.httpBody)
        let responseBody = try #require(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        #expect(responseBody["input"] != nil)
        #expect(responseBody["messages"] == nil)
    }
    @Test func selectionRoundTrip() throws {
        var selection = AgentXModelSelection(models: [.init(id: "model")])
        try selection.setEnabled("model", enabled: true)
        try selection.setDefault("model", category: .image)
        let restored = try JSONDecoder().decode(AgentXModelSelection.self, from: JSONEncoder().encode(selection))
        #expect(restored == selection)
    }
    @Test func catalogFetchAndSelection() async throws {
        let catalog = AgentXProviderCatalog { request in
            #expect(request.url?.path == "/v1/models")
            return (Data(#"{"data":[{"id":"a"},{"id":"b"},{"id":"a"}]}"#.utf8), 200)
        }
        let models = try await catalog.fetchModels(baseURL: "https://example.com/v1", protocol: .openAICompatible, secret: nil)
        #expect(models.map(\.id) == ["a", "b"])
        var settings = AgentXModelSelection(models: models)
        try settings.setEnabled("a", enabled: true)
        try settings.setFavorite("a", favorite: true)
        try settings.setDefault("a", category: .chat)
        #expect(settings.defaultModel(for: .chat) == "a")
        try settings.setEnabled("a", enabled: false)
        #expect(settings.defaultModel(for: .chat) == nil)
        #expect(throws: (any Error).self) { try settings.setDefault("missing", category: .chat) }
    }
    @Test func rejectsSecretsInHeadersAndUnsupportedOutput() throws {
        #expect(throws: (any Error).self) { try AgentXProviderCatalog.modelsRequest(baseURL: "https://example.com", protocol: .responses, secret: "bad\nheader") }
        #expect(throws: (any Error).self) { try AgentXProviderCatalog.responseText(Data(#"{"content":[{"type":"tool_use","id":"x"}]}"#.utf8), protocol: .anthropicMessages) }
        #expect(throws: (any Error).self) { try AgentXProviderCatalog.responseText(Data(#"{"choices":[{"message":{"content":"ok","tool_calls":[]}}]}"#.utf8), protocol: .openAICompatible) }
    }
    @Test func responseParsingAndHTTPFailures() async throws {
        #expect(try AgentXProviderCatalog.responseText(Data(#"{"output":[{"type":"message","content":[{"type":"output_text","text":"ok"}]}]}"#.utf8), protocol: .responses) == "ok")
        #expect(try AgentXProviderCatalog.responseText(Data(#"{"content":[{"type":"text","text":"ok"}]}"#.utf8), protocol: .anthropicMessages) == "ok")
        let catalog = AgentXProviderCatalog { _ in (Data(), 401) }
        await #expect(throws: (any Error).self) { try await catalog.fetchModels(baseURL: "https://example.com", protocol: .responses, secret: nil) }
    }
}

@MainActor private final class CatalogFixtureCredentials: TravelServiceCredentialStoring {
    var values = ["first": "fixture-a", "second": "fixture-b"]
    func read(id: String) throws -> String? { values[id] }
    func save(_ secret: String?, id: String) throws { values[id] = secret }
}
struct AgentXCredentialProfilesTests {
    @Test @MainActor func invalidProfilesAndMissingKeysFailClosed() throws {
        let store = CatalogFixtureCredentials()
        let profiles = AgentXCredentialProfiles(profiles: [.init(name: "missing-key", keyReferences: ["absent"])], store: store)
        #expect(throws: (any Error).self) { try profiles.nextSecret(profile: "missing-key") }
        let duplicates = AgentXCredentialProfiles(profiles: [.init(name: "same", keyReferences: ["first"]), .init(name: "same", keyReferences: ["second"])], store: store)
        #expect(throws: (any Error).self) { try duplicates.nextSecret(profile: "same") }
    }
    @Test @MainActor func concurrentConsumersRotateWithoutLosingTurns() async throws {
        let profiles = AgentXCredentialProfiles(profiles: [.init(name: "work", keyReferences: ["first", "second"])], store: CatalogFixtureCredentials())
        let values = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<20 { group.addTask { try await profiles.nextSecret(profile: "work") } }
            var values: [String] = []
            for try await value in group { values.append(value) }
            return values
        }
        #expect(values.filter { $0 == "fixture-a" }.count == 10)
        #expect(values.filter { $0 == "fixture-b" }.count == 10)
    }
    @Test @MainActor func saveUsesOnlyDeclaredReferences() throws {
        let store = CatalogFixtureCredentials()
        let profiles = AgentXCredentialProfiles(profiles: [.init(name: "work", keyReferences: ["first"])], store: store)
        try profiles.saveSecret("updated", profile: "work", keyReference: "first")
        #expect(store.values["first"] == "updated")
        #expect(throws: (any Error).self) { try profiles.saveSecret("bad", profile: "work", keyReference: "other") }
        #expect(store.values["other"] == nil)
    }
    @Test @MainActor func profilesContainOnlyReferencesAndRotate() throws {
        let profile = AgentXCredentialProfile(name: "work", keyReferences: ["first", "second"])
        let profiles = AgentXCredentialProfiles(profiles: [profile], store: CatalogFixtureCredentials())
        #expect(try profiles.nextSecret(profile: "work") == "fixture-a")
        #expect(try profiles.nextSecret(profile: "work") == "fixture-b")
        #expect(try profiles.nextSecret(profile: "work") == "fixture-a")
        let encoded = String(decoding: try JSONEncoder().encode(profile), as: UTF8.self)
        #expect(!encoded.contains("fixture-a"))
        #expect(throws: (any Error).self) { try profiles.nextSecret(profile: "absent") }
    }
}
