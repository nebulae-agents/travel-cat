import Foundation
import AppKit
import SwiftUI
import XCTest
@testable import TravelCatApp

final class AgentWorkbenchTests: XCTestCase {
    private func instance() -> WorkbenchInstance {
        WorkbenchInstance(name: "开发", image: "agent@sha256:" + String(repeating: "a", count: 64), command: ["codex-acp"])
    }
    func testOnlyPinnedImagesAndStructuredCommandsAllowed() throws {
        XCTAssertNoThrow(try instance().validate())
        var value = instance()
        value.image = "agent:latest"
        XCTAssertThrowsError(try value.validate())
        value = instance(); value.command = []
        XCTAssertThrowsError(try value.validate())
        value = instance(); value.host = "-oProxyCommand=bad"
        XCTAssertThrowsError(try value.validate())
        value = instance(); value.host = "dev-server"
        XCTAssertNoThrow(try value.validate())
    }
    func testProviderRejectsCredentialBearingAndInsecureURLs() throws {
        var value = WorkbenchProvider()
        value.model = "test"
        value.baseURL = "https://example.com/v1"
        XCTAssertNoThrow(try value.validate())
        for url in ["http://example.com/v1", "https://user:secret@example.com", "https://example.com?key=secret", "file:///tmp/key"] {
            value.baseURL = url
            XCTAssertThrowsError(try value.validate())
        }
    }
    func testStoreRecoversRunningTasksWithoutReplayingOrPersistingSecrets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkbenchStore(root: root)
        var state = WorkbenchSnapshot()
        state.instances = [instance()]
        var task = WorkbenchTask(instanceID: state.instances[0].id, title: "研究")
        task.status = .running
        state.tasks = [task]
        try store.save(state)
        let recovered = try store.load()
        XCTAssertEqual(recovered.tasks[0].status, .unknown)
        XCTAssertTrue(recovered.tasks[0].unread, "Interrupted tasks must appear in the mailbox after restart")
        let contents = try String(contentsOf: store.url, encoding: .utf8)
        XCTAssertFalse(contents.contains("apiKey"))
        XCTAssertFalse(contents.contains("authorization"))
        let mode = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }
    func testSchemaMismatchAndCorruptStoreDoNotSilentlyReset() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkbenchStore(root: root)
        try store.save(WorkbenchSnapshot())
        try Data("{\"schemaVersion\":99}".utf8).write(to: store.url)
        XCTAssertThrowsError(try store.load())
    }
}

@MainActor
private final class WorkbenchTestCredentials: TravelServiceCredentialStoring {
    var values: [String: String] = [:]
    func read(id: String) throws -> String? { values[id] }
    func save(_ secret: String?, id: String) throws { values[id] = secret }
}
@MainActor
private final class WorkbenchTestRuntime: AgentRuntimeClient {
    var onEvent: (([String: Any]) -> Void)?
    var onExit: (() -> Void)?
    var calls: [String] = []
    var taskID = ""
    var onPrompt: (() -> Void)?
    var startFailure: Error?
    func launch(python: String) throws {}
    func request(_ method: String, _ params: [String: Any], timeout: UInt64) async throws -> [String: Any] {
        calls.append(method)
        if let id = params["taskId"] as? String { taskID = id }
        if method == "start" { if let startFailure { throw startFailure }; return ["sessionId": "fake-session"] }
        if method == "prompt" { onPrompt?() }
        return [:]
    }
    func shutdown() { onExit?() }
    func emit(_ event: String, _ data: [String: Any]) { onEvent?(["event": event, "taskId": taskID, "data": data]) }
}

extension AgentWorkbenchTests {
    @MainActor
    func testPermissionExpiryClearsUIAndRecordsCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = WorkbenchTestRuntime()
        let model = AgentWorkbenchModel(root: root, credentials: WorkbenchTestCredentials(), client: client)
        var agent = instance(); agent.provider.model = "canary-model"
        try model.save(instance: agent, newKey: "secret-canary")
        client.onPrompt = {
            client.emit("permission", ["requestId": "r1", "options": [["optionId": "allow", "name": "允许", "kind": "allow_once"]], "toolCall": ["title": "执行命令", "rawInput": ["command": "test"]]])
            XCTAssertEqual(model.permissions.count, 1)
            XCTAssertTrue(model.permissions[0].detail.contains("command"))
            client.emit("permissionExpired", ["requestId": "r1"])
            XCTAssertTrue(model.permissions.isEmpty)
        }
        await model.start(instanceID: agent.id, text: "测试任务")
        XCTAssertTrue(model.state.tasks[0].messages.contains { $0.text.contains("已过期") })
        let saved = try String(decoding: Data(contentsOf: root.appendingPathComponent("workbench.sealed")), as: UTF8.self)
        XCTAssertFalse(saved.contains("secret-canary"))
        model.shutdown()
    }
    @MainActor
    func testReopeningHistoryDoesNotStartRuntime() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var snapshot = WorkbenchSnapshot()
        snapshot.tasks = [WorkbenchTask(instanceID: UUID(), title: "旧任务")]
        try WorkbenchStore(root: root).save(snapshot)
        let client = WorkbenchTestRuntime()
        let model = AgentWorkbenchModel(root: root, credentials: WorkbenchTestCredentials(), client: client)
        XCTAssertEqual(model.state.tasks[0].status, .unknown)
        XCTAssertFalse(model.canReply(model.state.tasks[0].id))
        XCTAssertTrue(client.calls.isEmpty)
    }
}

