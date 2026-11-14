import XCTest
@testable import TravelCatApp

@MainActor
final class AgentXPilotSubmissionTests: XCTestCase {
    func testExplicitRetryReusesKeyAndOnlySendsPromptAndInstance() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentXPilotSend-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = AgentXRepository(root: root)
        var state = AgentXState()
        state.apps.append(.init(id: "pilot", name: "Pilot", kind: .chat))
        state.providers = [.init(id: "p", name: "Provider", baseURL: "https://openrouter.ai/api/v1", models: ["m"])]
        state.definitions = [.init(id: "d", name: "Definition", prompt: "system")]
        state.instances = [.init(id: "member", name: "Member", appID: "pilot", definitionID: "d", providerID: "p", model: "m")]
        try repo.save(state)
        let marker: [String: Any] = ["root": root.path, "appID": "pilot", "pi": ["instanceID": "member", "providerID": "p", "model": "m"]]
        try JSONSerialization.data(withJSONObject: marker).write(to: root.appendingPathComponent(".agentxd-pilot.json"))
        // Return an ambiguous server failure after recording a create, as if its reply was lost.
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-B", "-c", #"""
        import http.server, json, pathlib, sys
        root = pathlib.Path(sys.argv[1])
        class Handler(http.server.BaseHTTPRequestHandler):
            saved_key = None
            def log_message(self, *args): pass
            def do_GET(self):
                recovered = dict(id="pilot-run", appID="pilot", instanceID="member", prompt="hello",
                                 status="failed", startedAt=0, isRead=False, response="", revision=4,
                                 stopEvidence="unverified", requiresProcessReview=True)
                body = json.dumps([recovered]).encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            def do_POST(self):
                with (root/"commands").open("a") as stream:
                    stream.write(self.path+"\n")
                key = self.headers.get("Idempotency-Key")
                payload = self.rfile.read(int(self.headers.get("Content-Length", 0)))
                status = 400
                run = dict(id="pilot-run", appID="pilot", instanceID="member", prompt="hello",
                           status="running", startedAt=0, isRead=False, response="", revision=1)
                if self.headers.get("Authorization") == "Bearer local" and key:
                    if self.path == "/v1/apps/pilot/runs" and json.loads(payload) == {"prompt":"hello","instanceId":"member"}:
                        if Handler.saved_key is None:
                            Handler.saved_key = key
                            status = 503
                        elif key == Handler.saved_key:
                            status = 200
                    elif self.path == "/v1/apps/pilot/runs/pilot-run/stop":
                        status = 202
                        run.update(status="cancelling", stopEvidence="pending", revision=2)
                body = json.dumps(run).encode()
                self.send_response(status)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
        server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        (root/".agentxd-endpoint.json").write_text(json.dumps(dict(port=server.server_port,token="local")))
        server.serve_forever()
        """#, root.path]
        try server.run()
        defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: root.appendingPathComponent(".agentxd-endpoint.json").path) {
            try await Task.sleep(for: .milliseconds(25))
        }
        let controller = AgentXController(repository: repo, credentials: AgentXTestCredentials(), respond: { _, _, _, _ in
            XCTFail("service-owned run used local responder")
            return ""
        }, autoRefreshCatalogs: false)
        controller.drafts["member"] = "hello"
        controller.send("hello", instanceID: "member")
        for _ in 0..<100 where controller.errorMessage == nil { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertEqual(controller.drafts["member"], "hello")
        controller.errorMessage = nil
        controller.send("hello", instanceID: "member")
        for _ in 0..<100 where controller.state.runs.isEmpty && controller.errorMessage == nil { try await Task.sleep(for: .milliseconds(25)) }
        let first = try XCTUnwrap(controller.state.runs.first)
        XCTAssertEqual(first.id, "pilot-run")
        XCTAssertEqual(controller.drafts["member"], "")
        controller.cancel(first.id)
        for _ in 0..<100 where controller.state.runs.first?.status == .running { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertEqual(controller.state.runs.first?.status, .cancelling)
        let commands = root.appendingPathComponent("commands")
        let beforeRecovery = try Data(contentsOf: commands)
        await controller.refreshPilotRuns()
        let recovered = try XCTUnwrap(controller.state.runs.first)
        XCTAssertEqual(recovered.revision, 4)
        XCTAssertTrue(recovered.status.terminal)
        XCTAssertTrue(recovered.displayedStatus.contains("Pi 退出未确认"))
        XCTAssertFalse(controller.isInstanceBusy("member"))
        XCTAssertNotNil(controller.pilotReviewNotice(for: "member"))
        XCTAssertNil(controller.pilotReviewNotice(for: "another-member"))
        controller.drafts["member"] = "next"
        controller.send("next", instanceID: "member")
        XCTAssertTrue(controller.errorMessage?.contains("等待进程复核") == true)
        controller.cancel(recovered.id)
        await controller.refreshPilotRuns()
        XCTAssertEqual(controller.drafts["member"], "next")
        XCTAssertEqual(try Data(contentsOf: commands), beforeRecovery)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("apps/pilot/runs/pilot-run.json").path))
    }
}
