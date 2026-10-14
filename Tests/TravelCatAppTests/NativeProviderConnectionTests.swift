import Foundation
import XCTest
@testable import TravelCatApp

/// Exercises the real URLSession transport over loopback, including cancellation
/// after the server has received a request. No credentials or external services.
@MainActor
final class NativeProviderConnectionTests: XCTestCase {
    func testLocalConnectionUsesRealHTTPAndNoAuthorization() async throws {
        let server = try await LoopbackProvider.start()
        defer { server.stop() }
        let output = try await OpenAICompatibleTravelClient().text(
            baseURL: server.baseURL, model: "local-fixture", apiKey: nil, prompt: "connection test")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: output) as? [String: Bool], ["ok": true])
        let request = try server.request()
        XCTAssertEqual(request["path"] as? String, "/v1/chat/completions")
        XCTAssertEqual(request["authorizationPresent"] as? Bool, false)
    }

    func testCancelsAnInFlightLocalRequestAndAllowsNextConnection() async throws {
        try await checkCancellation(route: "slow", signal: "request.json")
    }

    func testCancelsWhileWaitingForRemainingResponseBytes() async throws {
        try await checkCancellation(route: "body-slow", signal: "body-started")
    }

    private func checkCancellation(route: String, signal: String) async throws {
        let server = try await LoopbackProvider.start()
        defer { server.stop() }
        let client = OpenAICompatibleTravelClient()
        let task = Task {
            try await client.text(baseURL: server.baseURL.appendingPathComponent(route),
                                  model: "local-fixture", apiKey: nil, prompt: "connection test")
        }
        defer { task.cancel() }
        try await server.waitForSignal(signal)
        let started = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled probe must not report success")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "Cancellation must not wait for the slow server")
        let output = try await client.text(baseURL: server.baseURL, model: "local-fixture", apiKey: nil, prompt: "retry")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: output) as? [String: Bool], ["ok": true])
    }

    func testRealRedirectIsRejectedWithoutFollowingLocation() async throws {
        let server = try await LoopbackProvider.start()
        defer { server.stop() }
        do {
            _ = try await OpenAICompatibleTravelClient().text(
                baseURL: server.baseURL.appendingPathComponent("redirect"),
                model: "local-fixture", apiKey: nil, prompt: "connection test")
            XCTFail("Redirect must be rejected")
        } catch {
            guard case OpenAICompatibleTravelError.http(302) = error else {
                return XCTFail("Expected HTTP 302 refusal, got \(error)")
            }
        }
        XCTAssertEqual(try server.request()["path"] as? String, "/v1/redirect/chat/completions")
        XCTAssertFalse(FileManager.default.fileExists(atPath: server.root.appendingPathComponent("followed").path))
    }
}

@MainActor
private final class LoopbackProvider {
    let root: URL
    let process: Process
    let baseURL: URL

    private init(root: URL, process: Process, port: Int) {
        self.root = root
        self.process = process
        baseURL = URL(string: "http://127.0.0.1:\(port)/v1")!
    }

    static func start() async throws -> LoopbackProvider {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("travelcat-http-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let script = root.appendingPathComponent("server.py")
        try Data(#"""
import json, pathlib, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
root = pathlib.Path(sys.argv[1])
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length', '0')))
        item = {'path': self.path, 'authorizationPresent': bool(self.headers.get('Authorization'))}
        (root / 'request.json').write_text(json.dumps(item))
        if '/redirect/' in self.path:
            self.send_response(302)
            self.send_header('Location', '/followed')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        if '/slow/' in self.path: time.sleep(8)
        body = json.dumps({'choices': [{'message': {'content': '{"ok":true}'}}]}).encode()
        try:
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            if '/body-slow/' in self.path:
                self.wfile.write(body[:1])
                self.wfile.flush()
                (root / 'body-started').write_text('ready')
                time.sleep(8)
                self.wfile.write(body[1:])
            else:
                self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError): pass
    def do_GET(self):
        (root / 'followed').write_text('unexpected redirect')
        self.send_response(200)
        self.end_headers()
server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
(root / 'port').write_text(str(server.server_address[1]))
server.serve_forever()
"""#.utf8).write(to: script)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, root.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline, process.isRunning {
                if let text = try? String(contentsOf: root.appendingPathComponent("port"), encoding: .utf8), let port = Int(text) {
                    return LoopbackProvider(root: root, process: process, port: port)
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw NSError(domain: "LoopbackProvider", code: 1, userInfo: [NSLocalizedDescriptionKey: "Loopback server failed to start"])
        } catch {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func waitForSignal(_ name: String) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "LoopbackProvider", code: 2, userInfo: [NSLocalizedDescriptionKey: "Request did not reach loopback server"])
    }

    func request() throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent("request.json"))
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }

    func stop() {
        if process.isRunning { process.terminate(); process.waitUntilExit() }
        try? FileManager.default.removeItem(at: root)
    }
}
