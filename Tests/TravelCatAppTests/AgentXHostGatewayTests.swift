import XCTest
@testable import TravelCatApp

@MainActor
final class AgentXHostGatewayTests: XCTestCase {
    private struct Fixture {
        let controller: AgentXController
        let root: URL
        let calls: URL
    }
    private func fixture(runtime: String = "native-http", limit: String = "0.2", realPi: (URL, URL)? = nil) async throws -> Fixture {
        var root = FileManager.default.temporaryDirectory.appendingPathComponent("HostGateway-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let resolved = try XCTUnwrap(realpath(root.path, nil))
        root = URL(fileURLWithPath: String(cString: resolved)); free(resolved)
        let cleanupRoot = root
        addTeardownBlock { try? FileManager.default.removeItem(at: cleanupRoot) }
        let server = root.appendingPathComponent("server.py"), port = root.appendingPathComponent("port"), calls = root.appendingPathComponent("calls.json")
        try #"""
        from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
        from pathlib import Path
        import json, time
        root = Path(__file__).parent
        calls = []
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                calls.append({'authorized': self.headers.get('Authorization') == 'Bearer host-fixture-key', 'limit': body.get('max_tokens')})
                (root / 'calls.json').write_text(json.dumps(calls))
                self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.end_headers()
                if any(m['content'] == 'hold' for m in body['messages']):
                    time.sleep(10); return
                frames = [dict(choices=[dict(index=0, delta=dict(content='gateway reply'))]),
                          dict(choices=[dict(index=0, delta={}, finish_reason='stop')]),
                          dict(choices=[], usage=dict(prompt_tokens=11, completion_tokens=3))]
                for frame in frames:
                    self.wfile.write(('data: ' + json.dumps(frame) + '\n\n').encode())
                    self.wfile.flush()
                self.wfile.write(b'data: [DONE]\n\n'); self.wfile.flush()
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        (root / 'port').write_text(str(server.server_port))
        server.serve_forever()
        """#.write(to: server, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [server.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        addTeardownBlock { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: port.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let number = try String(contentsOf: port, encoding: .utf8)
        let repository = AgentXRepository(root: root)
        var state = AgentXState()
        state.apps[0].runtime = runtime
        state.apps[0].manifest = ["permissions": .object(["network": .array([.string("configured-provider")]), "files": .array([.string("self")])])]
        state.providers = [.init(id: "p", name: "P", baseURL: "http://127.0.0.1:\(number)/v1", models: ["m"],
            modelSelection: .init(models: [.init(id: "m", enabled: true, contextLength: 100)]))]
        state.definitions = [.init(id: "role", name: "Role", prompt: "Be brief")]
        state.instances = [.init(id: "member", name: "Member", appID: "blackcat", definitionID: "role", providerID: "p", model: "m")]
        try repository.save(state)
        try JSONSerialization.data(withJSONObject: ["version": 1, "applications": ["blackcat": ["provider": "p", "model": "m", "max_output_tokens": 23, "max_request_bytes": 1048576, "timeout_seconds": 5]]]).write(to: root.appendingPathComponent("manager/gateway.yaml"))
        try JSONSerialization.data(withJSONObject: ["version": 1, "currency": "USD", "time_zone": "Asia/Shanghai", "daily_limit": limit,
            "prices": ["p": ["m": ["input_per_token": "0.001", "output_per_token": "0.002", "source": "fixture", "revision": "v1"]]]]).write(to: root.appendingPathComponent("manager/gateway-budget.yaml"))
        let credentials = AgentXTestCredentials()
        try credentials.save("host-fixture-key", id: state.providers[0].credentialID)
        // A process fixture verifies Pi's stdin contract without depending on an installed app.
        let runner = root.appendingPathComponent("runner.sh")
        try #"""
        set -eu
        payload=$(/bin/cat)
        base=$(printf '%s' "$payload" | /usr/bin/plutil -extract baseURL raw -o - -)
        token=$(printf '%s' "$payload" | /usr/bin/plutil -extract gatewayToken raw -o - -)
        messages=$(printf '%s' "$payload" | /usr/bin/plutil -extract messages json -o - -)
        body=$(printf '{"model":"m","stream":true,"messages":%s}' "$messages")
        endpoint=${base#http://127.0.0.1:}
        port=${endpoint%%/*}
        path=/${endpoint#*/}/chat/completions
        length=$(printf '%s' "$body" | /usr/bin/wc -c | /usr/bin/tr -d ' ')
        exec 3<>/dev/tcp/127.0.0.1/$port
        printf 'POST %s HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer %s\r\nContent-Type: application/json\r\nContent-Length: %s\r\n\r\n%s' "$path" "$token" "$length" "$body" >&3
        output=$(/bin/cat <&3)
        exec 3>&-
        printf '%s' "$output" | /usr/bin/grep -q 'gateway reply'
        printf '%s\n' '{"event":"text","text":"gateway reply"}' '{"version":1,"ok":true,"text":"gateway reply"}'
        """#.write(to: runner, atomically: true, encoding: .utf8)
        let pi = AgentXPiRuntime(nodeURL: realPi?.0 ?? URL(fileURLWithPath: "/bin/sh"), runnerURL: realPi?.1 ?? runner, ledgerRoot: root)
        let controller = AgentXController(repository: repository, credentials: credentials, autoRefreshCatalogs: false, piRuntime: pi)
        return Fixture(controller: controller, root: root, calls: calls)
    }
    private func calls(_ fixture: Fixture) throws -> [[String: Any]] {
        guard FileManager.default.fileExists(atPath: fixture.calls.path) else { return [] }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.calls)) as? [[String: Any]])
    }
    func testNativeAndPiChatUseGatewayAndSettleSharedBudget() async throws {
        for runtime in ["native-http", "pi-agent-core"] {
            let f = try await fixture(runtime: runtime), controller = f.controller
            controller.send("Hello", instanceID: "member")
            await controller.waitForRuns()
            let run = try XCTUnwrap(controller.state.runs.last, controller.errorMessage ?? "missing run")
            XCTAssertEqual(run.status, .completed, run.failure ?? "")
            XCTAssertEqual(run.response, "gateway reply")
            XCTAssertEqual(run.runtimeCore, runtime)
            XCTAssertEqual(try controller.gatewayBudget.receipt(appID: "blackcat", runID: run.id)?["actual"] as? String, "0.017")
            XCTAssertEqual(try calls(f).count, 1)
            XCTAssertEqual(try calls(f).first?["authorized"] as? Bool, true)
            XCTAssertEqual(try calls(f).first?["limit"] as? Int, 23)
            if runtime == "pi-agent-core" {
                XCTAssertTrue(try AgentXPiProcessLedger(root: f.root).confirmedExited(owner: XCTUnwrap(AgentXStopProcessIdentity.read(getpid())), runID: run.id))
            }
        }
    }
    func testWorkflowBillsEachStepAndStopsBeforeOverBudgetSubmission() async throws {
        let f = try await fixture(limit: "0.16"), controller = f.controller
        let workflow = AgentXWorkflowDefinition(name: "Flow", steps: [
            .init(name: "First", instanceID: "member", instruction: "Write"),
            .init(name: "Second", instanceID: "member", instruction: "Review")])
        try controller.saveWorkflowDraft(appID: "blackcat", definition: workflow, expectedDraft: nil)
        try controller.publishWorkflow(appID: "blackcat")
        controller.startWorkflow("Hello", appID: "blackcat")
        await controller.waitForRuns()
        let run = try XCTUnwrap(controller.state.runs.last, controller.errorMessage ?? "missing run")
        XCTAssertEqual(run.status, .failed)
        XCTAssertEqual(run.workflowSteps?.map(\.status), [.completed, .failed])
        XCTAssertTrue(run.failure?.contains("预算") == true)
        XCTAssertTrue(run.workflowSteps?.last?.failure?.contains("预算") == true)
        XCTAssertEqual(try calls(f).count, 1)
        let step = try XCTUnwrap(run.workflowSteps?.first?.runID)
        XCTAssertEqual(try controller.gatewayBudget.receipt(appID: "blackcat", runID: step)?["actual"] as? String, "0.017")
        XCTAssertNil(try controller.gatewayBudget.receipt(appID: "blackcat", runID: run.id))
    }
    func testCancellationKeepsReservationAndDeletedGatewayCannotFallback() async throws {
        let f = try await fixture(), controller = f.controller
        controller.send("hold", instanceID: "member")
        for _ in 0..<300 {
            if try !calls(f).isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let run = try XCTUnwrap(controller.state.runs.last, controller.errorMessage ?? "missing run")
        XCTAssertEqual(try calls(f).count, 1)
        controller.cancel(run.id)
        await controller.waitForRuns()
        XCTAssertEqual(controller.state.runs.last?.status, .cancelled)
        XCTAssertEqual(try controller.gatewayBudget.receipt(appID: "blackcat", runID: run.id)?["held"] as? String, "0.146")
        controller.send("denied", instanceID: "member")
        await controller.waitForRuns()
        XCTAssertEqual(controller.state.runs.last?.status, .failed)
        XCTAssertTrue(controller.state.runs.last?.failure?.contains("预算") == true)
        XCTAssertEqual(try calls(f).count, 1)
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("manager/gateway.yaml"))
        let count = controller.state.runs.count
        controller.send("no fallback", instanceID: "member")
        await controller.waitForRuns()
        XCTAssertEqual(controller.state.runs.count, count)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertEqual(try calls(f).count, 1)
    }
    func testRealPiGatewayWorkflowWhenRuntimeIsExplicitlyProvided() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let node = environment["AGENTX_TEST_PI_NODE"], let runner = environment["AGENTX_TEST_PI_RUNNER"] else {
            throw XCTSkip("Real Pi acceptance requires explicit disposable runtime paths")
        }
        let f = try await fixture(runtime: "pi-agent-core", realPi: (URL(fileURLWithPath: node), URL(fileURLWithPath: runner)))
        let controller = f.controller
        let workflow = AgentXWorkflowDefinition(name: "Flow", steps: [
            .init(name: "First", instanceID: "member", instruction: "Write"),
            .init(name: "Second", instanceID: "member", instruction: "Review")])
        try controller.saveWorkflowDraft(appID: "blackcat", definition: workflow, expectedDraft: nil)
        try controller.publishWorkflow(appID: "blackcat")
        controller.startWorkflow("Hello", appID: "blackcat")
        await controller.waitForRuns()
        let run = try XCTUnwrap(controller.state.runs.last, controller.errorMessage ?? "missing run")
        XCTAssertEqual(run.status, .completed, run.failure ?? "")
        XCTAssertEqual(run.workflowSteps?.map(\.status), [.completed, .completed])
        XCTAssertEqual(run.response, "gateway reply")
        XCTAssertEqual(try calls(f).count, 2)
        for step in run.workflowSteps ?? [] {
            let id = try XCTUnwrap(step.runID)
            XCTAssertEqual(try controller.gatewayBudget.receipt(appID: "blackcat", runID: id)?["actual"] as? String, "0.017")
        }
        XCTAssertEqual(try controller.gatewayBudget.summary()["spent"] as? String, "0.034")
        XCTAssertTrue(try AgentXPiProcessLedger(root: f.root).confirmedExited(owner: XCTUnwrap(AgentXStopProcessIdentity.read(getpid())), runID: run.id))
    }

    func testSharedBudgetReservationFromAnotherAppBlocksController() async throws {
        let f = try await fixture(), controller = f.controller
        let provider = try XCTUnwrap(controller.state.providers.first)
        try controller.gatewayBudget.reserve(appID: "another-app", runID: "managed-run", provider: provider, model: "m", maxOutputTokens: 23)
        controller.send("Hello", instanceID: "member")
        await controller.waitForRuns()
        XCTAssertEqual(controller.state.runs.last?.status, .failed)
        XCTAssertTrue(controller.state.runs.last?.failure?.contains("预算") == true)
        XCTAssertEqual(try calls(f).count, 0)
    }

}
