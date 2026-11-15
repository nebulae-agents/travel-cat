import XCTest
import Yams
@testable import TravelCatApp

@MainActor
final class AgentXApplicationPolicyTests: XCTestCase {
    private func repository() throws -> AgentXRepository {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AppPolicy-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return AgentXRepository(root: url)
    }
    func testDisabledCanonicalManifestRejectsSelectionAndRestoresFallback() throws {
        let repo = try repository()
        var state = AgentXState()
        state.apps.append(.init(id: "notes", name: "Notes", kind: .chat))
        try repo.save(state)
        try Data("id: blackcat\nname: BlackCat\nkind: blackcat\nenabled: false\n".utf8).write(to: repo.root.appendingPathComponent("apps/blackcat/app.yaml"))
        try Data("version: 1\ncurrent_app: blackcat\napps_enabled: [blackcat, notes]\n".utf8).write(to: repo.root.appendingPathComponent("agentx.yaml"))
        let controller = AgentXController(repository: repo, credentials: AgentXTestCredentials(), autoRefreshCatalogs: false)
        XCTAssertEqual(controller.selectedAppID, "notes")
        controller.selectedInstanceID = "keep-selection"
        controller.openApp("blackcat")
        XCTAssertEqual(controller.selectedAppID, "notes")
        XCTAssertEqual(controller.selectedInstanceID, "keep-selection")
        controller.openApp("missing")
        XCTAssertEqual(controller.selectedAppID, "notes")
        XCTAssertEqual(controller.selectedInstanceID, "keep-selection")
    }

