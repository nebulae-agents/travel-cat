// Manual UI fixture only. No network, Docker, real credentials or user data.
import AppKit
import SwiftUI
import Combine
import CryptoKit

extension Bundle { static var module: Bundle { .main } }

@MainActor
final class PreviewCredentials: TravelServiceCredentialStoring {
    private var values: [String: String] = [:]
    func read(id: String) throws -> String? { values[id] }
    func save(_ secret: String?, id: String) throws { values[id] = secret }
}

@MainActor
final class PreviewRuntime: AgentRuntimeClient {
    var onEvent: (([String: Any]) -> Void)?
    var onExit: (() -> Void)?
    private var turns: [String: CheckedContinuation<Void, Never>] = [:]
    private var auditReceipts: [String: (task: String, continuation: CheckedContinuation<Bool, Never>)] = [:]
    private var modelDecisions: [String: (task: String, hash: String, continuation: CheckedContinuation<Bool, Never>)] = [:]
    private var stopped: Set<String> = []
    private var closed = false

    private func checkActive(_ task: String) throws {
        guard !closed, !stopped.contains(task) else { throw WorkbenchFailure("离线验收会话已结束。") }
    }

    // Suspend only this request. MainActor reentrancy lets audit_ack and model_permission
    // resolve their continuations while the original prompt is still pending.
    private func audit(_ task: String, _ kind: String, call: String, fields: [String: Any]) async throws {
        try checkActive(task)
        let receipt = UUID().uuidString
        var record = fields
        record["eventId"] = UUID().uuidString; record["taskId"] = task
        record["callId"] = call; record["kind"] = kind
        record["timestamp"] = ISO8601DateFormatter().string(from: Date())
        let accepted = await withCheckedContinuation { continuation in
            auditReceipts[receipt] = (task, continuation)
            emit(task, "audit", ["receiptId": receipt, "record": record])
        }
        try checkActive(task)
        guard accepted else { throw WorkbenchFailure("离线验收审计未获持久化确认，已阻止继续。") }
    }

    private func modelCall(_ task: String, text: String) async throws {
        let call = UUID().uuidString
        let destination = "https://fixture.invalid/v1", model = "fixture-only"
        let bodyData = try JSONSerialization.data(withJSONObject: ["model": model, "input": text, "stream": true], options: [.sortedKeys, .withoutEscapingSlashes])
        let body = String(decoding: bodyData, as: UTF8.self)
        let hash = SHA256.hash(data: bodyData).map { String(format: "%02x", $0) }.joined()
        try await audit(task, "model.request", call: call, fields: ["destination": destination, "model": model, "body": body, "requestHash": hash, "bytes": bodyData.count, "api": "responses"])
        let allowed = await withCheckedContinuation { continuation in
            modelDecisions[call] = (task, hash, continuation)
            emit(task, "modelApproval", ["callId": call, "requestHash": hash, "destination": destination, "model": model])
        }
        try checkActive(task)
        try await audit(task, "model.decision", call: call, fields: ["requestHash": hash, "allow": allowed, "policy": "review"])
        guard allowed else {
            try await audit(task, "model.failed", call: call, fields: ["reason": "离线验收：用户拒绝本次模型提交，未联网。"])
            throw WorkbenchFailure("离线验收：本次模型提交已拒绝。", taskRetained: true)
        }
        let response = "离线测试模型返回：已收到任务；以下 token 为固定夹具数据，未联网。"
        try await audit(task, "model.response", call: call, fields: ["text": response, "sequence": 0])
        let rawUsage: [String: Any] = ["input_tokens": 128, "output_tokens": 32, "input_tokens_details": ["cached_tokens": 16]]
        let usage: [String: Any] = ["totalInput": 128, "output": 32, "cacheRead": 16, "cacheWrite": 0, "source": "reported", "rawUsage": [rawUsage], "fixture": true]
        try await audit(task, "model.completed", call: call, fields: ["usage": usage, "status": 200, "complete": true])
        emit(task, "update", ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": response]])
    }

    private func releasePending(task: String? = nil) {
        for key in turns.keys.filter({ task == nil || $0 == task }) { turns.removeValue(forKey: key)?.resume() }
        for key in auditReceipts.keys.filter({ task == nil || auditReceipts[$0]?.task == task }) {
            auditReceipts.removeValue(forKey: key)?.continuation.resume(returning: false)
        }
        for key in modelDecisions.keys.filter({ task == nil || modelDecisions[$0]?.task == task }) {
            modelDecisions.removeValue(forKey: key)?.continuation.resume(returning: false)
        }
    }
    func launch(python: String) throws {}
    func emit(_ task: String, _ event: String, _ data: [String: Any]) {
        onEvent?(["taskId": task, "event": event, "data": data])
    }
    func request(_ method: String, _ params: [String: Any], timeout: UInt64) async throws -> [String: Any] {
        let id = params["taskId"] as? String ?? ""
        switch method {
        case "audit_ack":
            guard let receipt = params["receiptId"] as? String,
                  let pending = auditReceipts.removeValue(forKey: receipt) else { return ["accepted": false] }
            pending.continuation.resume(returning: params["accepted"] as? Bool == true)
            return ["accepted": true]
        case "model_permission":
            guard let call = params["callId"] as? String, let pending = modelDecisions[call],
                  pending.task == id, pending.hash == params["requestHash"] as? String,
                  let allow = params["allow"] as? Bool else { throw WorkbenchFailure("离线验收：授权与请求不匹配。") }
            modelDecisions.removeValue(forKey: call)?.continuation.resume(returning: allow)
            return ["accepted": true]
        case "start":
            if let instance = params["instance"] as? [String: Any], (instance["command"] as? [String])?.first == "fail-start" {
                throw WorkbenchFailure("离线测试：模拟容器启动失败，草稿应保留。", taskRetained: false)
            }
            return ["sessionId": UUID().uuidString]
        case "discover": return ["docker": false, "message": "离线验收：未连接真实 Docker。"]
        case "scan_local":
            let image = "localhost:5000/travelcat-codex-acp@sha256:" + String(repeating: "a", count: 64)
            return ["tools": [["kind": "codex", "path": "/fixture/bin/codex", "running": 1],
                              ["kind": "claude", "path": "/fixture/bin/claude", "running": 0]],
                    "contexts": [["name": "offline-colima", "local": true, "available": true],
                                 ["name": "remote-fixture", "local": false, "available": false]],
                    "images": [["context": "offline-colima", "ref": image],
                               ["context": "offline-colima", "ref": "node@sha256:" + String(repeating: "b", count: 64)]],
                    "containers": [["context": "offline-colima", "id": "abcdef123456", "name": "codex-fixture",
                                    "image": image, "state": "running"]]]
        case "probe":
            let allowed = (params["dockerContext"] as? String) == "offline-colima"
                && (params["command"] as? [String]) == ACPAdapterPreset.codex.command
            return ["probeId": params["probeId"] ?? "", "compatible": allowed,
                    "cleanupConfirmed": true, "message": allowed ? "Offline handshake and cleanup confirmed" : "Offline handshake failed"]
        case "probe_cleanup": return ["probeId": params["probeId"] ?? "", "cleanupConfirmed": true]
        case "prompt":
            let text = params["text"] as? String ?? ""
            try await modelCall(id, text: text)
            if text.contains("确认") {
                await withCheckedContinuation { continuation in
                    turns[id] = continuation
                    emit(id, "permission", ["requestId": "preview-\(id)", "toolCall": ["title": "生成测试报告", "rawInput": ["command": "fixture-only"]], "options": [["optionId": "allow", "name": "允许本次", "kind": "allow_once"], ["optionId": "deny", "name": "拒绝", "kind": "reject_once"]]])
                }
            } else {
                emit(id, "state", ["status": "completed"])
            }
            try checkActive(id)
            return [:]
        case "permission":
            emit(id, "update", ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "\n已收到你的选择：\(params["optionId"] as? String ?? "")。本次仅验证界面。"]])
            emit(id, "state", ["status": "completed"])
            turns.removeValue(forKey: id)?.resume()
            return [:]
        case "cancel", "stop":
            stopped.insert(id)
            emit(id, "state", ["status": "cancelled"])
            releasePending(task: id)
            return ["stopped": true]
        case "artifacts": return ["files": []]
        default: throw WorkbenchFailure("离线验收不支持该操作。")
        }
    }
    func shutdown() {
        closed = true
        releasePending()
        onExit?()
    }
}

