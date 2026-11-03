import Foundation
import Testing
@testable import TravelCatApp

@MainActor private final class IntegrationCredentials: TravelServiceCredentialStoring {
    var values = ["key-a": "fixture-a", "key-b": "fixture-b"]
    func read(id: String) throws -> String? { values[id] }
    func save(_ secret: String?, id: String) throws { values[id] = secret }
}
struct AgentXProviderIntegrationTests {
    @Test func chatRoutesSelectedProtocol() throws {
        let provider = AgentXProvider(id: "p", name: "P", baseURL: "https://example.com", models: ["m"], serviceProtocol: .anthropicMessages)
        let request = try AgentXChatClient.request(provider: provider, model: "m", secret: "fixture", messages: [.init(role: "user", content: "hello")])
        #expect(request.url?.path == "/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "fixture")
    }
    @Test func chatParsesResponsesThroughCatalog() async throws {
        let catalog = AgentXProviderCatalog { request in
            #expect(request.url?.path == "/v1/responses")
            return (Data(#"{"output":[{"type":"message","content":[{"type":"output_text","text":"fixture reply"}]}]}"#.utf8), 200)
        }
        let client = AgentXChatClient(catalog: catalog)
        let provider = AgentXProvider(id: "p", name: "P", baseURL: "https://example.com", models: ["m"], serviceProtocol: .responses)
        #expect(try await client.respond(provider: provider, model: "m", secret: nil, messages: [.init(role: "user", content: "hello")]) == "fixture reply")
    }
    @Test @MainActor func controllerRotatesProfileAndBlocksDisabledModel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = AgentXRepository(root: root)
        var state = AgentXState()
        state.providers = [.init(id: "p", name: "P", baseURL: "https://example.com", models: ["m"], credentialProfile: "work")]
        state.credentialProfiles = [.init(name: "work", keyReferences: ["key-a", "key-b"])]
        state.definitions = [.init(id: "d", name: "D", prompt: "hello")]
        state.instances = [.init(id: "i", name: "I", appID: "blackcat", definitionID: "d", providerID: "p", model: "m")]
        try repository.save(state)
        var received: [String] = []
        let controller = AgentXController(repository: repository, credentials: IntegrationCredentials(), respond: { _, _, secret, _ in received.append(secret ?? "missing"); return "ok" })
        controller.send("one", instanceID: "i")
        await controller.waitForRuns()
        controller.send("two", instanceID: "i")
        await controller.waitForRuns()
        #expect(received == ["fixture-a", "fixture-b"])
        try controller.updateProvider(id: "p", name: "P", address: "https://example.com", models: "m", secret: "", modelSelection: .init(models: [.init(id: "m", enabled: false)]))
        controller.send("three", instanceID: "i")
        await controller.waitForRuns()
        #expect(received.count == 2)
        #expect(controller.errorMessage != nil)
    }
    @Test @MainActor func createProfileSavesReferencesOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = IntegrationCredentials()
        let controller = AgentXController(repository: .init(root: root), credentials: store)
        try controller.addCredentialProfile(name: "team", secrets: ["new-a", "new-b"])
        let profile = try #require(controller.state.credentialProfiles?.first)
        #expect(profile.keyReferences.count == 2)
        #expect(profile.keyReferences.allSatisfy { store.values[$0] != nil })
        #expect(!String(decoding: try JSONEncoder().encode(profile), as: UTF8.self).contains("new-a"))
        #expect(throws: (any Error).self) { try controller.addCredentialProfile(name: "team", secrets: ["duplicate"]) }
    }
    @Test @MainActor func discoveryUsesInjectedTransport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = AgentXProviderCatalog { request in
            #expect(request.url?.path == "/v1/models")
            return (Data(#"{"data":[{"id":"remote-model"}]}"#.utf8), 200)
        }
        let controller = AgentXController(repository: .init(root: root), credentials: IntegrationCredentials(), catalog: catalog)
        let models = try await controller.discoverModels(address: "https://example.com", serviceProtocol: .responses, secret: "")
        #expect(models.map(\.id) == ["remote-model"])
        #expect(controller.state.providers.isEmpty)
    }
}
