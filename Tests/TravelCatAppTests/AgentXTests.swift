import XCTest
@testable import TravelCatApp

@MainActor
final class AgentXTests: XCTestCase {
    func testWorkbenchRegistrationSurvivesSecondStartup() throws {
        let directory = try root()
        let repository = AgentXRepository(root: directory)
        let controller = AgentXController(repository: repository, credentials: AgentXTestCredentials())
        try controller.ensureWorkbenchApp()
        let path = directory.appendingPathComponent("apps/workbench/state/runtime")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let reopened = AgentXController(repository: repository, credentials: AgentXTestCredentials())
        XCTAssertTrue(reopened.isLoaded)
        XCTAssertEqual(reopened.state.apps.first { $0.id == "workbench" }?.kind, .workbench)
    }
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AgentXTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testDefaultBlackCatAndNoPetPreferenceRoundTrip() throws {
        let repository = AgentXRepository(root: try root())
        var state = try repository.load()
        XCTAssertEqual(state.apps.map(\.id), ["blackcat"])
        XCTAssertTrue(state.blackCatEnabled)
        state.blackCatEnabled = false
        try repository.save(state)
        XCTAssertFalse(try repository.load().blackCatEnabled)
        XCTAssertEqual(try repository.load().apps.count, 1)
    }

    func testInvalidReferencesAndPathTraversalDoNotOverwriteState() throws {
        let repository = AgentXRepository(root: try root())
        let state = try repository.load()
        try repository.save(state)
        var invalid = state
        invalid.apps.append(.init(id: "../outside", name: "Escape", kind: .chat))
        XCTAssertThrowsError(try repository.save(invalid))
        invalid = state
        invalid.instances.append(.init(id: "agent", name: "Agent", appID: "missing", definitionID: "missing", providerID: "missing", model: "test"))
        XCTAssertThrowsError(try repository.save(invalid))
        XCTAssertEqual(try repository.load(), state)
    }

    func testCorruptStateAndSymlinkAreRejected() throws {
        let directory = try root()
        let repository = AgentXRepository(root: directory)
        try Data("corrupt".utf8).write(to: directory.appendingPathComponent("agentx.yaml"))
        XCTAssertThrowsError(try repository.load())
        let other = try root()
        try FileManager.default.createSymbolicLink(at: other.appendingPathComponent("manager"), withDestinationURL: directory)
        XCTAssertThrowsError(try AgentXRepository(root: other).save(.init()))
    }

    func testBadgeCountsOnlyUnreadTerminalRunsAndClickRoutesToInbox() {
        var state = AgentXState()
        state.runs = [AgentXRun(id: "1", appID: "blackcat", instanceID: "a", prompt: "hello", status: .running),
                      AgentXRun(id: "2", appID: "blackcat", instanceID: "a", prompt: "hello", status: .completed),
                      AgentXRun(id: "3", appID: "blackcat", instanceID: "a", prompt: "hello", status: .failed, isRead: true)]
        XCTAssertEqual(state.unreadCount, 1)
        XCTAssertEqual(state.dockDestination, .inbox)
        state.runs[1].isRead = true
        XCTAssertEqual(state.unreadCount, 0)
        XCTAssertEqual(state.dockDestination, .overview)
    }

    func testRestartConvertsInFlightRunToActionableFailure() throws {
        let repository = AgentXRepository(root: try root())
        var state = AgentXState()
        state.runs = [.init(id: "1", appID: "blackcat", instanceID: "a", prompt: "hello", status: .running)]
        try repository.save(state)
        let controller = AgentXController(repository: repository, credentials: AgentXTestCredentials())
        XCTAssertEqual(controller.state.runs.first?.status, .failed)
        XCTAssertEqual(controller.state.unreadCount, 1)
        XCTAssertEqual(try repository.load().runs.first?.status, .failed)
    }

    func testChatRequestUsesSelectedModelAndRejectsUnsafeEndpoint() throws {
        let provider = AgentXProvider(id: "p", name: "Local", baseURL: "http://127.0.0.1:1234/v1", models: ["model"])
        let request = try AgentXChatClient.request(provider: provider, model: "model", secret: "test-secret", messages: [.init(role: "user", content: "hi")])
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:1234/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-secret")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "model")
        var unsafe = provider
        unsafe.baseURL = "http://example.com/v1"
        XCTAssertThrowsError(try AgentXChatClient.request(provider: unsafe, model: "model", secret: "secret", messages: []))
    }

