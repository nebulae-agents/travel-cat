import XCTest
@testable import TravelCatApp

final class AgentXModelBrowserTests: XCTestCase {
    private func provider(_ id: String = "router", enabled: Bool = true) -> AgentXProvider {
        .init(id: id, name: id, baseURL: "https://example.com/v1", models: ["deepseek/deepseek-v4.1-flash", "google/gemini-flash", "gone"], enabled: enabled,
              modelSelection: .init(models: [.init(id: "deepseek/deepseek-v4.1-flash", enabled: true, favorite: true, name: "DeepSeek V4.1 Flash"), .init(id: "google/gemini-flash", enabled: true), .init(id: "gone", favorite: true, available: false)]))
    }
    func testSearchUnderstandsAliasesPunctuationAndUnorderedWords() {
        for query in ["ds v4.1 flash", "FLASH deep seek v4 1", "DeepSeekV4.1Flash", "dpsk flsh"] {
            XCTAssertEqual(AgentXModelBrowserQuery.results(providers: [provider()], query: query).first?.model.id, "deepseek/deepseek-v4.1-flash", query)
        }
        XCTAssertTrue(AgentXModelBrowserQuery.results(providers: [provider()], query: "unrelatedxyz").isEmpty)
    }
    func testServiceIdentityFavoritesAndUnavailableReasons() {
        let entries = AgentXModelBrowserQuery.results(providers: [provider(), provider("other", enabled: false)])
        XCTAssertEqual(Set(entries.map(\.id)).count, 6)
        let favorites = AgentXModelBrowserQuery.favorites(providers: [provider()])
        XCTAssertEqual(favorites.count, 2)
        XCTAssertNil(favorites.first { $0.model.available }?.disabledReason())
        XCTAssertNotNil(favorites.first { !$0.model.available }?.disabledReason())
        XCTAssertTrue(AgentXModelBrowserQuery.results(providers: [provider("off", enabled: false)]).allSatisfy { $0.disabledReason() != nil })
        XCTAssertEqual(AgentXModelBrowserQuery.groups(entries).count, 2)
    }
    func testGroupsSortByServiceNameThenVendorAndRetainProviderIdentity() {
        var first = provider("uuid-z")
        first.name = "Alpha"
        var second = provider("uuid-a")
        second.name = "Zulu"
        let groups = AgentXModelBrowserQuery.groups(AgentXModelBrowserQuery.results(providers: [second, first]))
        XCTAssertEqual(groups.map(\.name), ["Alpha", "Zulu"])
        XCTAssertEqual(groups[0].vendors.map(\.id), ["deepseek", "google", "其他模型"])
        XCTAssertTrue(groups[0].vendors.flatMap(\.entries).allSatisfy { $0.providerID == "uuid-z" })
    }
    func testBatchAndDatedVariantsRemainExplicit() {
        let p = AgentXProvider(id: "p", name: "P", baseURL: "https://example.com", models: ["deepseek/flash", "deepseek/flash:batch", "vendor/model-2026-11-05"])
        let results = AgentXModelBrowserQuery.results(providers: [p])
        XCTAssertNil(results.first { $0.model.id == "deepseek/flash" }?.variantLabel)
        XCTAssertEqual(results.first { $0.model.id.contains(":batch") }?.variantLabel, "批处理版")
        XCTAssertEqual(results.first { $0.model.id.contains("2026") }?.variantLabel, "日期版本")
    }
    func testUnorderedLiteralTermsOutrankCompetingLooseSubsequence() {
        let p = AgentXProvider(id: "p", name: "P", baseURL: "https://example.com", models: ["a/flex-alpha-shared-deepseek", "z/deepseek-flash"])
        let results = AgentXModelBrowserQuery.results(providers: [p], query: "flash deepseek")
        XCTAssertEqual(results.map(\.model.id), ["z/deepseek-flash", "a/flex-alpha-shared-deepseek"])
    }
    func testSlashOnlyManualIDsUseFallbackVendorWithoutCrashing() {
        let p = AgentXProvider(id: "p", name: "P", baseURL: "https://example.com", models: ["/", "///"])
        let entries = AgentXModelBrowserQuery.results(providers: [p])
        XCTAssertEqual(entries.map(\.vendor), ["其他模型", "其他模型"])
        let groups = AgentXModelBrowserQuery.groups(entries)
        XCTAssertEqual(groups.first?.vendors.first?.id, "其他模型")
        XCTAssertEqual(groups.first?.vendors.first?.entries.count, 2)
    }
    func testExactSearchOutranksSubsequenceAndIsDeterministic() {
        let p = AgentXProvider(id: "p", name: "P", baseURL: "https://example.com", models: ["flash-extra", "f-l-a-s-h", "flash"])
        let results = AgentXModelBrowserQuery.results(providers: [p], query: "flash")
        XCTAssertEqual(results.first?.model.id, "flash")
        XCTAssertEqual(results.map(\.id), AgentXModelBrowserQuery.results(providers: [p], query: "flash").map(\.id))
    }
    func testDefaultEnablesValidModelAndRejectsMissingOrNonTextWithoutMutation() throws {
        var selection = AgentXModelSelection(models: [.init(id: "text"), .init(id: "image", outputModalities: ["image"]), .init(id: "gone", available: false)])
        try selection.enableAndSetDefault("text", category: .chat)
        XCTAssertEqual(selection.defaultModel(for: .chat), "text")
        let valid = selection
        XCTAssertThrowsError(try selection.enableAndSetDefault("image", category: .chat))
        XCTAssertThrowsError(try selection.enableAndSetDefault("gone", category: .chat))
        XCTAssertEqual(selection, valid)
    }
}

