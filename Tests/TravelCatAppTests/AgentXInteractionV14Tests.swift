import XCTest
@testable import TravelCatApp

@MainActor final class AgentXInteractionV14Tests: XCTestCase {
    func configured(_ respond: @escaping AgentXController.Responder) throws -> (AgentXController, URL, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentXV14-\(UUID())")
        let c = AgentXController(repository: .init(root: root), credentials: AgentXTestCredentials(), respond: respond)
        try c.addProvider(name: "Local", address: "http://localhost:1234", models: "m,m2", secret: "")
        try c.addDefinition(name: "Role", prompt: "Published role")
        try c.addInstance(name: "Member", appID: "blackcat", definitionID: c.state.definitions[0].id, providerID: c.state.providers[0].id, model: "m")
        return (c, root, c.state.instances[0].id)
    }
    func testExperienceDraftIsolatedUntilPublishAndRoundTrips() async throws {
        var requests: [(String,[AgentXMessage])] = []
        let (c, root, member) = try configured { _, model, _, messages in requests.append((model,messages)); return "ok" }
        defer { try? FileManager.default.removeItem(at: root) }
        var config = AgentXAppExperience()
        config.intro = "At the harbor"; config.title = "Reading room"; config.rules = "Start with a conclusion"; config.sharedMemory = "Everyone knows the club meets Friday"
        config.layout = .scene; config.choices = ["Make a plan"]
        config.memberOverrides = [.init(instanceID: member, providerID: c.state.providers[0].id, model: "m2")]
        try c.saveExperienceDraft(appID: "blackcat", configuration: config, expectedDraft: nil)
        c.send("before", instanceID: member); await c.waitForRuns()
        guard requests.count == 1 else { XCTFail(c.errorMessage ?? "Missing first request"); return }; XCTAssertEqual(requests[0].0, "m"); XCTAssertEqual(requests[0].1[0].content, "Published role")
        try c.publishExperience(appID: "blackcat")
        c.send("after", instanceID: member); await c.waitForRuns()
        guard requests.count == 2 else { XCTFail(c.errorMessage ?? "Missing second request"); return }; XCTAssertEqual(requests[1].0, "m2")
        XCTAssertTrue(requests[1].1[0].content.contains(config.sharedMemory))
        XCTAssertTrue(requests[1].1[0].content.contains(config.rules))
        XCTAssertTrue(requests[1].1[0].content.contains(config.intro))
        XCTAssertEqual(try c.repository.load().apps[0].experience?.published?.configuration, config)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("apps/blackcat/memory/agentx-shared.md"), encoding: .utf8), config.sharedMemory)
    }
    func testDraftConflictAndCrossAppModelOverrideRejected() throws {
        let (c, root, _) = try configured { _, _, _, _ in "ok" }
        defer { try? FileManager.default.removeItem(at: root) }
        var config = AgentXAppExperience(); config.title = "One"
        try c.saveExperienceDraft(appID: "blackcat", configuration: config, expectedDraft: nil)
        XCTAssertThrowsError(try c.saveExperienceDraft(appID: "blackcat", configuration: config, expectedDraft: nil))
        config.memberOverrides = [.init(instanceID: "foreign", providerID: c.state.providers[0].id, model: "m")]
        XCTAssertThrowsError(try c.saveExperienceDraft(appID: "blackcat", configuration: config, expectedDraft: c.state.apps[0].experience?.draft))
    }
    func testPublicationCannotOverwriteHandEditedSharedMemory() throws {
        let (c, root, _) = try configured { _, _, _, _ in "ok" }
        defer { try? FileManager.default.removeItem(at: root) }
        var config = AgentXAppExperience(); config.sharedMemory = "First"
        try c.saveExperienceDraft(appID: "blackcat", configuration: config, expectedDraft: nil)
        try c.publishExperience(appID: "blackcat")
        let memory = root.appendingPathComponent("apps/blackcat/memory/agentx-shared.md")
        try "Handwritten".write(to: memory, atomically: true, encoding: .utf8)
        let expected = config; config.sharedMemory = "Next"
        try c.saveExperienceDraft(appID: "blackcat", configuration: config, expectedDraft: expected)
        XCTAssertThrowsError(try c.publishExperience(appID: "blackcat"))
        XCTAssertEqual(try String(contentsOf: memory, encoding: .utf8), "Handwritten")
    }
    func testUsageAssistantIsolatedFromFrontHistoryAndDoesNotChangeDrafts() async throws {
        var requests: [[AgentXMessage]] = []
        let (c, root, member) = try configured { _, _, _, messages in requests.append(messages); return "reply" }
        defer { try? FileManager.default.removeItem(at: root) }
        c.send("private front history", instanceID: member); await c.waitForRuns()
        c.drafts[member] = "Unsent"
        c.sendUsageRequest("How do I use this app?", instanceID: member); await c.waitForRuns()
        XCTAssertEqual(c.state.runs.last?.purpose, .usageAssistant)
        XCTAssertFalse(requests[1].contains { $0.content.contains("private front history") })
        XCTAssertEqual(c.drafts[member], "Unsent")
        XCTAssertNil(c.state.definitions[0].draft)
        c.send("next", instanceID: member); await c.waitForRuns()
        XCTAssertFalse(requests[2].contains { $0.content.contains("How do I use this app?") })
    }
    func testSkinRoundTripAndUndoDoesNotRevertOtherState() throws {
        let (c, root, _) = try configured { _, _, _, _ in "ok" }
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(c.frontSkin, .immersive)
        try c.setFrontSkin(.simple)
        XCTAssertTrue(c.canUndo)
        try c.addApp(name: "Keep this app")
        try c.undoLastChange()
        XCTAssertEqual(c.frontSkin, .immersive)
        XCTAssertEqual(c.state.apps.count, 2)
        try c.setFrontSkin(.simple)
        let reloaded = AgentXController(repository: c.repository, credentials: AgentXTestCredentials())
        XCTAssertEqual(reloaded.frontSkin, .simple)
    }
    func testBackstageRoutesAndAssistantRunRouting() throws {
        XCTAssertTrue(AgentXPage.characters.isBackstage)
        XCTAssertTrue(AgentXPage.sceneRules.isBackstage)
        XCTAssertFalse(AgentXPage.instances.isBackstage)
        XCTAssertFalse(AgentXPage.chat.isBackstage)
        let (c, root, member) = try configured { _, _, _, _ in "ok" }
        defer { try? FileManager.default.removeItem(at: root) }
        var run = AgentXRun(id: UUID().uuidString.lowercased(), appID: "blackcat", instanceID: member, prompt: "Help", status: .completed)
        run.purpose = .usageAssistant
        c.openRun(run)
        XCTAssertEqual(c.page, .chat)
        XCTAssertTrue(c.assistantPresented)
    }
}
