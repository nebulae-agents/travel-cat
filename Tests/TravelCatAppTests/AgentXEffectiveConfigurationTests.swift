import XCTest
@testable import TravelCatApp

@MainActor final class AgentXEffectiveConfigurationTests: XCTestCase {
    func testSnapshotTracksOverrideAndClear() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let c = AgentXController(repository: AgentXRepository(root: root), credentials: AgentXTestCredentials(), autoRefreshCatalogs: false)
        try c.addProvider(name: "Local", address: "http://localhost:1234", models: "a,b", secret: "")
        try c.addDefinition(name: "Role", prompt: "Hello")
        try c.addInstance(name: "Member", appID: "blackcat", definitionID: c.state.definitions[0].id, providerID: c.state.providers[0].id, model: "a")
        let id = c.state.instances[0].id
        try c.selectConversationModel(instanceID: id, providerID: c.state.providers[0].id, model: "b")
        XCTAssertEqual(try c.effectiveConfiguration(instanceID: id).model, "b")
        XCTAssertEqual(try c.effectiveConfiguration(instanceID: id).modelSource, .session)
        XCTAssertEqual(try c.effectiveConfiguration(instanceID: id, workflow: true).model, "a")
        try c.clearConversationModel(instanceID: id)
        XCTAssertEqual(try c.effectiveConfiguration(instanceID: id).model, "a")
    }
    func testHistoricalRunDoesNotInventSnapshot() throws {
        let bytes = Data(#"{"id":"old","appID":"blackcat","instanceID":"one","prompt":"hello","status":"completed","isRead":false,"response":"ok","startedAt":0}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(AgentXRun.self, from: bytes).effectiveConfiguration)
    }
    func testRunSnapshotPersistsActualConfigurationAfterEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var requestedModel = ""
        let c = AgentXController(repository: .init(root: root), credentials: AgentXTestCredentials(), respond: { _, model, _, _ in requestedModel = model; return "ok" }, autoRefreshCatalogs: false)
        try c.addProvider(name: "Local", address: "http://localhost:1234", models: "a,b", secret: "")
        try c.addDefinition(name: "Role", prompt: "Hello")
        try c.addInstance(name: "Member", appID: "blackcat", definitionID: c.state.definitions[0].id, providerID: c.state.providers[0].id, model: "a")
        let id = c.state.instances[0].id
        try c.selectConversationModel(instanceID: id, providerID: c.state.providers[0].id, model: "b")
        c.send("hello", instanceID: id)
        await c.waitForRuns()
        XCTAssertEqual(requestedModel, "b")
        try c.clearConversationModel(instanceID: id)
        let run = try XCTUnwrap(c.repository.load().runs.last)
        XCTAssertEqual(run.status, .completed)
        XCTAssertEqual(run.effectiveConfiguration?.model, requestedModel)
        XCTAssertEqual(run.effectiveConfiguration?.definitionRevision, 1)
        XCTAssertEqual(run.effectiveConfiguration?.modelSource, .session)
    }
    func testPublicationImpactRejectsMissingApplicationAndPreservesPinnedMember() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var state = AgentXState()
        state.definitions = [.init(id: "role", name: "Role", prompt: "Published", revisions: [.init(number: 1, document: .init(source: "Published"), publishedAt: nil)], publishedRevision: 1)]
        state.providers = [.init(id: "p", name: "Local", baseURL: "http://localhost:1234", models: ["a"])]
        state.instances = [.init(id: "one", name: "Member", appID: "blackcat", definitionID: "role", providerID: "p", model: "a", definitionRevision: 1)]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = AgentXRepository(root: root)
        try repo.save(state)
        let c = AgentXController(repository: repo, credentials: AgentXTestCredentials(), autoRefreshCatalogs: false)
        XCTAssertEqual(try c.definitionPublicationImpact(id: "role").first?.fixedRevision, 1)
        state.instances[0].appID = "missing"
        XCTAssertThrowsError(try repo.save(state))
        XCTAssertEqual(try c.definitionPublicationImpact(id: "role").count, 1)
    }
    func testSharedDefinitionPublicationTracksBothApplicationsAndNewReferences() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let c = AgentXController(repository: .init(root: root), credentials: AgentXTestCredentials(), autoRefreshCatalogs: false)
        try c.addProvider(name: "Local", address: "http://localhost:1234", models: "a", secret: "")
        try c.addDefinition(name: "Shared", prompt: "Version one")
        let definitionID = c.state.definitions[0].id
        let providerID = c.state.providers[0].id
        try c.saveDefinitionDraft(id: definitionID, name: "Shared", document: .init(source: "Version two"))
        try c.addApp(name: "Second application")
        let second = try XCTUnwrap(c.state.apps.first(where: { $0.id != "blackcat" }))
        try c.addInstance(name: "Follower", appID: "blackcat", definitionID: definitionID, providerID: providerID, model: "a")
        try c.addInstance(name: "Pinned", appID: second.id, definitionID: definitionID, providerID: providerID, model: "a", definitionRevision: 1)
        let before = try c.definitionPublicationImpact(id: definitionID)
        XCTAssertEqual(Set(before.map(\.appName)), Set(["BlackCat", second.name]))
        XCTAssertEqual(before.filter { $0.fixedRevision == nil }.count, 1)
        XCTAssertEqual(before.filter { $0.fixedRevision == 1 }.count, 1)
        // A new reference after preview must be included by the commit-time calculation.
        try c.addInstance(name: "New follower", appID: second.id, definitionID: definitionID, providerID: providerID, model: "a")
        XCTAssertEqual(try c.definitionPublicationImpact(id: definitionID).count, 3)
        try c.publishDefinition(id: definitionID)
        for member in c.state.instances {
            let configuration = try c.effectiveConfiguration(instanceID: member.id)
            XCTAssertEqual(configuration.definitionRevision, member.name == "Pinned" ? 1 : 2)
        }
    }
}
