import XCTest
@testable import TravelCatApp

@MainActor
final class AgentXLayeredRepositoryTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AgentXLayered-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testDesignApplicationYAMLPreservesRuntimeModulesAndUnknownConfiguration() throws {
        let directory = try root(), repository = AgentXRepository(root: directory)
        try repository.save(AgentXState())
        let app = directory.appendingPathComponent("apps/tavern")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let file = app.appendingPathComponent("app.yaml")
        try Data("id: tavern\nname: Tavern\nkind: npc-drama\nruntime: agentscope\nmodules: [stage, world-state]\norchestration: {type: turn-based, max_speakers_per_turn: 2}\nfront_stage: {allow_branching: true}\nversion: 5\n".utf8).write(to: file)
        let state = try repository.load()
        XCTAssertEqual(state.apps.first { $0.id == "tavern" }?.kind.rawValue, "npc-drama")
        XCTAssertEqual(state.apps.first { $0.id == "tavern" }?.canRunHostText, false)
        try repository.save(state)
        let saved = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(saved.contains("agentscope"))
        XCTAssertTrue(saved.contains("max_speakers_per_turn: 2"))
        XCTAssertTrue(saved.contains("allow_branching: true"))
    }
    func testProviderProtocolProfileAndModelChoicesRoundTrip() throws {
        let root = try root(), repository = AgentXRepository(root: root)
        var state = AgentXState()
        var provider = AgentXProvider(id: "service", name: "Service", baseURL: "https://example.com", models: ["a", "b"])
        provider.serviceProtocol = .responses
        provider.credentialProfile = "team"
        provider.modelSelection = .init(models: [.init(id: "a", enabled: true, favorite: true), .init(id: "b", enabled: false, favorite: false)])
        state.providers = [provider]
        state.credentialProfiles = [.init(name: "team", keyReferences: ["key-one", "key-two"])]
        try repository.save(state)
        XCTAssertEqual(try repository.load(), state)
        let text = try String(contentsOf: root.appendingPathComponent("manager/providers/service.yaml"), encoding: .utf8)
        XCTAssertTrue(text.contains("responses"))
        XCTAssertTrue(text.contains("favorite: true"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("manager/secrets/team.yaml").path))
    }
    func testRejectsCaseAliasedApplications() throws {
        var state = AgentXState()
        state.apps += [.init(id: "Notes", name: "First", kind: .chat), .init(id: "notes", name: "Second", kind: .chat)]
        XCTAssertThrowsError(try AgentXRepository(root: root()).save(state))
    }
    func testRejectsRecordClaimingAnotherApplication() throws {
        let root = try root(), repository = AgentXRepository(root: root)
        var state = AgentXState()
        state.apps.append(.init(id: "notes", name: "Notes", kind: .chat))
        try repository.save(state)
        let forged = AgentXRun(id: "forged", appID: "notes", instanceID: "i", prompt: "cross-app", status: .completed)
        try JSONEncoder().encode(forged).write(to: root.appendingPathComponent("apps/blackcat/runs/forged.json"))
        XCTAssertThrowsError(try repository.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("apps/notes/runs/forged.json").path))
    }
    func testInterruptedNewAppSaveRestoresUsableOriginalRoot() throws {
        let root = try root(), repository = AgentXRepository(root: root)
        try repository.save(.init())
        let dir = root.appendingPathComponent("apps/interrupted")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("state"), withIntermediateDirectories: true)
        try Data("incomplete".utf8).write(to: dir.appendingPathComponent("app.yaml"))
        let journal: [String: Any] = ["files": [["path": "apps/interrupted/app.yaml"]], "directories": ["apps/interrupted", "apps/interrupted/state"]]
        try JSONSerialization.data(withJSONObject: journal).write(to: root.appendingPathComponent(".agentx-transaction.json"))
        XCTAssertEqual(try repository.load(), AgentXState())
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }
    func testRootContainsOnlySettingsAndApplicationsAreSelfContained() throws {
        let root = try root(), repository = AgentXRepository(root: root)
        var state = AgentXState()
        state.providers = [.init(id: "local", name: "Local", baseURL: "http://localhost:1234", models: ["model"])]
        state.definitions = [.init(id: "writer", name: "Writer", prompt: "Write carefully.")]
        state.instances = [.init(id: "a", name: "Writer", appID: "blackcat", definitionID: "writer", providerID: "local", model: "model")]
        state.runs = [.init(id: "r", appID: "blackcat", instanceID: "a", prompt: "private conversation", status: .completed, response: "response")]
        try repository.save(state)
        let rootText = try String(contentsOf: root.appendingPathComponent("agentx.yaml"), encoding: .utf8)
        XCTAssertFalse(rootText.contains("private conversation"))
        XCTAssertFalse(rootText.contains("baseURL"))
        XCTAssertFalse(rootText.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"))
        for path in ["manager/providers/local.yaml", "manager/templates/assistant/writer/agent.md", "apps/blackcat/app.yaml", "apps/blackcat/instances/a/config/agent.yaml", "apps/blackcat/runs/r.json"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path), path)
        }
        XCTAssertEqual(try repository.load(), state)
    }
    func testOldSingleManifestIsImportedWithoutLosingOriginalBytes() throws {
        let root = try root(), repository = AgentXRepository(root: root)
        var original = AgentXState(); original.blackCatEnabled = false
        let bytes = try JSONEncoder().encode(original)
        try bytes.write(to: root.appendingPathComponent("agentx.yaml"))
        let state = try repository.load(); try repository.save(state)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("backups/legacy-v1/agentx.json")), bytes)
        XCTAssertEqual(try repository.load(), original)
    }
    func testReadsRealYAMLRootAndProviderWithoutJSONRestriction() throws {
        let root = try root(), repository = AgentXRepository(root: root)
        try repository.save(.init())
        try Data("version: 1\nmode: full\nblackcat:\n  enabled: false\n".utf8).write(to: root.appendingPathComponent("agentx.yaml"))
        let path = root.appendingPathComponent("manager/providers/deepseek.yaml")
        try Data("name: deepseek\ndisplay: DeepSeek\nenabled: true\napi_mode: openai-compatible\nbase_url: https://api.deepseek.com\nmodels:\n  - id: deepseek-chat\n    enabled: true\n    favorite: true\n".utf8).write(to: path)
        let loaded = try repository.load()
        XCTAssertFalse(loaded.blackCatEnabled)
        XCTAssertEqual(loaded.providers.first?.models, ["deepseek-chat"])
        try repository.save(loaded)
        let saved = try String(contentsOf: path, encoding: .utf8)
        XCTAssertTrue(saved.contains("favorite: true"))
    }
    func testSingleAppDirectoryRetainsHistoryAfterCopyIntoAnotherRoot() throws {
        let source = try root(), target = try root()
        var state = AgentXState()
        state.apps.append(.init(id: "notes", name: "Notes", kind: .chat))
        state.runs = [.init(id: "r", appID: "notes", instanceID: "i", prompt: "stay with notes", status: .completed)]
        try AgentXRepository(root: source).save(state)
        try AgentXRepository(root: target).save(.init())
        try FileManager.default.copyItem(at: source.appendingPathComponent("apps/notes"), to: target.appendingPathComponent("apps/notes"))
        let loaded = try AgentXRepository(root: target).load()
        XCTAssertEqual(loaded.runs.first?.prompt, "stay with notes")
        XCTAssertTrue(loaded.apps.contains { $0.id == "notes" })
    }
}