    private func configured() throws -> AgentXRepository {
        let repo = try repository()
        var state = AgentXState()
        state.apps = [.init(id: "blackcat", name: "BlackCat", kind: .blackcat, enabled: false), .init(id: "a", name: "A", kind: .chat), .init(id: "b", name: "B", kind: .chat)]
        state.providers = [.init(id: "local", name: "Local", baseURL: "http://localhost:1234", models: ["model"])]
        state.definitions = [.init(id: "writer", name: "Writer", prompt: "Write.")]
        state.instances = ["a", "b"].map { .init(id: $0, name: $0, appID: $0, definitionID: "writer", providerID: "local", model: "model") }
        try repo.save(state)
        return repo
    }
    func testStopWaitsForIgnoringResponderAndOnlyCancelsOwnApp() async throws {
        let repo = try configured()
        var continuations: [String: CheckedContinuation<String, Never>] = [:]
        let controller = AgentXController(repository: repo, credentials: AgentXTestCredentials(), respond: { _, _, _, messages in
            await withCheckedContinuation { continuations[messages.last!.content] = $0 }
        }, autoRefreshCatalogs: false)
        let externalStop = expectation(description: "external stop starts before internal responder exits")
        controller.externalRuntimeStop = { _ in externalStop.fulfill() }
        controller.send("a", instanceID: "a")
        controller.send("b", instanceID: "b")
        while continuations.count < 2 { await Task.yield() }
        let stopping = Task { try await controller.setApplicationEnabled("a", enabled: false) }
        while controller.applicationStopStates["a"] == nil { await Task.yield() }
        await fulfillment(of: [externalStop], timeout: 1)
        XCTAssertEqual(controller.applicationStopStates["a"], .stopping)
        XCTAssertEqual(controller.state.runs.first { $0.appID == "a" }?.status, .cancelling)
        XCTAssertEqual(controller.state.runs.first { $0.appID == "b" }?.status, .running)
        controller.sendUsageRequest("blocked", instanceID: "a")
        XCTAssertEqual(controller.state.runs.count, 2)
        do { try await controller.setApplicationEnabled("a", enabled: true); XCTFail("Cannot reenable while stopping") } catch {}
        continuations.removeValue(forKey: "a")!.resume(returning: "late ignored result")
        try await stopping.value
        XCTAssertEqual(controller.applicationStopStates["a"], .stopped)
        // A successful responder result wins the cancellation race and remains auditable.
        XCTAssertEqual(controller.state.runs.first { $0.appID == "a" }?.status, .completed)
        XCTAssertEqual(controller.state.runs.first { $0.appID == "a" }?.response, "late ignored result")
        continuations.removeValue(forKey: "b")!.resume(returning: "B completed")
        while controller.state.runs.first(where: { $0.appID == "b" })?.status == .running { await Task.yield() }
        XCTAssertEqual(controller.state.runs.first { $0.appID == "b" }?.response, "B completed")
        try await controller.setApplicationEnabled("a", enabled: true)
        XCTAssertEqual(controller.state.runs.count, 2)
    }
    func testExternalStopRequiresHookAndFailureNeverClaimsStopped() async throws {
        let controller = AgentXController(repository: try repository(), credentials: AgentXTestCredentials(), autoRefreshCatalogs: false)
        do { try await controller.setApplicationEnabled("blackcat", enabled: false); XCTFail("Missing hook") } catch {}
        XCTAssertFalse(controller.state.apps[0].enabled)
        guard case .unverified = controller.applicationStopStates["blackcat"] else { return XCTFail("Stop unverified") }
        controller.externalRuntimeStop = { _ in throw AgentXError.unavailable }
        do { try await controller.setApplicationEnabled("blackcat", enabled: false); XCTFail("Failed hook") } catch {}
        guard case .unverified = controller.applicationStopStates["blackcat"] else { return XCTFail("Stop unverified") }
        controller.externalRuntimeStop = { _ in }
        try await controller.setApplicationEnabled("blackcat", enabled: false)
        XCTAssertEqual(controller.applicationStopStates["blackcat"], .stopped)
    }
    func testSwitchPersistsSelectionClearsTransientButKeepsDraftsAndScopesResults() throws {
        let repo = try configured()
        let controller = AgentXController(repository: repo, credentials: AgentXTestCredentials(), autoRefreshCatalogs: false)
        controller.drafts = ["a": "A draft", "b": "B draft"]
        controller.assistantPresented = true; controller.selectedConfigurationRunID = "old"
        controller.openApp("b")
        XCTAssertEqual(controller.currentInstances.map(\.id), ["b"])
        XCTAssertFalse(controller.assistantPresented)
        XCTAssertNil(controller.selectedConfigurationRunID)
        XCTAssertEqual(controller.drafts["a"], "A draft")
        XCTAssertEqual(try repo.load().currentAppID, "b")
    }
    func testAllDisabledHasManagementEmptyStateAndPreservesUnknownManifest() throws {
        let repo = try configured()
        for id in ["a", "b"] {
            try Data("id: \(id)\nname: \(id)\nkind: chat\nenabled: false\nmanifest: {author: Author, source: 'zip://local', requires: {runtime: piagent, providers: [local]}, permissions: {shell: false}, ui: {icon: Cat}, future: {keep: true}}\nruntime: piagent\nversion: 5\nmodules: [overview, chat]\ncustom: {keep: yes}\n".utf8).write(to: repo.root.appendingPathComponent("apps/\(id)/app.yaml"))
        }
        let controller = AgentXController(repository: repo, credentials: AgentXTestCredentials(), autoRefreshCatalogs: false)
        XCTAssertEqual(controller.selectedAppID, "")
        XCTAssertEqual(controller.page, .apps)
        XCTAssertTrue(controller.currentInstances.isEmpty)
        XCTAssertTrue(controller.currentRuns.isEmpty)
        XCTAssertEqual(controller.state.apps.first { $0.id == "a" }?.manifestAuthor, "Author")
        XCTAssertTrue(try String(contentsOf: repo.root.appendingPathComponent("apps/a/app.yaml"), encoding: .utf8).contains("custom:"))
    }