    func testConfigurationAndCompletedChatStayWithOriginalApplication() async throws {
        let repository = AgentXRepository(root: try root())
        let credentials = AgentXTestCredentials()
        let controller = AgentXController(repository: repository, credentials: credentials,
            respond: { _, _, _, messages in
                XCTAssertEqual(messages.first?.content, "Be helpful")
                return "Real test response"
            })
        try controller.addProvider(name: "Local", address: "http://localhost:1234/v1", models: "model", secret: "private-test-key")
        try controller.addDefinition(name: "Writer", prompt: "Be helpful")
        try controller.addApp(name: "Workspace")
        let app = try XCTUnwrap(controller.state.apps.last)
        try controller.addInstance(name: "Writer", appID: app.id, definitionID: controller.state.definitions[0].id,
                                   providerID: controller.state.providers[0].id, model: "model")
        let instance = try XCTUnwrap(controller.state.instances.first)
        controller.send("Hello", instanceID: instance.id)
        controller.selectedAppID = "blackcat"
        await controller.waitForRuns()
        XCTAssertEqual(controller.state.runs.first?.appID, app.id)
        XCTAssertEqual(controller.state.runs.first?.response, "Real test response")
        XCTAssertEqual(controller.state.runs.first?.status, .completed)
        XCTAssertEqual(controller.state.unreadCount, 1)
        try controller.markAllRead()
        XCTAssertEqual(controller.state.unreadCount, 0)
        let data = try Data(contentsOf: repository.root.appendingPathComponent("agentx.yaml"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private-test-key"))
        XCTAssertEqual(try repository.load(), controller.state)
    }

    func testCancelProducesCancelledStateAndNoFalseCompletion() async throws {
        let repository = AgentXRepository(root: try root())
        var state = AgentXState()
        state.providers = [.init(id: "p", name: "P", baseURL: "https://example.com/v1", models: ["m"])]
        state.definitions = [.init(id: "d", name: "D", prompt: "Hi")]
        state.instances = [.init(id: "i", name: "I", appID: "blackcat", definitionID: "d", providerID: "p", model: "m")]
        try repository.save(state)
        let controller = AgentXController(repository: repository, credentials: AgentXTestCredentials(), respond: { _, _, _, _ in
            try await Task.sleep(for: .seconds(30))
            return "Should not finish"
        })
        controller.send("hi", instanceID: "i")
        controller.cancelAll()
        await controller.waitForRuns()
        XCTAssertEqual(controller.state.runs.first?.status, .cancelled)
        XCTAssertEqual(controller.state.runs.first?.response, "")
    }

    func testProviderEditPreservesSecretAndRejectsRemovingReferencedModel() throws {
        let repository = AgentXRepository(root: try root())
        let credentials = AgentXTestCredentials()
        let controller = AgentXController(repository: repository, credentials: credentials)
        try controller.addProvider(name: "Old", address: "https://example.com/v1", models: "m", secret: "original")
        try controller.addDefinition(name: "D", prompt: "Help")
        let provider = try XCTUnwrap(controller.state.providers.first)
        try controller.addInstance(name: "I", appID: "blackcat", definitionID: controller.state.definitions[0].id, providerID: provider.id, model: "m")
        try controller.updateProvider(id: provider.id, name: "New", address: "https://example.com/v1", models: "m,new", secret: "")
        XCTAssertEqual(credentials.secrets[provider.credentialID], "original")
        XCTAssertEqual(controller.state.providers[0].name, "New")
        XCTAssertThrowsError(try controller.updateProvider(id: provider.id, name: "Bad", address: "https://example.com/v1", models: "new", secret: "replacement"))
        XCTAssertEqual(credentials.secrets[provider.credentialID], "original")
        XCTAssertEqual(controller.state.providers[0].name, "New")
    }

    func testDisablingPetPreservesAppsAndDockReopenDoesNotClearUnread() throws {
        let controller = AgentXController(repository: AgentXRepository(root: try root()), credentials: AgentXTestCredentials())
        try controller.addApp(name: "Writing")
        let apps = controller.state.apps
        try controller.setBlackCatEnabled(false)
        XCTAssertEqual(controller.state.apps, apps)
        controller.openFromDock(travelPending: true)
        XCTAssertEqual(controller.page, .inbox)
        controller.openFromDock()
        XCTAssertEqual(controller.page, .chat)
        XCTAssertEqual(controller.currentApp?.name, "Writing")
    }

    func testCorruptConfigurationCannotBeOverwrittenThroughController() throws {
        let directory = try root()
        let original = Data("user-edited: unsupported-yaml".utf8)
        let file = directory.appendingPathComponent("agentx.yaml")
        try original.write(to: file)
        let controller = AgentXController(repository: AgentXRepository(root: directory), credentials: AgentXTestCredentials())
        XCTAssertFalse(controller.isLoaded)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertThrowsError(try controller.addApp(name: "New"))
        XCTAssertThrowsError(try controller.setBlackCatEnabled(false))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testSingleApplicationStartupAndIndependentPetPreference() throws {
        let repository = AgentXRepository(root: try root())
        let controller = AgentXController(repository: repository, credentials: AgentXTestCredentials())
        try controller.addApp(name: "Independent")
        let id = try XCTUnwrap(controller.state.apps.last?.id)
        try controller.setSingleApp(id)
        try controller.setBlackCatEnabled(false)
        let reopened = AgentXController(repository: repository, credentials: AgentXTestCredentials())
        XCTAssertTrue(reopened.singleMode)
        XCTAssertEqual(reopened.currentApp?.id, id)
        XCTAssertEqual(reopened.page, .chat)
        XCTAssertFalse(reopened.state.blackCatEnabled)
        try reopened.setSingleApp(nil)
        XCTAssertFalse(reopened.singleMode)
        XCTAssertFalse(reopened.state.blackCatEnabled)
    }

    func testRootURLAndExactEndpointAddressRules() throws {
        var provider = AgentXProvider(id: "p", name: "P", baseURL: "https://example.com", models: ["m"])
        XCTAssertEqual(try AgentXChatClient.request(provider: provider, model: "m", secret: nil, messages: []).url?.path, "/v1/chat/completions")
        provider.baseURL = "https://example.com/custom/messages#"
        XCTAssertEqual(try AgentXChatClient.request(provider: provider, model: "m", secret: nil, messages: []).url?.path, "/custom/messages")
        for address in ["https://user:secret@example.com/v1", "https://example.com/v1?api_key=secret", "file:///tmp/request", "http://192.168.1.1/v1"] {
            provider.baseURL = address
            XCTAssertThrowsError(try AgentXChatClient.request(provider: provider, model: "m", secret: nil, messages: []))
        }
    }
}

@MainActor
final class AgentXTestCredentials: TravelServiceCredentialStoring {
    var secrets: [String: String] = [:]
    func read(id: String) throws -> String? { secrets[id] }
    func save(_ secret: String?, id: String) throws { secrets[id] = secret }
}
