import XCTest
@testable import TravelCatApp

@MainActor final class AgentXStudioIntegrationTests: XCTestCase {
    func make(_ responder: @escaping AgentXController.Responder) throws -> (AgentXController, URL, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentXStudio-\(UUID())")
        let c = AgentXController(repository: .init(root: root), credentials: AgentXTestCredentials(), respond: responder)
        try c.addProvider(name: "Test", address: "http://localhost:1234", models: "m", secret: "")
        try c.addDefinition(name: "Role", prompt: "Published")
        let id = c.state.definitions[0].id
        try c.addInstance(name: "One", appID: "blackcat", definitionID: id, providerID: c.state.providers[0].id, model: "m")
        return (c, root, id)
    }
    func testCharacterDraftConflictAndPreviewIsolation() async throws {
        var messages: [[AgentXMessage]] = []
        let (c, root, id) = try make { _, _, _, request in messages.append(request); return "hello" }
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try c.state.definitions[0].publishedDocument()
        var profile = try c.characterProfile(definitionID: id)
        try profile.setText("Gentle", for: .voice)
        let saved = try c.saveCharacterDraft(definitionID: id, profile: profile, expectedDocument: original)
        XCTAssertThrowsError(try c.saveCharacterDraft(definitionID: id, profile: profile, expectedDocument: original))
        XCTAssertTrue(try saved.executionPrompt().contains("Gentle"))
        c.previewCharacter("Try", instanceID: c.state.instances[0].id)
        await c.waitForRuns()
        XCTAssertEqual(c.state.runs.last?.purpose, .characterPreview)
        XCTAssertTrue(messages[0][0].content.contains("Gentle"))
        c.send("Chat", instanceID: c.state.instances[0].id)
        await c.waitForRuns()
        XCTAssertEqual(messages[1][0].content, "Published")
        XCTAssertEqual(messages[1].count, 2)
    }
    func testWorkflowSequenceSnapshotPersistenceAndBusyProtection() async throws {
        var messages: [[AgentXMessage]] = []
        let (c, root, id) = try make { _, _, _, request in
            messages.append(request)
            try await Task.sleep(for: .milliseconds(30))
            return "output-\(messages.count)"
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let member = c.state.instances[0].id
        let draft = AgentXWorkflowDefinition(name: "Pipeline", steps: [.init(name: "First", instanceID: member, instruction: "Plan"), .init(name: "Second", instanceID: member, instruction: "Review")])
        try c.saveWorkflowDraft(appID: "blackcat", definition: draft, expectedDraft: nil)
        try c.publishWorkflow(appID: "blackcat")
        c.startWorkflow("Task", appID: "blackcat")
        XCTAssertTrue(c.isInstanceBusy(member))
        c.send("Must not overlap", instanceID: member)
        XCTAssertEqual(c.state.runs.count, 1)
        try c.saveDefinitionDraft(id: id, name: "Role", document: .init(source: "New published"))
        try c.publishDefinition(id: id)
        await c.waitForRuns()
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[1][0].content, "Published")
        XCTAssertTrue(messages[1][1].content.contains("output-1"))
        XCTAssertEqual(c.state.runs[0].workflowSteps?.count, 2)
        XCTAssertEqual(c.state.runs[0].response, "output-2")
        XCTAssertEqual(c.state.runs[0].status, .completed)
        XCTAssertFalse(c.isInstanceBusy(member))
        XCTAssertEqual(try c.repository.load().apps[0].workflow?.published?.definition, draft)
    }
    func testWorkflowFailureAndCancellationStopNextStep() async throws {
        var calls = 0
        let (c, root, _) = try make { _, _, _, _ in calls += 1; try await Task.sleep(for: .seconds(10)); return "late" }
        defer { try? FileManager.default.removeItem(at: root) }
        let member = c.state.instances[0].id
        let draft = AgentXWorkflowDefinition(name: "Pipeline", steps: [.init(name: "First", instanceID: member, instruction: "Plan"), .init(name: "Second", instanceID: member, instruction: "Review")])
        try c.saveWorkflowDraft(appID: "blackcat", definition: draft, expectedDraft: nil)
        try c.publishWorkflow(appID: "blackcat")
        c.startWorkflow("Task", appID: "blackcat")
        try await Task.sleep(for: .milliseconds(30))
        c.cancel(c.state.runs[0].id)
        await c.waitForRuns()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(c.state.runs[0].status, .cancelled)
        XCTAssertEqual(c.state.runs[0].workflowSteps?.count, 1)
    }
    func testStructuredSelectionPersistsOnlySelectedChanges() async throws {
        let (c, root, id) = try make { _, _, _, _ in
            #"{"summary":"change","changes":[{"id":"body","dimension":"body","value":"Changed body","reason":"x"},{"id":"voice","dimension":"voice","value":"Gentle","reason":"y"}]}"#
        }
        defer { try? FileManager.default.removeItem(at: root) }
        c.sendConfigurationRequest("Change", instanceID: c.state.instances[0].id)
        await c.waitForRuns()
        let run = try XCTUnwrap(c.state.runs.last)
        try c.applyConfigurationProposal(runID: run.id, selectedChangeIDs: ["voice"])
        let applied = try XCTUnwrap(c.state.runs.last)
        XCTAssertEqual(applied.configurationAppliedChangeIDs, ["voice"])
        XCTAssertEqual(c.configurationProposalStage(applied), .saved)
        XCTAssertEqual(try c.characterProfile(definitionID: id).text(for: .voice), "Gentle")
        XCTAssertFalse(try c.state.definitions[0].draft!.bodyText().contains("Changed body"))
        XCTAssertEqual(c.state.definitions[0].prompt, "Published")
        XCTAssertThrowsError(try c.applyConfigurationProposal(runID: run.id, selectedChangeIDs: ["body"]))
        try c.publishDefinition(id: id)
        XCTAssertEqual(c.configurationProposalStage(applied), .published)
        XCTAssertEqual(try c.repository.load().runs.last?.configurationAppliedChangeIDs, ["voice"])
    }
    func testWorkflowFailureStopsFollowingStep() async throws {
        var calls = 0
        let (c, root, _) = try make { _, _, _, _ in calls += 1; throw AgentXError.unavailable }
        defer { try? FileManager.default.removeItem(at: root) }
        let member = c.state.instances[0].id
        let draft = AgentXWorkflowDefinition(name: "Pipeline", steps: [.init(name: "First", instanceID: member, instruction: "Plan"), .init(name: "Second", instanceID: member, instruction: "Review")])
        try c.saveWorkflowDraft(appID: "blackcat", definition: draft, expectedDraft: nil)
        try c.publishWorkflow(appID: "blackcat")
        c.startWorkflow("Task", appID: "blackcat")
        await c.waitForRuns()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(c.state.runs[0].status, .failed)
        XCTAssertEqual(c.state.runs[0].workflowSteps?.first?.status, .failed)
        XCTAssertEqual(c.state.runs[0].workflowSteps?.count, 1)
    }