@main
@MainActor
struct WorkbenchPreview {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-ui-\(UUID().uuidString)")
        let runtime = PreviewRuntime()
        let credentials = PreviewCredentials()
        var legacy = WorkbenchSnapshot()
        var oldTask = WorkbenchTask(instanceID: UUID(), title: "旧对话迁移夹具")
        oldTask.status = .completed
        oldTask.messages = [.init(role: "user", text: "legacy-private-fixture-canary")]
        legacy.tasks = [oldTask]
        try WorkbenchStore(root: root).save(legacy)
        let audit = try AgentAuditStore.open(root: root.appendingPathComponent("audit-v1"), credentials: credentials)
        try audit.append(record: ["eventId": UUID().uuidString, "taskId": oldTask.id.uuidString, "kind": "model.request", "timestamp": "2020-01-01T00:00:00Z", "body": "retention-private-fixture-canary", "model": "offline-fixture", "destination": "https://fixture.invalid/v1/responses"])
        let model = AgentWorkbenchModel(root: root, credentials: credentials, client: runtime, auditStore: audit)
        var first = WorkbenchInstance(name: "开发助手（离线）", image: "fixture@sha256:" + String(repeating: "a", count: 64), command: ["fixture-only"])
        first.provider.model = "fixture-only"
        var second = first; second.id = UUID(); second.name = "研究助手（离线）"; second.symbol = "chart.line.uptrend.xyaxis"; second.provider.credentialID = UUID().uuidString
        try model.save(instance: first, newKey: "fixture-canary")
        try model.save(instance: second, newKey: "fixture-canary")
        var failing = first; failing.id = UUID(); failing.name = "启动失败（离线）"; failing.command = ["fail-start"]; failing.provider.credentialID = UUID().uuidString
        try model.save(instance: failing, newKey: "fixture-canary")
        var keyless = first; keyless.id = UUID(); keyless.name = "未配置凭据（离线）"; keyless.provider.credentialID = UUID().uuidString
        try model.save(instance: keyless, newKey: "")
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 740), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Agent Workbench · 离线交互验收"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: VStack(spacing: 0) {
            Button("仅显示浮动入口（离线验收）") { window.orderOut(nil) }.padding(6)
            AgentWorkbenchView(model: model)
        })
        window.center(); window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        let launcher = AgentLauncherController(model: model) {
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
        }
        launcher.show(beside: window.frame)
        let subscription = model.objectWillChange.sink {
            Task { @MainActor in launcher.update(model: model) }
        }
        Task { await model.start(instanceID: first.id, text: "检查项目，需要确认") }
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { app.stop(nil) }
        }
        app.run()
        NotificationCenter.default.removeObserver(observer)
        subscription.cancel(); launcher.hide(); model.shutdown()
        try? FileManager.default.removeItem(at: root)
    }
}