    func testMarkAllReadOnlyTouchesCurrentApp() async throws {
        let repo = try configured()
        var state = try repo.load()
        state.runs = ["a", "b", "blackcat"].map { .init(id: $0, appID: $0, instanceID: $0, prompt: "result", status: .completed) }
        state.currentAppID = "a"
        try repo.save(state)
        let controller = AgentXController(repository: repo, credentials: AgentXTestCredentials(), autoRefreshCatalogs: false)
        XCTAssertEqual(controller.state.unreadCount, 2)
        XCTAssertEqual(controller.currentUnreadCount, 1)
        try await controller.markAllRead()
        XCTAssertFalse(controller.state.runs.first { $0.appID == "b" }!.isRead)
        XCTAssertFalse(controller.state.runs.first { $0.appID == "blackcat" }!.isRead)
        XCTAssertEqual(controller.currentUnreadCount, 0)
    }
    func testLegacyJSONAndYAMLDefaultEnabledPreserveVisibilityAndMetadata() throws {
        let repo = try repository()
        var state = AgentXState(); state.blackCatEnabled = false
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
        var apps = json["apps"] as! [[String: Any]]; apps[0].removeValue(forKey: "enabled"); json["apps"] = apps
        let original = try JSONSerialization.data(withJSONObject: json)
        try original.write(to: repo.root.appendingPathComponent("agentx.yaml"))
        let legacy = try repo.load()
        XCTAssertTrue(legacy.apps[0].enabled)
        XCTAssertFalse(legacy.blackCatEnabled)
        try repo.save(legacy)
        XCTAssertEqual(try Data(contentsOf: repo.root.appendingPathComponent("backups/legacy-v1/agentx.json")), original)
        XCTAssertEqual(try repo.load(), legacy)
        try Data("id: blackcat\nname: BlackCat\nkind: blackcat\n".utf8).write(to: repo.root.appendingPathComponent("apps/blackcat/app.yaml"))
        try Data("version: 1\nblackcat: {enabled: false}\n".utf8).write(to: repo.root.appendingPathComponent("agentx.yaml"))
        XCTAssertTrue(try repo.load().apps[0].enabled)
        try Data("version: 1\napps_enabled: []\n".utf8).write(to: repo.root.appendingPathComponent("agentx.yaml"))
        XCTAssertFalse(try repo.load().apps[0].enabled)
    }
    func testDisabledAppFencesAllHostEntrances() async throws {
        let repo = try configured()
        var calls = 0
        let controller = AgentXController(repository: repo, credentials: AgentXTestCredentials(), respond: { _, _, _, _ in calls += 1; return "unexpected" }, autoRefreshCatalogs: false)
        try await controller.setApplicationEnabled("a", enabled: false)
        controller.send("x", instanceID: "a")
        controller.sendConfigurationRequest("x", instanceID: "a")
        controller.previewCharacter("x", instanceID: "a")
        controller.sendUsageRequest("x", instanceID: "a")
        controller.startWorkflow("x", appID: "a")
        XCTAssertTrue(controller.state.runs.isEmpty)
        XCTAssertEqual(calls, 0)
        XCTAssertNotNil(controller.errorMessage)
    }

    func testRejectsMalformedRecognizedManifestSections() throws {
        let repo = try repository(); try repo.save(.init())
        for invalid in ["permissions: {shell: yesplease}", "requires: {providers: wrong}", "ui: {modules: [valid, 3]}"] {
            try Data("id: blackcat\nname: BlackCat\nkind: blackcat\nmanifest: {\(invalid)}\n".utf8).write(to: repo.root.appendingPathComponent("apps/blackcat/app.yaml"))
            XCTAssertThrowsError(try repo.load(), invalid)
        }
    }

    func testMissingCurrentApplicationPersistsEnabledFallback() throws {
        let repo = try configured()
        var state = try repo.load(); state.currentAppID = "missing"; try repo.save(state)
        let controller = AgentXController(repository: repo, credentials: AgentXTestCredentials(), autoRefreshCatalogs: false)
        XCTAssertEqual(controller.selectedAppID, "a")
        XCTAssertEqual(try repo.load().currentAppID, "a")
    }

    func testVersionRetainsStringVersusNumericRepresentation() throws {
        let repo = try repository(); try repo.save(.init())
        for (raw, expected) in [("5", AgentXManifestValue.integer(5)), ("'5'", AgentXManifestValue.string("5"))] {
            try Data("id: blackcat\nname: BlackCat\nkind: blackcat\nversion: \(raw)\n".utf8).write(to: repo.root.appendingPathComponent("apps/blackcat/app.yaml"))
            let state = try repo.load()
            XCTAssertEqual(state.apps[0].version, expected)
            try repo.save(state)
            XCTAssertEqual(try repo.load().apps[0].version, expected)
        }
    }

