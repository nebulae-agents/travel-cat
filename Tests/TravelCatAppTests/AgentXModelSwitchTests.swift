import XCTest
@testable import TravelCatApp

private actor ModelRefreshGate {
    var requests = 0
    var response: CheckedContinuation<(Data, Int), Never>?
    func fetch() async -> (Data, Int) {
        requests += 1
        return await withCheckedContinuation { response = $0 }
    }
    func finish(_ status: Int = 200) {
        response?.resume(returning: (Data(#"{"data":[{"id":"a","context_length":9000},{"id":"b"},{"id":"new"}]}"#.utf8), status))
        response = nil
    }
}

@MainActor final class AgentXModelSwitchTests: XCTestCase {
    func fixture(catalog: AgentXProviderCatalog = .init(), respond: AgentXController.Responder? = nil) throws -> (AgentXController, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentXModelSwitch-\(UUID())")
        var state = AgentXState()
        state.providers = [.init(id: "router", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", models: ["a", "b"], modelSelection: .init(models: [.init(id: "a", enabled: true), .init(id: "b", enabled: true)], defaults: ["chat": "a"]))]
        state.definitions = [.init(id: "role", name: "Role", prompt: "Be brief")]
        state.instances = [.init(id: "one", name: "One", appID: "blackcat", definitionID: "role", providerID: "router", model: "a")]
        let repository = AgentXRepository(root: root)
        try repository.save(state)
        return (AgentXController(repository: repository, credentials: AgentXTestCredentials(), respond: respond, catalog: catalog, autoRefreshCatalogs: false), root)
    }
    func testRefreshUsesCacheAndManualRefreshMergesLatestPreferences() async throws {
        let gate = ModelRefreshGate()
        let (c, root) = try fixture(catalog: .init { _ in await gate.fetch() })
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let refresh = Task { await c.refreshOpenRouterCatalog(providerID: "router", now: now) }
        while await gate.requests == 0 { await Task.yield() }
        var choice = c.state.providers[0].modelSelection!
        try choice.setEnabled("b", enabled: false)
        try choice.setFavorite("a", favorite: true)
        try c.updateProvider(id: "router", name: "Renamed", address: "https://openrouter.ai/api/v1", models: "a,b", secret: "", modelSelection: choice)
        await gate.finish()
        await refresh.value
        let p = c.state.providers[0]
        XCTAssertEqual(p.name, "Renamed")
        XCTAssertEqual(p.catalogRefreshedAt, now)
        XCTAssertEqual(p.enabledModels, ["a"])
        XCTAssertEqual(p.modelSelection?.models.first?.contextLength, 9000)
        XCTAssertTrue(p.modelSelection?.models.first?.favorite == true)
        XCTAssertTrue(p.modelSelection?.models.last?.enabled == false)
        await c.refreshOpenRouterCatalog(providerID: "router", now: now.addingTimeInterval(60))
        let count = await gate.requests
        XCTAssertEqual(count, 1)
        let forced = Task { await c.refreshOpenRouterCatalog(providerID: "router", force: true, now: now.addingTimeInterval(120)) }
        while await gate.requests < 2 { await Task.yield() }
        await gate.finish(503)
        await forced.value
        XCTAssertEqual(c.state.providers[0], p)
        XCTAssertNotNil(c.catalogErrors["router"])
    }
    func testOldRefreshCannotOverwriteChangedEndpoint() async throws {
        let gate = ModelRefreshGate()
        let (c, root) = try fixture(catalog: .init { _ in await gate.fetch() })
        defer { try? FileManager.default.removeItem(at: root) }
        let refresh = Task { await c.refreshOpenRouterCatalog(providerID: "router", force: true) }
        while await gate.requests == 0 { await Task.yield() }
        try c.updateProvider(id: "router", name: "Local", address: "http://localhost:8000", models: "a,b", secret: "")
        await gate.finish()
        await refresh.value
        XCTAssertEqual(c.state.providers[0].models, ["a", "b"])
        XCTAssertNil(c.state.providers[0].catalogRefreshedAt)
    }
    func testSwitchPersistsHistoryAndRecordsActualModelAndCore() async throws {
        var requests: [(String, [AgentXMessage])] = []
        let (c, root) = try fixture { _, model, _, messages in requests.append((model, messages)); return "answer-\(model)" }
        defer { try? FileManager.default.removeItem(at: root) }
        c.send("first", instanceID: "one")
        await c.waitForRuns()
        try c.selectConversationModel(instanceID: "one", providerID: "router", model: "b")
        c.sendUsageRequest("help", instanceID: "one")
        await c.waitForRuns()
        c.send("second", instanceID: "one")
        await c.waitForRuns()
        XCTAssertEqual(requests.map { $0.0 }, ["a", "b", "b"])
        XCTAssertEqual(requests[2].1.map(\.content), ["Be brief", "first", "answer-a", "second"])
        XCTAssertFalse(requests[1].1.contains { $0.content == "first" })
        XCTAssertEqual(c.state.runs.last?.actualModel, "b")
        XCTAssertEqual(c.state.runs.last?.actualProviderID, "router")
        XCTAssertEqual(c.state.runs.last?.runtimeCore, "pi-agent-core")
        let restored = AgentXController(repository: c.repository, credentials: AgentXTestCredentials(), autoRefreshCatalogs: false)
        XCTAssertEqual(restored.effectiveInstance(restored.state.instances[0]).model, "b")
        XCTAssertEqual(restored.state.runs.count, 3)
        XCTAssertEqual(restored.state.instances[0].model, "a")
    }
    func testBusySwitchRejectedAndDisabledSelectionCannotSend() async throws {
        let (c, root) = try fixture { _, _, _, _ in try await Task.sleep(for: .seconds(20)); return "late" }
        defer { try? FileManager.default.removeItem(at: root) }
        c.send("first", instanceID: "one")
        XCTAssertThrowsError(try c.selectConversationModel(instanceID: "one", providerID: "router", model: "b"))
        c.cancel(c.state.runs[0].id)
        await c.waitForRuns()
        try c.selectConversationModel(instanceID: "one", providerID: "router", model: "b")
        var selection = c.state.providers[0].modelSelection!
        try selection.setEnabled("b", enabled: false)
        try c.updateProvider(id: "router", name: "OpenRouter", address: "https://openrouter.ai/api/v1", models: "a,b", secret: "", modelSelection: selection)
        c.send("must not send", instanceID: "one")
        XCTAssertEqual(c.state.runs.count, 1)
        XCTAssertEqual(c.state.runs[0].actualModel, "a")
        XCTAssertNotNil(c.errorMessage)
        XCTAssertThrowsError(try c.selectConversationModel(instanceID: "one", providerID: "router", model: "b"))
    }
    func testConversationChoiceOverridesPublishedChoiceWithoutEditingIt() throws {
        let (c, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var experience = AgentXAppExperience()
        experience.memberOverrides = [.init(instanceID: "one", providerID: "router", model: "b")]
        try c.saveExperienceDraft(appID: "blackcat", configuration: experience, expectedDraft: nil)
        try c.publishExperience(appID: "blackcat")
        XCTAssertEqual(c.effectiveInstance(c.state.instances[0]).model, "b")
        try c.selectConversationModel(instanceID: "one", providerID: "router", model: "a")
        XCTAssertEqual(c.effectiveInstance(c.state.instances[0]).model, "a")
        XCTAssertEqual(c.state.apps[0].experience?.published?.configuration.memberOverrides.first?.model, "b")
    }
    func testNewOpenRouterServiceCanBeSavedBeforeDiscoveringModels() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentXEmptyRouter-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let c = AgentXController(repository: .init(root: root), credentials: AgentXTestCredentials(), autoRefreshCatalogs: false)
        try c.addProvider(name: "OpenRouter", address: "https://openrouter.ai/api/v1", models: "", secret: "")
        XCTAssertEqual(c.state.providers.count, 1)
        XCTAssertTrue(try c.repository.load().providers[0].models.isEmpty)
        XCTAssertTrue(c.availableConversationModels.isEmpty)
    }
    func testStartupRefreshesExpiredEnabledRouterOnly() async throws {
        let gate = ModelRefreshGate()
        let (original, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = AgentXController(repository: original.repository, credentials: AgentXTestCredentials(), catalog: .init { _ in await gate.fetch() })
        while await gate.requests == 0 { await Task.yield() }
        await gate.finish()
        while c.refreshingCatalogs.contains("router") { await Task.yield() }
        XCTAssertNotNil(c.state.providers[0].catalogRefreshedAt)
        let restored = AgentXController(repository: c.repository, credentials: AgentXTestCredentials(), catalog: .init { _ in await gate.fetch() })
        await restored.refreshOpenRouterCatalog(providerID: "router")
        for _ in 0..<10 { await Task.yield() }
        let count = await gate.requests
        XCTAssertEqual(count, 1)
        XCTAssertTrue(restored.isLoaded)
    }

    func testSavingOldEditorKeepsNewDirectoryFactsAndAppliesOnlyChangedChoices() async throws {
        let (c, root) = try fixture(catalog: .init { _ in (Data(#"{"data":[{"id":"a","context_length":9000},{"id":"new"}]}"#.utf8), 200) })
        defer { try? FileManager.default.removeItem(at: root) }
        let baseline = c.state.providers[0]
        var editing = baseline.modelSelection!
        try editing.setFavorite("a", favorite: true)
        await c.refreshOpenRouterCatalog(providerID: "router", force: true)
        try c.updateProvider(id: "router", name: "OpenRouter", address: baseline.baseURL, models: "a,b", secret: "", modelSelection: editing, catalogBaseline: baseline)
        let saved = try c.repository.load().providers[0]
        XCTAssertTrue(saved.models.contains("new"))
        XCTAssertFalse(saved.modelSelection!.models.first { $0.id == "b" }!.available)
        XCTAssertEqual(saved.modelSelection!.models.first { $0.id == "a" }!.contextLength, 9000)
        XCTAssertTrue(saved.modelSelection!.models.first { $0.id == "a" }!.favorite)
    }
    func testMemberRenamePreservesConversationModelInMemoryAndOnDisk() throws {
        let (c, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try c.selectConversationModel(instanceID: "one", providerID: "router", model: "b")
        try c.updateInstance(id: "one", name: "Renamed", appID: "blackcat", definitionID: "role", providerID: "router", model: "a")
        XCTAssertEqual(c.effectiveInstance(c.state.instances[0]).model, "b")
        XCTAssertEqual(c.state.instances[0].conversationModel, try c.repository.load().instances[0].conversationModel)
        var removed = c.state
        removed.instances[0].conversationModel = nil
        try c.repository.save(removed)
        XCTAssertNil(try c.repository.load().instances[0].conversationModel)
    }
    func testWorkflowRecordsStepModelAndCoreWithoutConversationOverride() async throws {
        let (c, root) = try fixture { _, _, _, _ in "result" }
        defer { try? FileManager.default.removeItem(at: root) }
        try c.selectConversationModel(instanceID: "one", providerID: "router", model: "b")
        let draft = AgentXWorkflowDefinition(name: "Flow", steps: [.init(name: "First", instanceID: "one", instruction: "Work")])
        try c.saveWorkflowDraft(appID: "blackcat", definition: draft, expectedDraft: nil)
        try c.publishWorkflow(appID: "blackcat")
        c.startWorkflow("Input", appID: "blackcat")
        await c.waitForRuns()
        let step = try XCTUnwrap(c.repository.load().runs.last?.workflowSteps?.first)
        XCTAssertEqual(step.actualModel, "a")
        XCTAssertEqual(step.actualProviderID, "router")
        XCTAssertEqual(step.runtimeCore, "pi-agent-core")
    }

    func testNewModelPreferencesSurviveDiscoveryAndBackgroundRefreshInterleaving() async throws {
        let (c, root) = try fixture(catalog: .init { _ in (Data(#"{"data":[{"id":"a"},{"id":"b"},{"id":"new"}]}"#.utf8), 200) })
        defer { try? FileManager.default.removeItem(at: root) }
        let baseline = c.state.providers[0]
        var draft = baseline.modelSelection!
        draft.models.append(.init(id: "new", enabled: true, favorite: true))
        try draft.setDefault("new", category: .chat)
        await c.refreshOpenRouterCatalog(providerID: "router", force: true)
        try c.updateProvider(id: "router", name: baseline.name, address: baseline.baseURL, models: "a,b,new", secret: "", modelSelection: draft, catalogBaseline: baseline)
        let saved = c.state.providers[0].modelSelection!
        XCTAssertTrue(saved.models.first { $0.id == "new" }!.enabled)
        XCTAssertTrue(saved.models.first { $0.id == "new" }!.favorite)
        XCTAssertEqual(saved.defaultModel(for: .chat), "new")
    }

}
