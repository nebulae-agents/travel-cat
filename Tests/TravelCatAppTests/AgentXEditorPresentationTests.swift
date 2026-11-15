import XCTest
@testable import TravelCatApp

final class AgentXEditorPresentationTests: XCTestCase {
    func testFirstProviderEditCarriesCompleteSnapshot() {
        var provider = AgentXProvider(id: "router", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", models: ["model-a"])
        let presentation = AgentXEditorPresentation(provider: provider)
        provider.name = "Changed after opening"
        XCTAssertEqual(presentation.kind, .provider)
        XCTAssertEqual(presentation.existingProvider?.id, "router")
        XCTAssertEqual(presentation.existingProvider?.name, "OpenRouter")
        XCTAssertEqual(presentation.existingProvider?.models, ["model-a"])
        XCTAssertNil(presentation.existingDefinition)
        XCTAssertNil(presentation.existingInstance)
    }

    func testDefinitionAndInstanceEditsKeepTheirOwnSnapshots() {
        let definition = AgentXDefinition(id: "role", name: "Role", prompt: "Be brief")
        let instance = AgentXInstance(id: "one", name: "One", appID: "blackcat", definitionID: "role", providerID: "router", model: "model-a")
        let definitionEditor = AgentXEditorPresentation(definition: definition)
        let instanceEditor = AgentXEditorPresentation(instance: instance)
        XCTAssertEqual(definitionEditor.kind, .definition)
        XCTAssertEqual(definitionEditor.existingDefinition, definition)
        XCTAssertNil(definitionEditor.existingProvider)
        XCTAssertNil(definitionEditor.existingInstance)
        XCTAssertEqual(instanceEditor.kind, .instance)
        XCTAssertEqual(instanceEditor.existingInstance, instance)
        XCTAssertNil(instanceEditor.existingProvider)
        XCTAssertNil(instanceEditor.existingDefinition)
    }

    func testCreatingAfterEditingCannotReusePreviousEntityOrSheetIdentity() {
        let provider = AgentXProvider(id: "router", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", models: ["model-a"])
        let edit = AgentXEditorPresentation(provider: provider)
        for kind: AgentXEditor in [.app, .provider, .definition, .instance] {
            let create = AgentXEditorPresentation(create: kind)
            XCTAssertEqual(create.kind, kind)
            XCTAssertNil(create.existingProvider)
            XCTAssertNil(create.existingDefinition)
            XCTAssertNil(create.existingInstance)
            XCTAssertNotEqual(create.id, edit.id)
        }
        XCTAssertNotEqual(edit.id, AgentXEditorPresentation(provider: provider).id)
    }
}
