import XCTest
@testable import TravelCatApp

@MainActor
final class AgentXTextRuntimeRoutingTests: XCTestCase {
    private let routerURL = "https://openrouter.ai/api/v1"
    private let localURL = "http://127.0.0.1:12345/v1"

    private func controller(runtime: String?, endpoint: String, requires: String? = nil,
                            serviceProtocol: AgentXServiceProtocol = .openAICompatible,
                            key: String? = "fixture-key", nativeReply: String = "native reply") throws -> AgentXController {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("AgentXTextRouting-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let runner = root.appendingPathComponent("runner.sh")
        try """
        /bin/cat >/dev/null
        if [ "$1" = "--stream-loopback" ]; then printf '%s\\n' '{"event":"text","text":"pi reply"}'; fi
        printf '%s\\n' '{"version":1,"ok":true,"text":"pi reply"}'
        """.write(to: runner, atomically: true, encoding: .utf8)
        let repository = AgentXRepository(root: root.appendingPathComponent("agentx"))
        var state = AgentXState()
        state.apps[0].runtime = runtime
        if let requires { state.apps[0].manifest = ["requires": .object(["runtime": .string(requires)])] }
        state.providers = [.init(id: "p", name: "Provider", baseURL: endpoint, models: ["m"], serviceProtocol: serviceProtocol)]
        state.definitions = [.init(id: "role", name: "Role", prompt: "Be brief")]
        state.instances = [.init(id: "member", name: "Member", appID: "blackcat", definitionID: "role", providerID: "p", model: "m")]
        try repository.save(state)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: repository.root.path)
        let usesPi = runtime == "pi-agent-core" || ((runtime == nil || runtime == "host-text") && endpoint == routerURL)
        if usesPi {
            try JSONSerialization.data(withJSONObject: ["version": 1, "applications": ["blackcat": ["provider": "p", "model": "m", "max_output_tokens": 23, "max_request_bytes": 1048576, "timeout_seconds": 3]]]).write(to: repository.root.appendingPathComponent("manager/gateway.yaml"))
        }
        let credentials = AgentXTestCredentials()
        try credentials.save(key, id: state.providers[0].credentialID)
        let catalog = AgentXProviderCatalog { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), key.map { "Bearer " + $0 })
            let data = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": nativeReply]]]])
            return (data, 200)
        }
        let pi = AgentXPiRuntime(nodeURL: URL(fileURLWithPath: "/bin/sh"), runnerURL: runner, timeout: 3)
        let controller = AgentXController(repository: repository, credentials: credentials, catalog: catalog,
                                          autoRefreshCatalogs: false, piRuntime: pi)
        let workflow = AgentXWorkflowDefinition(name: "Flow", steps: [.init(name: "First", instanceID: "member", instruction: "Write")])
        try controller.saveWorkflowDraft(appID: "blackcat", definition: workflow, expectedDraft: nil)
        try controller.publishWorkflow(appID: "blackcat")
        return controller
    }

    func testChatAndWorkflowSelectAndPersistTheRuntimeThatActuallyAnswered() async throws {
        let cases: [(String?, String, AgentXTextRuntime)] = [
            (nil, routerURL, .pi), (nil, localURL, .nativeHTTP),
            ("host-text", routerURL, .pi), ("host-text", localURL, .nativeHTTP),
            ("pi-agent-core", localURL, .pi), ("native-http", routerURL, .nativeHTTP)
        ]
        for (declaration, endpoint, expected) in cases {
            let controller = try controller(runtime: declaration, endpoint: endpoint)
            controller.send("Hello", instanceID: "member")
            await controller.waitForRuns()
            controller.startWorkflow("Hello", appID: "blackcat")
            await controller.waitForRuns()
            let runs = try controller.repository.load().runs
            let reply = expected == .pi ? "pi reply" : "native reply"
            XCTAssertEqual(runs.map(\.status), [.completed, .completed], controller.errorMessage ?? "no controller error")
            XCTAssertEqual(runs.map(\.response), [reply, reply])
            XCTAssertEqual(runs.map(\.runtimeCore), [expected.rawValue, expected.rawValue])
            XCTAssertEqual(runs.last?.workflowSteps?.first?.runtimeCore, expected.rawValue)
        }
    }

    func testLegacyWorkflowWithUnconfinedPiMemberIsRejectedBeforeAnyStep() async throws {
        let controller = try controller(runtime: "host-text", endpoint: localURL)
        try controller.addProvider(name: "Router", address: routerURL, models: "m", secret: "fixture-key")
        let router = try XCTUnwrap(controller.state.providers.first { $0.name == "Router" })
        try controller.addInstance(name: "Reviewer", appID: "blackcat", definitionID: "role", providerID: router.id, model: "m")
        let reviewer = try XCTUnwrap(controller.state.instances.first { $0.name == "Reviewer" })
        let original = try XCTUnwrap(controller.state.apps.first?.workflow?.draft)
        var draft = original
        draft.steps.append(.init(name: "Review", instanceID: reviewer.id, instruction: "Review the draft"))
        try controller.saveWorkflowDraft(appID: "blackcat", definition: draft, expectedDraft: original)
        try controller.publishWorkflow(appID: "blackcat")

        controller.startWorkflow("Hello", appID: "blackcat")
        await controller.waitForRuns()
        XCTAssertTrue(try controller.repository.load().runs.isEmpty)
        XCTAssertNotNil(controller.errorMessage)
        let app = try XCTUnwrap(controller.state.apps.first)
        let permission = try AgentXExecutionPolicy(root: controller.repository.root, application: app, provider: router)
        XCTAssertEqual(try permission.events().last?["operation"] as? String, "runtime.gateway")
    }

    func testUnknownRuntimeConflictAndUnsupportedPiProtocolRejectBothEntries() async throws {
        let cases: [(String?, String?, AgentXServiceProtocol)] = [
            ("custom-engine", nil, .openAICompatible),
            ("pi-agent-core", "native-http", .openAICompatible),
            ("pi-agent-core", nil, .responses)
        ]
        for (declaration, requires, kind) in cases {
            let controller = try controller(runtime: declaration, endpoint: localURL, requires: requires, serviceProtocol: kind)
            controller.send("Hello", instanceID: "member")
            await controller.waitForRuns()
            XCTAssertNotNil(controller.errorMessage)
            controller.errorMessage = nil
            controller.startWorkflow("Hello", appID: "blackcat")
            await controller.waitForRuns()
            XCTAssertNotNil(controller.errorMessage)
            XCTAssertTrue(try controller.repository.load().runs.isEmpty)
        }
    }

    func testExplicitNativeOpenRouterRequiresKeyAndSuppressesReflectedCredential() async throws {
        for key in [nil, "fixture-key"] {
            let controller = try controller(runtime: "native-http", endpoint: routerURL, key: key, nativeReply: "fixture-key")
            controller.send("Hello", instanceID: "member")
            await controller.waitForRuns()
            let run = try XCTUnwrap(controller.repository.load().runs.last)
            XCTAssertEqual(run.status, .failed)
            XCTAssertEqual(run.runtimeCore, "native-http")
            XCTAssertTrue(run.response.isEmpty)
            XCTAssertFalse(run.failure?.contains("fixture-key") == true)
        }
    }
    func testConfiguredGatewayNeverFallsBackToDirectChatOrWorkflow() async throws {
        for runtime in ["native-http", "pi-agent-core"] {
            for file in ["gateway.yaml", "gateway-budget.yaml"] {
                let controller = try controller(runtime: runtime, endpoint: localURL)
                let manager = controller.repository.root.appendingPathComponent("manager")
                try FileManager.default.createDirectory(at: manager, withIntermediateDirectories: true)
                try "invalid: true".write(to: manager.appendingPathComponent(file), atomically: true, encoding: .utf8)
                controller.send("Hello", instanceID: "member")
                await controller.waitForRuns()
                XCTAssertNotNil(controller.errorMessage)
                controller.errorMessage = nil
                controller.startWorkflow("Hello", appID: "blackcat")
                await controller.waitForRuns()
                XCTAssertNotNil(controller.errorMessage)
                XCTAssertTrue(try controller.repository.load().runs.isEmpty)
            }
        }
    }

    func testWorkflowRechecksGatewayPolicyBeforeEachLegacyStep() async throws {
        let original = try controller(runtime: "native-http", endpoint: localURL)
        let root = original.repository.root
        var calls = 0
        let controller = AgentXController(repository: original.repository, credentials: AgentXTestCredentials(), respond: { _, _, _, _ in
            calls += 1
            try "invalid: true".write(to: root.appendingPathComponent("manager/gateway.yaml"), atomically: true, encoding: .utf8)
            return "first reply"
        }, autoRefreshCatalogs: false)
        let current = try XCTUnwrap(controller.state.apps.first?.workflow?.draft)
        var draft = current
        draft.steps.append(.init(name: "Second", instanceID: "member", instruction: "Review"))
        try controller.saveWorkflowDraft(appID: "blackcat", definition: draft, expectedDraft: current)
        try controller.publishWorkflow(appID: "blackcat")
        controller.startWorkflow("Hello", appID: "blackcat")
        await controller.waitForRuns()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(controller.state.runs.last?.status, .failed)
        XCTAssertEqual(controller.state.runs.last?.workflowSteps?.map(\.status), [.completed, .failed])
    }

}
