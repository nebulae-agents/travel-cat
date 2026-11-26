import Foundation
import Darwin
import Testing
@testable import TravelCatApp

/// Run with AGENTX_TEST_PI_NODE set to the actual bundled Node. Missing Node is a
/// hard acceptance failure; this suite never turns unavailable confinement into a pass.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["AGENTX_M4_ACCEPTANCE"] == "1"))
@MainActor
struct AgentXPiSandboxTests {
    private func node() throws -> URL {
        let configured = try #require(ProcessInfo.processInfo.environment["AGENTX_TEST_PI_NODE"], "Explicit real Pi Node is required for M4 acceptance")
        let url = URL(fileURLWithPath: configured)
        #expect(FileManager.default.isExecutableFile(atPath: url.path), "Real Pi Node is required for M4 acceptance")
        return url
    }
    private func listener() throws -> (Int32, UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentXError.unavailable }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(fd, 4) == 0 else { close(fd); throw AgentXError.unavailable }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) } }
        guard result == 0 else { close(fd); throw AgentXError.unavailable }
        return (fd, UInt16(bigEndian: address.sin_port))
    }
    private func application() -> AgentXApplication {
        var app = AgentXApplication(id: "a", name: "A", kind: .chat)
        app.manifest = ["permissions": .object(["files": .array([.string("self")]), "network": .array([.string("configured-provider")])])]
        return app
    }
    @Test func actualPiChildAllowsOwnFilesAndOnlyOneLoopbackPort() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("agentx-sandbox-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (allowedFD, allowedPort) = try listener(), (otherFD, otherPort) = try listener()
        defer { close(allowedFD); close(otherFD) }
        let provider = AgentXProvider(id: "p", name: "P", baseURL: "http://127.0.0.1:\(allowedPort)/v1", models: ["m"])
        let policy = try AgentXExecutionPolicy(root: root, application: application(), provider: provider)
        let sandbox = try policy.sandbox(gatewayURL: provider.baseURL, runID: "probe")
        for path in ["apps/b", "manager", "apps/a/events"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
            try Data("protected".utf8).write(to: root.appendingPathComponent(path + "/secret"))
        }
        try Data("protected manifest".utf8).write(to: root.appendingPathComponent("apps/a/app.yaml"))
        try Data("own".utf8).write(to: root.appendingPathComponent("apps/a/state/input"))
        try Data("payload".utf8).write(to: root.appendingPathComponent("apps/a/payload/input"))
        let runner = root.appendingPathComponent("runner.mjs")
        let encodedRoot = String(decoding: try JSONEncoder().encode(root.path), as: UTF8.self)
        try """
        import fs from 'node:fs'; import net from 'node:net';
        fs.readFileSync(0); const root = \(encodedRoot), result = {};
        result.readOwn = fs.readFileSync(root + '/apps/a/state/input','utf8') === 'own';
        fs.writeFileSync(root + '/apps/a/artifacts/output', 'allowed'); result.writeOwn = true;
        result.readPayload = fs.readFileSync(root + '/apps/a/payload/input','utf8') === 'payload';
        const denied = (f) => { try { f(); return false; } catch(e) { return ['EPERM','EACCES'].includes(e.code); } };
        for (const path of ['apps/b/secret','manager/secret','apps/a/events/secret','apps/a/app.yaml']) {
          result['read:' + path] = denied(() => fs.readFileSync(root + '/' + path));
          result['write:' + path] = denied(() => fs.writeFileSync(root + '/' + path, 'forbidden'));
        }
        result.writePayload = denied(() => fs.writeFileSync(root + '/apps/a/payload/input','forbidden'));
        fs.symlinkSync(root + '/apps/b/secret', root + '/apps/a/state/link');
        result.linkEscape = denied(() => fs.readFileSync(root + '/apps/a/state/link'));
        result.hardlinkEscape = denied(() => fs.linkSync(root + '/apps/b/secret', root + '/apps/a/state/hardlink'));
        const connect = (port, host = '127.0.0.1') => new Promise(resolve => { const s = net.createConnection({host,port});
          s.on('connect',()=>{s.destroy();resolve('connected')}); s.on('error',e=>resolve(e.code)); s.setTimeout(1500,()=>{s.destroy();resolve('timeout')}); });
        result.allowedPort = await connect(\(allowedPort)) === 'connected';
        result.otherPort = ['EPERM','EACCES'].includes(await connect(\(otherPort)));
        result.external = ['EPERM','EACCES'].includes(await connect(\(allowedPort), '192.0.2.1'));
        result.ipv6 = ['EPERM','EACCES'].includes(await connect(\(allowedPort), '::1'));
        console.log(JSON.stringify({version:1,ok:true,text:JSON.stringify(result)}));
        """.write(to: runner, atomically: true, encoding: .utf8)
        let runtime = AgentXPiRuntime(nodeURL: try node(), runnerURL: runner, sandbox: sandbox)
        let text: String
        do {
            text = try await runtime.respond(provider: provider, model: "m", secret: nil, messages: [.init(role: "user", content: "probe")])
        } catch {
            // This fixture contains no credentials/user data. Preserve exact OS diagnostics
            // in the failing test, while production continues discarding arbitrary stderr.
            for name in ["link", "hardlink"] { try? FileManager.default.removeItem(at: root.appendingPathComponent("apps/a/state/" + name)) }
            let process = Process(), output = Pipe(), input = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            process.arguments = ["-p", try sandbox.profile(node: node(), runner: runner), try node().path, runner.path]
            process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "TMPDIR": "/private/tmp"]
            process.currentDirectoryURL = root
            process.standardOutput = output; process.standardError = output; process.standardInput = input
            try process.run(); try input.fileHandleForWriting.write(contentsOf: Data("{}".utf8)); try input.fileHandleForWriting.close()
            let diagnostic = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            Issue.record("Sandbox fixture diagnostics: \(String(decoding: diagnostic, as: UTF8.self))\n\(try sandbox.profile(node: node(), runner: runner))")
            throw error
        }
        let results = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Bool])
        #expect(results.count == 18)
        for (name, passed) in results { #expect(passed, "Actual OS sandbox probe failed: \(name)") }
        #expect(try String(contentsOf: root.appendingPathComponent("apps/b/secret"), encoding: .utf8) == "protected")
        #expect(try String(contentsOf: root.appendingPathComponent("apps/a/artifacts/output"), encoding: .utf8) == "allowed")
    }
    @Test func missingFileGrantDeniesOwnDataInActualChild() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("agentx-sandbox-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("apps/a/state"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let secret = root.appendingPathComponent("apps/a/state/private")
        try Data("protected".utf8).write(to: secret)
        let provider = AgentXProvider(id: "p", name: "P", baseURL: "https://example.com/v1", models: ["m"])
        var app = application(); app.manifest = ["permissions": .object(["files": .array([])])]
        let policy = try AgentXExecutionPolicy(root: root, application: app, provider: provider)
        let sandbox = try policy.sandbox(gatewayURL: nil, runID: "probe")
        let runner = root.appendingPathComponent("runner.mjs")
        let path = String(decoding: try JSONEncoder().encode(secret.path), as: UTF8.self)
        try """
        import fs from 'node:fs'; fs.readFileSync(0);
        let blocked = false; try { fs.readFileSync(\(path)); } catch(e) { blocked = ['EPERM','EACCES'].includes(e.code); }
        console.log(JSON.stringify({version:1,ok:true,text:blocked ? 'denied' : 'escaped'}));
        """.write(to: runner, atomically: true, encoding: .utf8)
        let runtime = AgentXPiRuntime(nodeURL: try node(), runnerURL: runner, sandbox: sandbox)
        #expect(try await runtime.respond(provider: provider, model: "m", secret: nil, messages: [.init(role: "user", content: "probe")]) == "denied")
    }
    @Test func linkedGrantedTreeFailsBeforeChildLaunchAndPersistsPolicyEvent() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("agentx-sandbox-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = AgentXProvider(id: "p", name: "P", baseURL: "https://example.com/v1", models: ["m"])
        let policy = try AgentXExecutionPolicy(root: root, application: application(), provider: provider)
        let sandbox = try policy.sandbox(gatewayURL: nil, runID: "probe")
        let secret = root.appendingPathComponent("protected")
        try Data("protected".utf8).write(to: secret)
        try FileManager.default.linkItem(at: secret, to: root.appendingPathComponent("apps/a/state/link"))
        let runner = root.appendingPathComponent("runner.mjs")
        try "console.log('must not launch')".write(to: runner, atomically: true, encoding: .utf8)
        let runtime = AgentXPiRuntime(nodeURL: try node(), runnerURL: runner, sandbox: sandbox)
        await #expect(throws: AgentXPermissionDenied.self) {
            try await runtime.respond(provider: provider, model: "m", secret: nil, messages: [.init(role: "user", content: "probe")])
        }
        #expect(try policy.events().first?["operation"] as? String == "runtime.filesystem")
        try FileManager.default.removeItem(at: root.appendingPathComponent("apps/a/state/link"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("apps/a/state/link"), withDestinationURL: secret)
        await #expect(throws: AgentXPermissionDenied.self) {
            try await runtime.respond(provider: provider, model: "m", secret: nil, messages: [.init(role: "user", content: "probe")])
        }
        #expect(try policy.events().count == 2)
    }
}