@MainActor final class AgentXModelPreferenceTests: XCTestCase {
    func testOldGenericProviderDraftPreservesNewFavoritesAndNewDiscovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = AgentXRepository(root: root)
        var state = AgentXState()
        state.providers = [.init(id: "p", name: "P", baseURL: "https://example.com/v1", models: ["a", "b"], modelSelection: .init(models: [.init(id: "a", enabled: true), .init(id: "b")]))]
        try repository.save(state)
        let c = AgentXController(repository: repository, credentials: AgentXTestCredentials(), autoRefreshCatalogs: false)
        let baseline = c.state.providers[0]
        var draft = baseline.modelSelection!
        draft.models.append(.init(id: "discovered", favorite: true))
        try draft.enableAndSetDefault("b", category: .chat)
        try c.setModelFavorite(providerID: "p", modelID: "a", favorite: true)
        try c.updateProvider(id: "p", name: "Renamed", address: baseline.baseURL, models: "a,b,discovered", secret: "", modelSelection: draft, catalogBaseline: baseline)
        let saved = try repository.load().providers[0].modelSelection!
        XCTAssertTrue(saved.models.first { $0.id == "a" }!.favorite)
        XCTAssertEqual(saved.defaultModel(for: .chat), "b")
        XCTAssertTrue(saved.models.contains { $0.id == "discovered" && $0.favorite })
    }
    func testNarrowPreferencesPreserveLatestFactsAndPersistMultipleFavorites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = AgentXRepository(root: root)
        var state = AgentXState()
        state.providers = [.init(id: "p", name: "P", baseURL: "https://example.com/v1", models: ["a", "b"], modelSelection: .init(models: [.init(id: "a", contextLength: 9000), .init(id: "b", contextLength: 12000)]))]
        try repository.save(state)
        let c = AgentXController(repository: repository, credentials: AgentXTestCredentials(), autoRefreshCatalogs: false)
        try c.setModelFavorite(providerID: "p", modelID: "a", favorite: true)
        try c.setModelFavorite(providerID: "p", modelID: "b", favorite: true)
        try c.setModelDefault(providerID: "p", modelID: "a", category: .chat)
        let saved = try repository.load().providers[0].modelSelection!
        XCTAssertEqual(saved.models.filter(\.favorite).count, 2)
        XCTAssertEqual(saved.models.map(\.contextLength), [9000, 12000])
        XCTAssertEqual(saved.defaultModel(for: .chat), "a")
        XCTAssertFalse(saved.models[1].enabled)
        XCTAssertThrowsError(try c.setModelFavorite(providerID: "p", modelID: "missing", favorite: true))
    }
}