extension AgentWorkbenchTests {
    @MainActor
    func testLatePermissionExpiryCannotReopenCompletedTask() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = WorkbenchTestRuntime()
        let model = AgentWorkbenchModel(root: root, credentials: WorkbenchTestCredentials(), client: client)
        var agent = instance(); agent.provider.model = "test"
        try model.save(instance: agent, newKey: "canary")
        client.onPrompt = {
            client.emit("permission", ["requestId": "r", "options": [["optionId": "allow"]]])
            client.emit("state", ["status": "completed"])
            client.emit("permissionExpired", ["requestId": "r"])
            XCTAssertEqual(model.state.tasks[0].status, .completed)
        }
        await model.start(instanceID: agent.id, text: "test")
        XCTAssertEqual(model.state.tasks[0].status, .completed)
        model.shutdown()
    }
    @MainActor
    func testUnconfirmedStopKeepsRetryAvailable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = WorkbenchTestRuntime()
        let model = AgentWorkbenchModel(root: root, credentials: WorkbenchTestCredentials(), client: client)
        var agent = instance(); agent.provider.model = "test"
        try model.save(instance: agent, newKey: "canary")
        await model.start(instanceID: agent.id, text: "test")
        let id = try XCTUnwrap(model.state.tasks.first?.id)
        await model.stop(id) // Fake omits stopped:true, so no success may be inferred.
        XCTAssertEqual(model.state.tasks[0].status, .unknown)
        XCTAssertTrue(model.isLive(id))
        model.shutdown()
    }
}


extension AgentWorkbenchTests {
    @MainActor
    func testWorkbenchRenderWithPendingPermission() async throws {
        // This may be the first AppKit test in the CI process.
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = WorkbenchTestRuntime()
        let model = AgentWorkbenchModel(root: root, credentials: WorkbenchTestCredentials(), client: client)
        var agent = instance(); agent.provider.model = "test"; agent.name = "项目开发助手"
        try model.save(instance: agent, newKey: "canary")
        client.onPrompt = {
            client.emit("update", ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "已完成输入资料检查。准备在隔离工作区生成报告，需要你确认下一步。"]])
            client.emit("permission", ["requestId": "preview", "options": [["optionId": "allow", "name": "允许本次", "kind": "allow_once"], ["optionId": "deny", "name": "拒绝", "kind": "reject_once"]], "toolCall": ["title": "在隔离工作区运行检查", "rawInput": ["command": "python3 check.py"]]])
        }
        await model.start(instanceID: agent.id, text: "检查项目并生成改进报告")
        let view = NSHostingView(rootView: AgentWorkbenchView(model: model).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 740), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        view.appearance = NSAppearance(named: .aqua)
        window.contentView = view
        if ProcessInfo.processInfo.environment["TRAVELCAT_AGENT_RENDER"] != nil { window.orderFrontRegardless() }
        defer { window.orderOut(nil) }
        view.frame = NSRect(x: 0, y: 0, width: 1000, height: 740)
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 700)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 500)
        if let path = ProcessInfo.processInfo.environment["TRAVELCAT_AGENT_RENDER"] {
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        }
        model.shutdown()
    }
}


extension AgentWorkbenchTests {
    @MainActor
    func testFourMiBBinaryInputsRemainWithinControlRecordLimit() throws {
        let encoded = Data(repeating: 255, count: 1024 * 1024).base64EncodedString()
        let files = (0..<4).map { ["name": "input-\($0).bin", "base64": encoded] }
        let message = try AgentSidecarClient.encodeRequest(id: "test", method: "start", params: ["files": files])
        XCTAssertLessThan(message.count, 6 * 1024 * 1024)
        XCTAssertEqual(message.last, 10)
        XCTAssertThrowsError(try AgentSidecarClient.encodeRequest(id: "test", method: "start", params: ["text": String(repeating: "a", count: 6 * 1024 * 1024)]))
    }
}


extension AgentWorkbenchTests {
    @MainActor
    func testCleanStartupFailureDoesNotLeaveGhostLiveSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = WorkbenchTestRuntime()
        client.startFailure = WorkbenchFailure("Docker unavailable", taskRetained: false)
        let model = AgentWorkbenchModel(root: root, credentials: WorkbenchTestCredentials(), client: client)
        var agent = instance(); agent.provider.model = "test"
        try model.save(instance: agent, newKey: "canary")
        await model.start(instanceID: agent.id, text: "test")
        XCTAssertFalse(model.isLive(model.state.tasks[0].id))
        XCTAssertEqual(model.state.tasks[0].status, .failed)
        model.remove(instanceID: agent.id)
        XCTAssertTrue(model.state.instances.isEmpty)
        model.shutdown()
    }
}
