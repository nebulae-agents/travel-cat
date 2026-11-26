import Foundation
import Testing
import Darwin
@testable import TravelCatApp

@MainActor
struct AgentXPiRuntimeTests {
    private let provider = AgentXProvider(id: "router", name: "Router", baseURL: "https://openrouter.ai/api/v1", models: ["new/model"])
    private let messages = [AgentXMessage(role: "user", content: "hello")]
    private func fixture(_ script: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-runtime-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try script.write(to: directory.appendingPathComponent("runner.sh"), atomically: true, encoding: .utf8)
        return directory
    }
    private func runtime(_ directory: URL, timeout: TimeInterval = 2) -> AgentXPiRuntime {
        AgentXPiRuntime(nodeURL: URL(fileURLWithPath: "/bin/sh"), runnerURL: directory.appendingPathComponent("runner.sh"), timeout: timeout)
    }
    @Test func fastCompletedChildPersistsReapedReceiptForItsRun() async throws {
        let directory = try fixture("/bin/cat >/dev/null; printf '%s' '{\"version\":1,\"ok\":true,\"text\":\"fast\"}'")
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try #require(AgentXStopProcessIdentity.read(getpid()))
        let instance = AgentXPiRuntime(nodeURL: URL(fileURLWithPath: "/bin/sh"), runnerURL: directory.appendingPathComponent("runner.sh"), ledgerRoot: directory)
        for _ in 0..<12 {
            let answer = try await AgentXPiExecutionContext.$runID.withValue("fast-run") {
                try await instance.respond(provider: provider, model: "new/model", secret: "key", messages: messages)
            }
            #expect(answer == "fast")
        }
        let ledger = AgentXPiProcessLedger(root: directory)
        #expect(try ledger.confirmedExited(owner: owner, runID: "fast-run"))
        #expect(try !ledger.confirmedExited(owner: owner, runID: "other-run"))
    }
    @Test func pipeCarriesCredentialsAndMetadataWithoutArgumentsOrEnvironment() async throws {
        let directory = try fixture(#"""
        payload=$(/bin/cat)
        [ "$#" = 0 ] || exit 9
        case "$payload" in *'private-fixture-key'*) ;; *) exit 8;; esac
        case "$payload" in *'"contextLength":131072'*) ;; *) exit 7;; esac
        case "$payload" in *'new'*'model'*) ;; *) exit 6;; esac
        case "$(/usr/bin/env)" in *NODE_OPTIONS*|*OPENROUTER*|*HTTP_PROXY*|*private-fixture-key*) exit 5;; esac
        printf '%s' '{"version":1,"ok":true,"text":"confirmed"}'
        """#)
        defer { try? FileManager.default.removeItem(at: directory) }
        var selected = provider
        selected.modelSelection = .init(models: [.init(id: "new/model", contextLength: 131072)])
        let result = try await runtime(directory).respond(provider: selected, model: "new/model", secret: "private-fixture-key", messages: messages)
        #expect(result == "confirmed")
    }
    @Test func streamingDeliversBeforeExitAndDrainsFinalBufferedRecords() async throws {
        let directory = try fixture(#"""
        [ "$1" = "--stream-loopback" ] || exit 1
        /bin/cat >/dev/null
        printf '%s' '{"event":"text",'
        printf '%s\n' '"text":"一"}'
        while [ ! -f acknowledged ]; do /bin/sleep 0.01; done
        printf '%s\n' '{"event":"text","text":"二"}' '{"event":"usage","input":9,"output":2}' '{"version":1,"ok":true,"text":"一二"}'
        """#)
        defer { try? FileManager.default.removeItem(at: directory) }
        let instance = runtime(directory)
        let local = AgentXProvider(id: "loop", name: "Loop", baseURL: "http://127.0.0.1:1/v1", models: ["model"])
        let payload = try instance.prepare(provider: local, model: "model", secret: nil, messages: messages)
        let adapter: any AgentXRunAdapter = instance
        #expect(adapter.runtimeCore == "pi-agent-core")
        var events = [String]()
        let answer = try await adapter.execute(runID: "stream-test", payload: payload) { progress in
            switch progress {
            case .text(let text):
                events.append(text)
                if events.count == 1 { try Data().write(to: directory.appendingPathComponent("acknowledged")) }
            case .usage(let input, let output):
                events.append("\(input)/\(output)")
            }
        }
        #expect(events == ["一", "二", "9/2"])
        #expect(answer == "一二")
    }

    @Test func streamingChecksBothEndpointAndCredentialBeforeLaunching() async throws {
        let directory = try fixture("touch launched")
        defer { try? FileManager.default.removeItem(at: directory) }
        let instance = runtime(directory)
        let local = AgentXProvider(id: "local", name: "Loop", baseURL: "http://127.0.0.1:1/v1", models: ["model"])
        for (endpoint, pipeSecret, explicitSecret) in [(provider, "test-key", ""), (local, "test-key", ""), (local, "", "test-key")] {
            let payload = try instance.prepare(provider: endpoint, model: "model", secret: pipeSecret, messages: messages)
            await #expect(throws: AgentXPiRuntimeError.invalidRequest) {
                try await instance.respond(payload: payload, secret: explicitSecret) { _ in Issue.record("Unexpected progress") }
            }
        }
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("launched").path))
    }

    @Test func streamingCallbackFailureReapsChildAndDropsQueuedProgress() async throws {
        let directory = try fixture(#"""
        trap '' TERM
        /bin/cat >/dev/null
        printf '%s' $$ > child.pid
        printf '%s\n' '{"event":"text","text":"first"}' '{"event":"text","text":"second"}'
        while :; do :; done
        """#)
        defer { try? FileManager.default.removeItem(at: directory) }
        let instance = runtime(directory)
        let local = AgentXProvider(id: "loop", name: "Loop", baseURL: "http://127.0.0.1:1/v1", models: ["model"])
        let payload = try instance.prepare(provider: local, model: "model", secret: nil, messages: messages)
        var calls = 0
        struct JournalFailure: Error {}
        await #expect(throws: JournalFailure.self) {
            try await instance.respond(payload: payload, secret: nil) { _ in
                calls += 1
                throw JournalFailure()
            }
        }
        #expect(calls == 1)
        let pid = try #require(Int32(String(contentsOf: directory.appendingPathComponent("child.pid"), encoding: .utf8)))
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test func invalidProtocolAndNonzeroExitAreGenericErrors() async throws {
        for script in ["/bin/cat >/dev/null; printf 'private-fixture-key'", "/bin/cat >/dev/null; printf '%s' '{\"version\":1,\"ok\":true,\"text\":\"bad\"}'; exit 4", "/bin/cat >/dev/null; printf '%s' '{\"version\":2,\"ok\":true,\"text\":\"bad\"}'", "/bin/cat >/dev/null; printf '%s' '{\"version\":1,\"ok\":false,\"code\":\"private-fixture-key\"}'"] {
            let directory = try fixture(script)
            defer { try? FileManager.default.removeItem(at: directory) }
            do {
                _ = try await runtime(directory).respond(provider: provider, model: "new/model", secret: "private-fixture-key", messages: messages)
                Issue.record("Invalid result unexpectedly succeeded")
            } catch {
                #expect(error is AgentXPiRuntimeError)
                #expect(!error.localizedDescription.contains("private-fixture-key"))
            }
        }
    }
    @Test func missingExecutableAndCredentialFailBeforeLaunch() async throws {
        let missing = AgentXPiRuntime(nodeURL: URL(fileURLWithPath: "/missing-node"), runnerURL: URL(fileURLWithPath: "/missing-runner"))
        await #expect(throws: AgentXPiRuntimeError.missingCredential) {
            try await missing.respond(provider: provider, model: "new/model", secret: nil, messages: messages)
        }
        await #expect(throws: AgentXPiRuntimeError.missingRuntime) {
            try await missing.respond(provider: provider, model: "new/model", secret: "key", messages: messages)
        }
    }
    @Test func requestAndResponseBoundsFailWithoutPipeDeadlocks() async throws {
        let directory = try fixture("/bin/cat >/dev/null; /usr/bin/head -c 200000 /dev/zero")
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: AgentXPiRuntimeError.invalidResponse) {
            try await runtime(directory).respond(provider: provider, model: "new/model", secret: "key", messages: messages)
        }
        await #expect(throws: AgentXPiRuntimeError.invalidRequest) {
            try await runtime(directory).respond(provider: provider, model: "new/model", secret: "key", messages: [.init(role: "user", content: String(repeating: "x", count: 1_048_577))])
        }
    }
    @Test func stderrIsDrainedWithoutExposingItsContents() async throws {
        let directory = try fixture("/bin/cat >/dev/null; /usr/bin/head -c 200000 /dev/zero >&2; printf '%s' '{\"version\":1,\"ok\":true,\"text\":\"ok\"}'")
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try await runtime(directory).respond(provider: provider, model: "new/model", secret: "key", messages: messages) == "ok")
    }
    @Test func timeoutKillsUncooperativeChildAndReapsIt() async throws {
        let directory = try fixture("trap '' TERM\nprintf '%s' $$ > \"$0.pid\"\nwhile :; do :; done")
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: AgentXPiRuntimeError.timeout) {
            try await runtime(directory, timeout: 0.15).respond(provider: provider, model: "new/model", secret: "key", messages: messages)
        }
        let pid = try #require(Int32(String(contentsOf: directory.appendingPathComponent("runner.sh.pid"), encoding: .utf8)))
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }
    @Test func cancellationKillsUncooperativeChildAndReapsIt() async throws {
        let directory = try fixture("trap '' TERM\nprintf '%s' $$ > \"$0.pid\"\nwhile :; do :; done")
        defer { try? FileManager.default.removeItem(at: directory) }
        let operation = Task { try await runtime(directory).respond(provider: provider, model: "new/model", secret: "key", messages: messages) }
        let pidFile = directory.appendingPathComponent("runner.sh.pid")
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: pidFile.path) { try await Task.sleep(for: .milliseconds(10)) }
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        operation.cancel()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENTX_PI_TEST_NODE"] != nil && ProcessInfo.processInfo.environment["AGENTX_PI_TEST_RUNNER"] != nil))
    func bundledPiPreservesHistoryAcrossModelsAndCancelsLocalSSE() async throws {
        let node = try #require(ProcessInfo.processInfo.environment["AGENTX_PI_TEST_NODE"])
        let runner = try #require(ProcessInfo.processInfo.environment["AGENTX_PI_TEST_RUNNER"])
        let directory = try fixture("")
        defer { try? FileManager.default.removeItem(at: directory) }
        let serverScript = directory.appendingPathComponent("server.mjs")
        try #"""
        import http from 'node:http';
        import fs from 'node:fs';
        import path from 'node:path';
        const root = process.argv[2], requests = [];
        const server = http.createServer(async (req, res) => {
          let raw = ''; for await (const chunk of req) raw += chunk;
          const body = JSON.parse(raw); requests.push(body);
          fs.writeFileSync(path.join(root, 'requests.json'), JSON.stringify(requests));
          const latest = body.messages.at(-1).content;
          const text = typeof latest === 'string' ? latest : latest.map(x => x.text).join('');
          if (text === 'hang') {
            fs.writeFileSync(path.join(root, 'hanging'), 'ready');
            res.on('close', () => fs.writeFileSync(path.join(root, 'closed'), 'closed'));
            return;
          }
          res.writeHead(200, { 'content-type': 'text/event-stream' });
          const first = { id: 'fixture', choices: [{ index: 0, delta: { content: 'reply:' + body.model }, finish_reason: null }] };
          const last = { id: 'fixture', choices: [{ index: 0, delta: {}, finish_reason: 'stop' }] };
          res.end(['data: ' + JSON.stringify(first), '', 'data: ' + JSON.stringify(last), '', 'data: [DONE]', '', ''].join(String.fromCharCode(10)));
        });
        server.listen(0, '127.0.0.1', () => fs.writeFileSync(path.join(root, 'port'), String(server.address().port)));
        """#.write(to: serverScript, atomically: true, encoding: .utf8)
        let server = Process()
        server.executableURL = URL(fileURLWithPath: node)
        server.arguments = [serverScript.path, directory.path]
        server.environment = ["PATH": "/usr/bin:/bin"]
        server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
        try server.run()
        defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
        let portFile = directory.appendingPathComponent("port")
        for _ in 0..<300 where !FileManager.default.fileExists(atPath: portFile.path) { try await Task.sleep(for: .milliseconds(10)) }
        let port = try String(contentsOf: portFile, encoding: .utf8)
        let local = AgentXProvider(id: "local", name: "Local fixture", baseURL: "http://127.0.0.1:\(port)/v1", models: ["new/model-a", "new/model-b"])
        let runtime = AgentXPiRuntime(nodeURL: URL(fileURLWithPath: node), runnerURL: URL(fileURLWithPath: runner), timeout: 5)
        let history = [AgentXMessage(role: "system", content: "system"), .init(role: "user", content: "old question"), .init(role: "assistant", content: "old answer"), .init(role: "user", content: "next")]
        for model in local.models {
            #expect(try await runtime.respond(provider: local, model: model, secret: "fixture-key", messages: history) == "reply:\(model)")
        }
        let data = try Data(contentsOf: directory.appendingPathComponent("requests.json"))
        let requests = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(requests.count == 2)
        #expect(requests.compactMap { $0["model"] as? String } == local.models)
        for request in requests {
            let sent = try #require(request["messages"] as? [[String: Any]])
            #expect(sent.map { $0["role"] as? String } == ["system", "user", "assistant", "user"])
            #expect(sent[1]["content"] as? String == "old question")
            #expect(sent[2]["content"] as? String == "old answer")
        }
        let operation = Task { try await runtime.respond(provider: local, model: "new/model-b", secret: "fixture-key", messages: [.init(role: "user", content: "hang")]) }
        let hanging = directory.appendingPathComponent("hanging")
        for _ in 0..<300 where !FileManager.default.fileExists(atPath: hanging.path) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(FileManager.default.fileExists(atPath: hanging.path))
        operation.cancel()
        await #expect(throws: CancellationError.self) { try await operation.value }
        let closed = directory.appendingPathComponent("closed")
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: closed.path) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(FileManager.default.fileExists(atPath: closed.path))
    }

}