    func testWorkflowAuditFailurePreservesGeneratedOutputAndStops() async throws {
        var testRoot: URL?
        var calls = 0
        let (c, root, _) = try make { _, _, _, _ in
            calls += 1
            try Data("broken".utf8).write(to: testRoot!.appendingPathComponent("audit/blackcat/00000000000000000001.event"))
            return "Retain this output"
        }
        testRoot = root
        defer { try? FileManager.default.removeItem(at: root) }
        let member = c.state.instances[0].id
        let draft = AgentXWorkflowDefinition(name: "Pipeline", steps: [.init(name: "First", instanceID: member, instruction: "Plan"), .init(name: "Second", instanceID: member, instruction: "Review")])
        try c.saveWorkflowDraft(appID: "blackcat", definition: draft, expectedDraft: nil)
        try c.publishWorkflow(appID: "blackcat")
        c.startWorkflow("Task", appID: "blackcat")
        await c.waitForRuns()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(c.state.runs[0].response, "Retain this output")
        XCTAssertEqual(c.state.runs[0].workflowSteps?.first?.output, "Retain this output")
        XCTAssertEqual(c.state.runs[0].status, .failed)
        XCTAssertNotNil(c.state.runs[0].auditFailure)
        XCTAssertEqual(try c.repository.load().runs[0].response, "Retain this output")
        var state = c.state
        state.runs[0].status = .running
        state.runs[0].workflowSteps?[0].status = .running
        try c.repository.save(state)
        let reopened = AgentXController(repository: c.repository, credentials: AgentXTestCredentials())
        XCTAssertEqual(reopened.state.runs[0].status, .failed)
        XCTAssertEqual(reopened.state.runs[0].workflowSteps?.first?.status, .failed)
    }

}