    func testSingleModeTakesPrecedenceAndCannotSwitchOutsideIt() throws {
        let repo = try configured()
        var state = try repo.load(); state.singleAppID = "b"; state.currentAppID = "a"; try repo.save(state)
        let controller = AgentXController(repository: repo, credentials: AgentXTestCredentials(), autoRefreshCatalogs: false)
        XCTAssertEqual(controller.selectedAppID, "b")
        controller.openApp("a")
        XCTAssertEqual(controller.selectedAppID, "b")
    }
    func testManifestRejectsEscapingFilePermissions() throws {
        let repo = try repository(); try repo.save(.init())
        for path in ["../other", "/private/tmp", "a/../../outside"] {
            try Data("id: blackcat\nname: BlackCat\nkind: blackcat\nmanifest: {permissions: {files: ['\(path)']}}\n".utf8).write(to: repo.root.appendingPathComponent("apps/blackcat/app.yaml"))
            XCTAssertThrowsError(try repo.load())
        }
    }
    func testManifestUnknownLeavesRetainScalarTypesAndQuotedIcon() throws {
        let repo = try repository(); try repo.save(.init())
        try Data("id: blackcat\nname: BlackCat\nkind: blackcat\nmanifest: {ui: {icon: '123'}, future: {quoted: '123', flag: true, number: 123}}\n".utf8).write(to: repo.root.appendingPathComponent("apps/blackcat/app.yaml"))
        let state = try repo.load()
        XCTAssertEqual(state.apps[0].declaredIcon, "123")
        XCTAssertEqual(state.apps[0].manifest?["future"], .object(["quoted": .string("123"), "flag": .bool(true), "number": .integer(123)]))
        try repo.save(state)
        XCTAssertEqual(try repo.load().apps[0].manifest, state.apps[0].manifest)
    }

    func testReloadRejectsUnverifiedStopUntilSuccessfulRetry() async throws {
        let controller = AgentXController(repository: try repository(), credentials: AgentXTestCredentials(), autoRefreshCatalogs: false)
        controller.externalRuntimeStop = { _ in throw AgentXError.unavailable }
        do { try await controller.setApplicationEnabled("blackcat", enabled: false); XCTFail("Hook must fail") } catch {}
        XCTAssertThrowsError(try controller.reloadApplications())
        do { try await controller.setApplicationEnabled("blackcat", enabled: true); XCTFail("Unverified stop must not be erased by enable") } catch {}
        XCTAssertFalse(controller.state.apps[0].enabled)
        guard case .unverified = controller.applicationStopStates["blackcat"] else { return XCTFail("Evidence must remain") }
        controller.externalRuntimeStop = { _ in }
        try await controller.setApplicationEnabled("blackcat", enabled: false)
        XCTAssertNoThrow(try controller.reloadApplications())
        try await controller.setApplicationEnabled("blackcat", enabled: true)
        XCTAssertTrue(controller.state.apps[0].enabled)
    }
    func testExistingEmptyRootNeverResurrectsDefaultApplication() throws {
        for directoryExists in [false, true] {
            let repo = try repository()
            if directoryExists { try FileManager.default.createDirectory(at: repo.root.appendingPathComponent("apps"), withIntermediateDirectories: true) }
            try Data("version: 1\ncurrent_app: removed\n".utf8).write(to: repo.root.appendingPathComponent("agentx.yaml"))
            let loaded = try repo.load()
            XCTAssertTrue(loaded.apps.isEmpty)
            XCTAssertNil(loaded.currentAppID)
            let controller = AgentXController(repository: repo, credentials: AgentXTestCredentials(), autoRefreshCatalogs: false)
            XCTAssertTrue(controller.isLoaded)
            XCTAssertTrue(controller.state.apps.isEmpty)
            XCTAssertEqual(controller.selectedAppID, "")
            XCTAssertEqual(controller.page, .apps)
            XCTAssertNil(try repo.load().currentAppID)
            XCTAssertFalse(FileManager.default.fileExists(atPath: repo.root.appendingPathComponent("apps/blackcat").path))
        }
    }
    func testAbsentBlackCatAllowedButImpersonatedBuiltinRejected() throws {
        let repo = try repository()
        var state = AgentXState(); state.apps = [.init(id: "notes", name: "Notes", kind: .chat)]
        XCTAssertNoThrow(try repo.save(state))
        state.apps = [.init(id: "blackcat", name: "Fake", kind: .chat)]
        XCTAssertThrowsError(try repo.save(state))
        state.apps = [.init(id: "other", name: "Fake", kind: .blackcat)]
        XCTAssertThrowsError(try repo.save(state))
    }
    func testManifestLargeIntegerPreservesExactYAMLAndJSONValues() throws {
        let repo = try repository(); try repo.save(.init())
        for raw in ["9007199254740993", "18446744073709551615", "-9007199254740993"] {
            try Data("id: blackcat\nname: BlackCat\nkind: blackcat\nmanifest: {future: \(raw)}\n".utf8).write(to: repo.root.appendingPathComponent("apps/blackcat/app.yaml"))
            let state = try repo.load()
            let value = try XCTUnwrap(state.apps[0].manifest?["future"])
            XCTAssertEqual(String(decoding: try JSONEncoder().encode(value), as: UTF8.self), raw)
            try repo.save(state)
            XCTAssertEqual(try repo.load().apps[0].manifest?["future"], value)
            let jsonValue = try JSONDecoder().decode(AgentXManifestValue.self, from: Data(raw.utf8))
            XCTAssertEqual(String(decoding: try JSONEncoder().encode(jsonValue), as: UTF8.self), raw)
        }
    }

