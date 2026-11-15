import XCTest
@testable import TravelCatApp

@MainActor
final class AgentXDesignV12Tests: XCTestCase {
    func testConfigurationAssistantIsIsolatedAndRequiresExplicitDraftAndPublication() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentXV12-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var requests: [[AgentXMessage]] = []
        let controller = AgentXController(repository: .init(root: root), credentials: AgentXTestCredentials(), respond: { _, _, _, messages in
            requests.append(messages)
            return "New role body"
        })
        try controller.addProvider(name: "Local", address: "http://localhost:1234", models: "m", secret: "")
        try controller.addDefinition(name: "Writer", prompt: "Original role")
        let definitionID = controller.state.definitions[0].id
        try controller.addInstance(name: "Writer", appID: "blackcat", definitionID: definitionID, providerID: controller.state.providers[0].id, model: "m")
        let instanceID = controller.state.instances[0].id
        controller.send("Private front conversation", instanceID: instanceID)
        await controller.waitForRuns()
        controller.drafts[instanceID] = "Unsent front input"
        controller.sendConfigurationRequest("Make it concise", instanceID: instanceID)
        await controller.waitForRuns()
        let proposal = try XCTUnwrap(controller.state.runs.last)
        XCTAssertEqual(proposal.purpose, .configuration)
        XCTAssertEqual(requests[1].count, 2)
        XCTAssertFalse(requests[1].contains { $0.content.contains("Private front conversation") })
        XCTAssertEqual(controller.drafts[instanceID], "Unsent front input")
        XCTAssertEqual(controller.state.definitions[0].prompt, "Original role")
        XCTAssertNil(controller.state.definitions[0].draft)
        XCTAssertEqual(controller.configurationProposalStage(proposal), .review)
        try controller.applyConfigurationProposal(runID: proposal.id)
        XCTAssertEqual(controller.state.definitions[0].draft?.source, "New role body")
        XCTAssertEqual(controller.configurationProposalStage(proposal), .saved)
        XCTAssertEqual(controller.state.definitions[0].prompt, "Original role")
        try controller.publishDefinition(id: definitionID)
        XCTAssertEqual(controller.configurationProposalStage(proposal), .published)
        controller.send("Next front message", instanceID: instanceID)
        await controller.waitForRuns()
        XCTAssertEqual(requests[2].first?.content, "New role body")
        XCTAssertFalse(requests[2].contains { $0.content.contains("Make it concise") })
        XCTAssertEqual(try controller.repository.load().runs.first { $0.id == proposal.id }?.purpose, .configuration)
    }

    func testPublicationDoesNotChangeInFlightRequestAndPinnedInstance() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentXV12-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var systems: [String] = []
        let controller = AgentXController(repository: .init(root: root), credentials: AgentXTestCredentials(), respond: { _, _, _, messages in
            systems.append(messages[0].content)
            try await Task.sleep(for: .milliseconds(50))
            return "done"
        })
        try controller.addProvider(name: "Local", address: "http://localhost:1234", models: "m", secret: "")
        let id = try controller.addDefinitionDraft(name: "Writer", document: .init(source: "Version one"))
        try controller.publishDefinition(id: id)
        try controller.addInstance(name: "Follow", appID: "blackcat", definitionID: id, providerID: controller.state.providers[0].id, model: "m")
        let follow = controller.state.instances[0].id
        try controller.addInstance(name: "Pinned", appID: "blackcat", definitionID: id, providerID: controller.state.providers[0].id, model: "m", definitionRevision: 1)
        let pinned = controller.state.instances[1].id
        controller.send("before", instanceID: follow)
        try controller.saveDefinitionDraft(id: id, name: "Writer", document: .init(source: "Version two"))
        try controller.publishDefinition(id: id)
        await controller.waitForRuns()
        XCTAssertEqual(systems, ["Version one"])
        controller.send("after", instanceID: follow)
        await controller.waitForRuns()
        controller.send("pinned", instanceID: pinned)
        await controller.waitForRuns()
        XCTAssertEqual(systems, ["Version one", "Version two", "Version one"])
    }

    func testLegacyRunDecodesAsConversationAndConfigurationInboxOpensExactProposal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentXV12-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = AgentXRun(id: UUID().uuidString.lowercased(), appID: "blackcat", instanceID: "a", prompt: "old", status: .completed)
        let decoded = try JSONDecoder().decode(AgentXRun.self, from: JSONEncoder().encode(legacy))
        XCTAssertNil(decoded.purpose)
        let repository = AgentXRepository(root: root)
        var state = AgentXState()
        var proposal = legacy
        proposal.purpose = .configuration
        state.runs = [proposal]
        try repository.save(state)
        let controller = AgentXController(repository: repository, credentials: AgentXTestCredentials())
        controller.openRun(proposal)
        XCTAssertEqual(controller.page, .configuration)
        XCTAssertEqual(controller.selectedConfigurationRunID, proposal.id)
        controller.openRun(decoded)
        XCTAssertEqual(controller.page, .chat)
    }

    func testReturningToSameAppPreservesSelectedMember() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentXV12-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = AgentXController(repository: .init(root: root), credentials: AgentXTestCredentials())
        controller.selectedInstanceID = "chosen-member"
        controller.page = .configuration
        controller.openApp("blackcat")
        XCTAssertEqual(controller.selectedInstanceID, "chosen-member")
        try controller.addApp(name: "Different app")
        let otherAppID = try XCTUnwrap(controller.state.apps.last?.id)
        controller.openApp("blackcat")
        controller.selectedInstanceID = "chosen-member"
        controller.openApp(otherAppID)
        XCTAssertEqual(controller.selectedInstanceID, "")
    }

    func testPublishedTextSuggestionCanRestoreDifferentDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentXV12-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = AgentXController(repository: .init(root: root), credentials: AgentXTestCredentials(), respond: { _, _, _, _ in "Published body" })
        try controller.addProvider(name: "Local", address: "http://localhost:1234", models: "m", secret: "")
        try controller.addDefinition(name: "Writer", prompt: "Published body")
        let id = controller.state.definitions[0].id
        try controller.saveDefinitionDraft(id: id, name: "Writer", document: .init(source: "Different draft"))
        try controller.addInstance(name: "Writer", appID: "blackcat", definitionID: id, providerID: controller.state.providers[0].id, model: "m")
        controller.sendConfigurationRequest("Restore original", instanceID: controller.state.instances[0].id)
        await controller.waitForRuns()
        let proposal = try XCTUnwrap(controller.state.runs.last)
        XCTAssertEqual(controller.configurationProposalStage(proposal), .review)
        try controller.applyConfigurationProposal(runID: proposal.id)
        XCTAssertEqual(controller.state.definitions[0].draft?.source, "Published body")
        XCTAssertEqual(controller.configurationProposalStage(proposal), .published)
    }

    func testProposalRejectsConcurrentEditsAndPreservesDefinitionFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentXV12-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = AgentXController(repository: .init(root: root), credentials: AgentXTestCredentials(), respond: { _, _, _, _ in "New body" })
        try controller.addProvider(name: "Local", address: "http://localhost:1234", models: "m", secret: "")
        let document = AgentXDefinitionDocument(source: "---\nsoul: ./soul.md\ncustom: retained\n---\nOld body", files: ["soul.md": "Kind"])
        let id = try controller.addDefinitionDraft(name: "Writer", document: document)
        try controller.publishDefinition(id: id)
        try controller.addInstance(name: "Writer", appID: "blackcat", definitionID: id, providerID: controller.state.providers[0].id, model: "m")
        let instance = controller.state.instances[0]
        controller.sendConfigurationRequest("Edit", instanceID: instance.id)
        await controller.waitForRuns()
        let proposal = try XCTUnwrap(controller.state.runs.last)
        try controller.applyConfigurationProposal(runID: proposal.id)
        let saved = try XCTUnwrap(controller.state.definitions[0].draft)
        XCTAssertTrue(saved.source.contains("custom: retained"))
        XCTAssertEqual(saved.files, document.files)
        XCTAssertEqual(try saved.bodyText(), "New body")
        try controller.saveDefinitionDraft(id: id, name: "Writer", document: .init(source: "Manual change"))
        XCTAssertThrowsError(try controller.applyConfigurationProposal(runID: proposal.id))
        XCTAssertEqual(controller.state.definitions[0].draft?.source, "Manual change")
    }
}
