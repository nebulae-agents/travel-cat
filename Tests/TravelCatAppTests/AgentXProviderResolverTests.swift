import Foundation
import XCTest
@testable import TravelCatApp

@MainActor private final class ResolverCredentials: TravelServiceCredentialStoring {
    var values = ["k1": "first", "k2": "second"]
    var reads: [String] = []
    var writes: [String] = []
    func read(id: String) throws -> String? { reads.append(id); return values[id] }
    func save(_ secret: String?, id: String) throws { writes.append(id); values[id] = secret }
}

@MainActor final class AgentXProviderResolverTests: XCTestCase {
    func testReferencePersistsWithoutCopyingSecretsOrResolvingLegacyEndpoint() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var state = AgentXState()
        state.providers = [.init(id: "unified", name: "Unified", baseURL: "https://example.com/v1", models: ["text"])]
        let keys = ResolverCredentials()
        let resolver = AgentXProviderResolver(state: { state }, credentials: keys)
        let store = TravelGenerationConfigurationStore(root: root)
        let controller = try GenerationServiceController(store: store, credentials: keys, hasExistingHistory: true, providerResolver: resolver)
        var candidate = controller.configuration
        candidate.narrative.agentXProviderID = "unified"
        candidate.narrative.model = "text"
        candidate.narrative.baseURL = "invalid stale endpoint"
        try controller.save(candidate, narrativeSecret: "must-not-copy", imageSecret: nil)
        XCTAssertEqual(try store.load(hasExistingHistory: true).narrative.agentXProviderID, "unified")
        XCTAssertEqual(keys.reads, [])
        XCTAssertEqual(keys.writes, [])
        let data = try String(contentsOf: store.configurationURL, encoding: .utf8)
        XCTAssertFalse(data.contains("must-not-copy"))
    }

    func testRuntimeUsesLiveProviderDefaultsAndRotatesProfileWithoutCopy() throws {
        var state = AgentXState()
        state.providers = [.init(id: "unified", name: "Unified", baseURL: "https://example.com/v1", models: ["first", "next"],
            credentialProfile: "shared", modelSelection: .init(models: [.init(id: "first", enabled: true), .init(id: "next", enabled: true)], defaults: ["chat": "first"]))]
        state.credentialProfiles = [.init(name: "shared", keyReferences: ["k1", "k2"])]
        let keys = ResolverCredentials()
        let resolver = AgentXProviderResolver(state: { state }, credentials: keys)
        var service = TravelServiceConfiguration()
        service.agentXProviderID = "unified"
        let first = try resolver.resolve(service, category: .chat)
        XCTAssertEqual(first.model, "first")
        XCTAssertEqual(try resolver.secret(for: first.provider), "first")
        state.providers[0].baseURL = "https://new.example/v1"
        state.providers[0].modelSelection?.defaults["chat"] = "next"
        let next = try resolver.resolve(service, category: .chat)
        XCTAssertEqual(next.model, "next")
        XCTAssertEqual(next.provider.baseURL, "https://new.example/v1")
        XCTAssertEqual(try resolver.secret(for: next.provider), "second")
        XCTAssertEqual(keys.writes, [])
    }

    func testDisabledMissingAndUnsupportedImageReferencesFailBeforeCredentials() throws {
        var state = AgentXState()
        state.providers = [.init(id: "unified", name: "Unified", baseURL: "https://example.com/v1", models: ["model"], serviceProtocol: .anthropicMessages)]
        let keys = ResolverCredentials()
        let resolver = AgentXProviderResolver(state: { state }, credentials: keys)
        var service = TravelServiceConfiguration(model: "model")
        service.agentXProviderID = "unified"
        XCTAssertThrowsError(try resolver.resolve(service, category: .image))
        state.providers[0].enabled = false
        XCTAssertThrowsError(try resolver.resolve(service, category: .chat))
        state.providers = []
        XCTAssertThrowsError(try resolver.resolve(service, category: .chat))
        XCTAssertEqual(keys.reads, [])
    }
}