    func testDeepUnknownYAMLIntegerAndQuotedStringTypesSurviveMerge() throws {
        let repo = try repository(); try repo.save(.init())
        let file = repo.root.appendingPathComponent("apps/blackcat/app.yaml")
        try Data("id: blackcat\nname: BlackCat\nkind: blackcat\nfuture_top: {levels: [{big: 18446744073709551615, quoted: '18446744073709551615', flag: true}]}\nmanifest: {future: {levels: [9007199254740993, '9007199254740993', false]}}\n".utf8).write(to: file)
        let original = try YAMLDecoder().decode([String: AgentXManifestValue].self, from: String(contentsOf: file, encoding: .utf8))
        let state = try repo.load()
        for _ in 0..<2 { try repo.save(state) }
        let saved = try YAMLDecoder().decode([String: AgentXManifestValue].self, from: String(contentsOf: file, encoding: .utf8))
        XCTAssertEqual(saved["future_top"], original["future_top"])
        XCTAssertEqual(saved["manifest"], original["manifest"])
        XCTAssertEqual(try repo.load().apps[0].manifest, state.apps[0].manifest)
    }

    func testExitingDisabledSingleAppRestoresEnabledFallbackAndPersistsTogether() async throws {
        let repo = try configured()
        let controller = AgentXController(repository: repo, credentials: AgentXTestCredentials(), autoRefreshCatalogs: false)
        try controller.setSingleApp("a")
        try await controller.setApplicationEnabled("a", enabled: false)
        XCTAssertEqual(controller.selectedAppID, "")
        try controller.setSingleApp(nil)
        XCTAssertEqual(controller.selectedAppID, "b")
        XCTAssertEqual(controller.state.currentAppID, "b")
        XCTAssertFalse(controller.singleMode)
        let saved = try repo.load()
        XCTAssertNil(saved.singleAppID)
        XCTAssertEqual(saved.currentAppID, "b")
    }

    func testSingleModeSaveFailureKeepsModeAndSelectionUnchanged() throws {
        let repo = try configured()
        let controller = AgentXController(repository: repo, credentials: AgentXTestCredentials(), autoRefreshCatalogs: false)
        let before = controller.state
        let selected = controller.selectedAppID
        let file = repo.root.appendingPathComponent("agentx.yaml")
        let backup = repo.root.appendingPathComponent("settings-before-test.yaml")
        try FileManager.default.moveItem(at: file, to: backup)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertThrowsError(try controller.setSingleApp("b"))
        XCTAssertEqual(controller.state, before)
        XCTAssertEqual(controller.selectedAppID, selected)
        XCTAssertFalse(controller.singleMode)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: backup, to: file)
        XCTAssertEqual(try repo.load(), before)
    }
}
