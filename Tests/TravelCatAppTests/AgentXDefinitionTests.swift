import Foundation
import Testing
@testable import TravelCatApp

@MainActor private final class DefinitionFixtureCredentials: TravelServiceCredentialStoring {
    private var values: [String: String] = [:]
    func read(id: String) throws -> String? { values[id] }
    func save(_ secret: String?, id: String) throws { values[id] = secret }
}
struct AgentXDefinitionTests {
    @Test func preservesFrontmatterAndLoadsSoulWithoutExecutingUnsupportedRuntime() throws {
        let source = "---\nname: Writer\nruntime: host-text\nsoul: ./soul.md\ncustom: {nested: [one, two]}\n---\nWrite carefully.\n"
        let document = AgentXDefinitionDocument(source: source, files: ["soul.md": "Be kind.", "extra.md": "keep me"])
        try document.validate()
        #expect(document.source == source)
        #expect(try document.executionPrompt().contains("Be kind."))
        #expect(try document.executionPrompt().contains("Write carefully."))
        let restored = try JSONDecoder().decode(AgentXDefinitionDocument.self, from: JSONEncoder().encode(document))
        #expect(restored == document)
        #expect(throws: (any Error).self) { try AgentXDefinitionDocument(source: "---\nruntime: agentscope\n---\nHello").executionPrompt() }
        #expect(throws: (any Error).self) { try AgentXDefinitionDocument(source: "---\nsoul: ../secret.md\n---\nHello").validate() }
        #expect(throws: (any Error).self) { try AgentXDefinitionDocument(source: "---\nsoul: /tmp/secret.md\n---\nHello").validate() }
    }
    @Test func rejectsCaseAliasedReservedFiles() throws {
        #expect(throws: (any Error).self) { try AgentXDefinitionDocument(source: "Hello", files: ["Agent.md": "overwrite"]).validate() }
        #expect(throws: (any Error).self) { try AgentXDefinitionDocument(source: "Hello", files: ["Definition.yaml": "overwrite"]).validate() }
        #expect(throws: (any Error).self) { try AgentXDefinitionDocument(source: "Hello", files: ["a.md": "one", "A.md": "two"]).validate() }
    }
    @Test func directoryImportPreservesExtraFilesAndRejectsLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("---\nsoul: ./soul.md\n---\nHello".utf8).write(to: root.appendingPathComponent("agent.md"))
        try Data("Kind".utf8).write(to: root.appendingPathComponent("soul.md"))
        try Data("Unknown auxiliary data".utf8).write(to: root.appendingPathComponent("notes.txt"))
        let document = try AgentXDefinitionDocument.importDirectory(root)
        #expect(document.files["notes.txt"] == "Unknown auxiliary data")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("bad.md"), withDestinationURL: root.appendingPathComponent("soul.md"))
        #expect(throws: (any Error).self) { try AgentXDefinitionDocument.importDirectory(root) }
    }
    @Test @MainActor func draftsDoNotReplacePublishedPromptAndHistoryRoundTrips() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = AgentXRepository(root: root)
        var received: [String] = []
        let controller = AgentXController(repository: repository, credentials: DefinitionFixtureCredentials(), respond: { _, _, _, messages in received.append(messages.first?.content ?? ""); return "ok" })
        try controller.addProvider(name: "Local", address: "http://localhost:1234", models: "m", secret: "")
        let id = try controller.addDefinitionDraft(name: "Writer", document: .init(source: "First published"))
        try controller.publishDefinition(id: id)
        try controller.addInstance(name: "Writer", appID: "blackcat", definitionID: id, providerID: controller.state.providers[0].id, model: "m")
        let instance = try #require(controller.state.instances.first)
        try controller.saveDefinitionDraft(id: id, name: "Writer", document: .init(source: "Unpublished edit"))
        controller.send("one", instanceID: instance.id)
        await controller.waitForRuns()
        #expect(received == ["First published"])
        try controller.publishDefinition(id: id)
        controller.send("two", instanceID: instance.id)
        await controller.waitForRuns()
        #expect(received == ["First published", "Unpublished edit"])
        let reopened = try repository.load()
        #expect(reopened.definitions[0].revisions?.count == 2)
        #expect(reopened.definitions[0].draft?.source == "Unpublished edit")
        try controller.restoreDefinitionDraft(id: id, revision: 1)
        #expect(controller.state.definitions[0].draft?.source == "First published")
        #expect(controller.state.definitions[0].publishedRevision == 2)
    }
    @Test @MainActor func instanceEditRejectsRunningBindingsAndPersistsVariables() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = AgentXController(repository: .init(root: root), credentials: DefinitionFixtureCredentials(), respond: { _, _, _, _ in try await Task.sleep(for: .milliseconds(100)); return "ok" })
        try controller.addProvider(name: "Local", address: "http://localhost:1234", models: "m", secret: "")
        try controller.addDefinition(name: "D", prompt: "Hi {{name}}")
        let definition = controller.state.definitions[0]
        let provider = controller.state.providers[0]
        try controller.addInstance(name: "I", appID: "blackcat", definitionID: definition.id, providerID: provider.id, model: "m")
        let id = controller.state.instances[0].id
        try controller.updateInstance(id: id, name: "Updated", appID: "blackcat", definitionID: definition.id, providerID: provider.id, model: "m", variables: ["name": "Ada"])
        #expect(controller.state.instances[0].variables?["name"] == "Ada")
        controller.send("hello", instanceID: id)
        #expect(throws: (any Error).self) { try controller.updateInstance(id: id, name: "Busy", appID: "blackcat", definitionID: definition.id, providerID: provider.id, model: "m") }
        await controller.waitForRuns()
    }
}
