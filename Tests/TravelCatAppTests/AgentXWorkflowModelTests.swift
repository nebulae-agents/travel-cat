import XCTest
@testable import TravelCatApp

final class AgentXWorkflowModelTests: XCTestCase {
    private let instance = AgentXInstance(id: "member", name: "Writer", appID: "app", definitionID: "def", providerID: "provider", model: "model")
    private var step: AgentXWorkflowStep { .init(name: "Draft", instanceID: "member", instruction: "Write a draft") }

    func testPublishedWorkflowRequiresCompleteFieldsAndMembers() throws {
        let valid = AgentXWorkflowDefinition(name: "Writing", steps: [step])
        XCTAssertNoThrow(try valid.validate(appID: "app", instances: [instance]))
        XCTAssertThrowsError(try valid.validate(appID: "other", instances: [instance]))
        XCTAssertThrowsError(try AgentXWorkflowDefinition(name: " ", steps: [step]).validate(appID: "app", instances: [instance]))
        XCTAssertThrowsError(try AgentXWorkflowDefinition(name: "Writing", steps: []).validate(appID: "app", instances: [instance]))
        var incomplete = step
        incomplete.instruction = "\n"
        XCTAssertThrowsError(try AgentXWorkflowDefinition(name: "Writing", steps: [incomplete]).validate(appID: "app", instances: [instance]))
    }

    func testDraftAllowsIncompleteFieldsButNeverCrossAppMembers() throws {
        let incomplete = AgentXWorkflowDefinition(name: "", steps: [.init(name: "", instanceID: "", instruction: "")])
        XCTAssertNoThrow(try incomplete.validate(appID: "app", instances: [instance], requireRunnable: false))
        XCTAssertThrowsError(try AgentXWorkflowDefinition(name: "", steps: [step]).validate(appID: "other", instances: [instance], requireRunnable: false))
    }

    func testDuplicateStepIDsAndOverlongPipelinesRejectedEvenInDraft() throws {
        let repeated = step
        XCTAssertThrowsError(try AgentXWorkflowDefinition(name: "Writing", steps: [repeated, repeated]).validate(appID: "app", instances: [instance], requireRunnable: false))
        let oversized = AgentXWorkflowDefinition(name: "Writing", steps: (0..<13).map { .init(name: "Step \($0)", instanceID: "member", instruction: "Continue") })
        XCTAssertThrowsError(try oversized.validate(appID: "app", instances: [instance], requireRunnable: false))
    }

    func testDraftEditsDoNotChangePublishedSnapshotAndConfigurationRoundTrips() throws {
        let published = AgentXWorkflowDefinition(name: "Original", steps: [step])
        var config = AgentXWorkflowConfiguration(draft: published, revisions: [.init(number: 1, definition: published, publishedAt: Date(timeIntervalSince1970: 100))], publishedRevision: 1)
        config.draft?.name = "Unpublished"
        XCTAssertEqual(config.published?.definition.name, "Original")
        XCTAssertEqual(try JSONDecoder().decode(AgentXWorkflowConfiguration.self, from: JSONEncoder().encode(config)), config)
        config.publishedRevision = 99
        XCTAssertNil(config.published)
    }
}
