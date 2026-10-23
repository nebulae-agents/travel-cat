import Foundation
import XCTest
@testable import TravelCatApp

@MainActor private final class NativeTestCredentials: TravelServiceCredentialStoring {
    var values: [String: String] = [:]
    var modelReads = 0
    func read(id: String) throws -> String? {
        if !["workbench-content-v1", "audit-journal-v1"].contains(id) { modelReads += 1 }
        return values[id]
    }
    func save(_ secret: String?, id: String) throws { values[id] = secret }
}
private final class NativeTestAudit: AgentAuditStoring {
    var saved: [[String: Any]] = []
    var reject = false
    func append(record: [String: Any]) throws {
        if reject { throw WorkbenchFailure("audit unavailable") }
        saved.append(record)
    }
    func records(taskID: UUID) throws -> [[String: Any]] { saved.filter { $0["taskId"] as? String == taskID.uuidString } }
}
@MainActor private final class NativeTestRuntime: AgentRuntimeClient {
    var onEvent: (([String: Any]) -> Void)?
    var onExit: (() -> Void)?
    var requests: [(String, [String: Any])] = []
    var results: [String: [String: Any]] = [:]
    var failMethod: String?
    var beforeRequest: ((String, [String: Any]) -> Void)?
    var duringRequest: (@MainActor (String, [String: Any]) async throws -> Void)?
    func launch(python: String) throws {}
    func shutdown() { onExit?() }
    func request(_ method: String, _ params: [String: Any], timeout: UInt64) async throws -> [String: Any] {
        requests.append((method, params)); beforeRequest?(method, params)
        try await duringRequest?(method, params)
        if method == failMethod { throw WorkbenchFailure("response missing") }
        if let result = results[method] { return result }
        switch method {
        case "native_connect": return ["connected":true,"version":"0.158.0","account":["authenticated":true,"authMode":"chatgpt"],"models":[["id":"m","model":"m","displayName":"Fixture model","isDefault":true]],"capabilities":["resume":true,"interrupt":true,"toolApproval":true]]
        case "native_start": return ["threadId":"native-thread","sessionId":"native-thread"]
        case "native_prompt": return ["turnId":"native-turn"]
        case "native_cancel": return ["requested":true,"backgroundStopped":true,"terminatedCount":0]
        default: return [:]
        }
    }
    func emit(taskID: UUID, instanceID: UUID, method: String, params: [String: Any]) {
        onEvent?(["event":"native","taskId":taskID.uuidString,"instanceId":instanceID.uuidString,"data":["method":method,"params":params]])
    }
}

final class NativeAgentModelTests: XCTestCase {
    @MainActor private func fixture() throws -> (AgentWorkbenchModel, NativeTestRuntime, NativeTestCredentials, NativeTestAudit, URL, WorkbenchInstance) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workspace = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let runtime = NativeTestRuntime(), credentials = NativeTestCredentials(), audit = NativeTestAudit()
        let model = AgentWorkbenchModel(root: root.appendingPathComponent("state"), credentials: credentials, client: runtime, auditStore: audit)
        var instance = WorkbenchInstance(name:"Native",image:"",command:[])
        instance.native = .init(executable:"/usr/bin/true",workspace:workspace.path,model:"m")
        try model.save(instance:instance,newKey:"")
        return (model,runtime,credentials,audit,root,instance)
    }

    @MainActor func testNativeSaveAndStartNeverReadsModelCredentials() async throws {
        let (model,runtime,credentials,audit,root,instance) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at:root) }
        runtime.beforeRequest = { method, _ in
            if ["native_start","native_prompt"].contains(method) { XCTAssertFalse(audit.saved.isEmpty, "persist audit before sending") }
        }
        await model.start(instanceID:instance.id,text:"hello")
        XCTAssertEqual(credentials.modelReads,0)
        XCTAssertEqual(runtime.requests.map(\.0),["native_connect","native_start","native_prompt"])
        XCTAssertEqual(model.state.tasks.first?.sessionID,"native-thread")
        XCTAssertEqual(model.state.tasks.first?.status,.running,"RPC acceptance does not complete a turn")
        XCTAssertEqual(model.state.tasks.first?.nativeState?.turnID,"native-turn")
    }

    @MainActor func testCancelRemainsRequestedUntilMatchingTurnConfirmsInterrupted() async throws {
        let (model,runtime,_,_,root,instance) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at:root) }
        await model.start(instanceID:instance.id,text:"hello")
        let task = try XCTUnwrap(model.state.tasks.first)
        await model.cancel(task.id)
        XCTAssertEqual(model.state.tasks.first?.status,.cancelling)
        runtime.emit(taskID:task.id,instanceID:instance.id,method:"turn/completed",params:["threadId":"native-thread","turn":["id":"other-turn","status":"interrupted"]])
        XCTAssertEqual(model.state.tasks.first?.status,.cancelling)
        runtime.emit(taskID:task.id,instanceID:instance.id,method:"turn/completed",params:["threadId":"native-thread","turn":["id":"native-turn","status":"interrupted"]])
        XCTAssertEqual(model.state.tasks.first?.status,.cancelled)
        XCTAssertTrue(model.canReply(task.id))
        XCTAssertNotNil(model.state.tasks.first?.nativeState?.historyNotice)
        runtime.results["native_prompt"] = ["turnId":"next-turn"]
        let sent = await model.followUp(taskID:task.id,text:"new turn")
        XCTAssertTrue(sent)
        XCTAssertNil(model.state.tasks.first?.nativeState?.historyNotice,"a previous stop check must not describe a new turn")
    }

    @MainActor func testEventWithForeignThreadDoesNotModifyTask() async throws {
        let (model,runtime,_,_,root,instance) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at:root) }
        await model.start(instanceID:instance.id,text:"hello")
        let task = try XCTUnwrap(model.state.tasks.first)
        runtime.emit(taskID:task.id,instanceID:instance.id,method:"item/completed",params:["threadId":"foreign","turnId":"native-turn","item":["id":"bad","type":"agentMessage","text":"must not appear"]])
        XCTAssertFalse(model.state.tasks[0].messages.contains { $0.text == "must not appear" })
    }

    @MainActor func testPromptTimeoutIsUnknownAndNeverAutomaticallyResent() async throws {
        let (model,runtime,_,_,root,instance) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at:root) }
        runtime.failMethod = "native_prompt"
        await model.start(instanceID:instance.id,text:"hello")
        XCTAssertEqual(runtime.requests.filter { $0.0 == "native_prompt" }.count,1)
        XCTAssertEqual(model.state.tasks.first?.status,.unknown)
        XCTAssertEqual(model.state.tasks.first?.sessionID,"native-thread")
    }

    @MainActor func testAuditFailureBlocksNativeTaskSubmission() async throws {
        let (model,runtime,_,audit,root,instance) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at:root) }
        audit.reject = true
        await model.start(instanceID:instance.id,text:"hello")
        XCTAssertFalse(runtime.requests.contains { ["native_start","native_prompt"].contains($0.0) })
        XCTAssertNotNil(model.error)
    }
    @MainActor func testRecoveryMergesStableItemsWithoutResendingPrompt() async throws {
        let (model,runtime,_,_,root,instance) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at:root) }
        await model.start(instanceID:instance.id,text:"hello")
        let id = try XCTUnwrap(model.state.tasks.first?.id)
        runtime.onExit?()
        runtime.results["native_resume"] = ["threadId":"native-thread", "turns":[["id":"native-turn","status":"completed"]],
            "items":[["turnId":"native-turn","item":["id":"reply","type":"agentMessage","text":"done"]]]]
        await model.recoverNative(taskID:id)
        await model.recoverNative(taskID:id)
        XCTAssertEqual(model.state.tasks[0].status,.completed)
        XCTAssertEqual(model.state.tasks[0].messages.filter { $0.runtimeItemID == "reply" }.count,1)
        XCTAssertEqual(runtime.requests.filter { $0.0 == "native_prompt" }.count,1)
        XCTAssertTrue(model.canReply(id))
    }

    @MainActor private func emitPermission(_ runtime: NativeTestRuntime, task: WorkbenchTask, expiry: Date = Date().addingTimeInterval(300)) {
        runtime.emit(taskID:task.id,instanceID:task.instanceID,method:"permission",params:[
            "threadId":"native-thread","turnId":"native-turn","itemId":"tool","requestId":"permission-id",
            "requestHash":"bound-hash","expiresAt":expiry.timeIntervalSince1970,"title":"Command","detail":"printf ok",
            "options":[["id":"accept","title":"Once","kind":"allow_once"],["id":"decline","title":"No","kind":"reject_once"],["id":"cancel","title":"Cancel turn","kind":"cancel"]]])
    }

    @MainActor func testNativeApprovalIsAuditedAndOneShot() async throws {
        let (model,runtime,_,audit,root,instance) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at:root) }
        await model.start(instanceID:instance.id,text:"hello")
        let task = try XCTUnwrap(model.state.tasks.first)
        emitPermission(runtime,task:task)
        let request = try XCTUnwrap(model.permissions.first)
        runtime.beforeRequest = { method, params in
            if method == "native_permission" {
                XCTAssertEqual(params["requestHash"] as? String,"bound-hash")
                XCTAssertTrue(audit.saved.contains { $0["kind"] as? String == "native.approval.requested" })
            }
        }
        await model.respond(request,option:request.options[0])
        await model.respond(request,option:request.options[0])
        XCTAssertEqual(runtime.requests.filter { $0.0 == "native_permission" }.count,1)
        XCTAssertTrue(model.permissions.isEmpty)
    }

    @MainActor func testCompletedToolInvalidatesVisibleApproval() async throws {
        let (model,runtime,_,_,root,instance) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at:root) }
        await model.start(instanceID:instance.id,text:"hello")
        let task = try XCTUnwrap(model.state.tasks.first)
        emitPermission(runtime,task:task)
        XCTAssertEqual(model.permissions.count,1)
        runtime.emit(taskID:task.id,instanceID:instance.id,method:"item/completed",params:["threadId":"native-thread","turnId":"native-turn","item":["id":"tool","type":"commandExecution","command":"printf ok","status":"completed"]])
        XCTAssertTrue(model.permissions.isEmpty)
    }

    @MainActor func testCompletionWhileRecoveringWinsOverOlderSnapshot() async throws {
        let (model,runtime,_,_,root,instance) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at:root) }
        await model.start(instanceID:instance.id,text:"hello")
        let id = try XCTUnwrap(model.state.tasks.first?.id)
        runtime.onExit?()
        runtime.results["native_resume"] = ["threadId":"native-thread", "turnId":"native-turn", "turns":[["id":"native-turn","status":"inProgress"]], "items":[]]
        runtime.beforeRequest = { method, _ in
            if method == "native_resume" { runtime.emit(taskID:id,instanceID:instance.id,method:"turn/completed",params:["threadId":"native-thread","turn":["id":"native-turn","status":"completed"]]) }
        }
        await model.recoverNative(taskID:id)
        XCTAssertEqual(model.state.tasks[0].status,.completed)
    }

    @MainActor func testExpiredApprovalCannotBeSentAndAuditFailureBlocksGrant() async throws {
        let (model,runtime,_,audit,root,instance) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at:root) }
        await model.start(instanceID:instance.id,text:"hello")
        let task = try XCTUnwrap(model.state.tasks.first)
        emitPermission(runtime,task:task,expiry:Date().addingTimeInterval(-1))
        XCTAssertTrue(model.permissions.isEmpty)
        emitPermission(runtime,task:task)
        let request = try XCTUnwrap(model.permissions.first)
        audit.reject = true
        await model.respond(request,option:request.options[0])
        XCTAssertFalse(runtime.requests.contains { $0.0 == "native_permission" })
    }

    @MainActor func testDetachedNativeInstanceRetainsRecoveryConfiguration() async throws {
        let (model,runtime,_,_,root,instance) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at:root) }
        await model.start(instanceID:instance.id,text:"hello")
        runtime.onExit?()
        model.remove(instanceID:instance.id)
        XCTAssertNotNil(model.state.instances.first { $0.id == instance.id })
        XCTAssertNotNil(model.error)
        var changed = instance
        changed.native?.executable = "/bin/echo"
        XCTAssertThrowsError(try model.save(instance:changed,newKey:""))
    }

    @MainActor func testOldTurnCompletionCannotBindToNewPrompt() async throws {
        let (model,runtime,_,_,root,instance) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at:root) }
        await model.start(instanceID:instance.id,text:"hello")
        let task = try XCTUnwrap(model.state.tasks.first)
        runtime.emit(taskID:task.id,instanceID:instance.id,method:"turn/completed",params:["threadId":"native-thread","turn":["id":"native-turn","status":"completed"]])
        runtime.results["native_prompt"] = ["turnId":"second-turn"]
        runtime.beforeRequest = { method, _ in
            if method == "native_prompt" { runtime.emit(taskID:task.id,instanceID:instance.id,method:"turn/completed",params:["threadId":"native-thread","turn":["id":"native-turn","status":"completed"]]) }
        }
        let sent = await model.followUp(taskID:task.id,text:"continue")
        XCTAssertTrue(sent)
        XCTAssertEqual(model.state.tasks[0].status,.running)
        XCTAssertEqual(model.state.tasks[0].nativeState?.turnID,"second-turn")
    }

    @MainActor func testRecoveryDoesNotDoubleApplyDeltasAlreadyInSnapshot() async throws {
        let (model,runtime,_,_,root,instance) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at:root) }
        await model.start(instanceID:instance.id,text:"hello")
        let id = try XCTUnwrap(model.state.tasks.first?.id)
        runtime.onExit?()
        runtime.results["native_resume"] = ["threadId":"native-thread", "turnId":"native-turn", "turns":[["id":"native-turn","status":"inProgress"]],
            "items":[["turnId":"native-turn","item":["id":"reply","type":"agentMessage","text":"hello world"]]]]
        runtime.beforeRequest = { method, _ in
            if method == "native_resume" { runtime.emit(taskID:id,instanceID:instance.id,method:"item/agentMessage/delta",params:["threadId":"native-thread","turnId":"native-turn","itemId":"reply","delta":" world"]) }
        }
        await model.recoverNative(taskID:id)
        XCTAssertEqual(model.state.tasks[0].messages.last(where: { $0.runtimeItemID == "reply" })?.text,"hello world")
    }

    @MainActor func testConfirmedFailedNativeTurnCanReceiveCorrection() async throws {
        let (model,runtime,_,_,root,instance) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at:root) }
        await model.start(instanceID:instance.id,text:"hello")
        let id = try XCTUnwrap(model.state.tasks.first?.id)
        runtime.emit(taskID:id,instanceID:instance.id,method:"turn/completed",params:["threadId":"native-thread","turn":["id":"native-turn","status":"failed"]])
        XCTAssertEqual(model.state.tasks[0].status,.failed)
        XCTAssertTrue(model.canReply(id))
    }

    @MainActor func testApprovalWriteAcknowledgmentIsNotExecutionConfirmation() async throws {
        let (model,runtime,_,_,root,instance) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at:root) }
        await model.start(instanceID:instance.id,text:"hello")
        let task = try XCTUnwrap(model.state.tasks.first)
        emitPermission(runtime,task:task)
        let request = try XCTUnwrap(model.permissions.first)
        await model.respond(request,option:request.options[0])
        XCTAssertEqual(model.state.tasks[0].nativeState?.pendingOperation?.status,.accepted)
        runtime.emit(taskID:task.id,instanceID:instance.id,method:"item/completed",params:["threadId":"native-thread","turnId":"native-turn","item":["id":"tool","type":"commandExecution","status":"completed"]])
        XCTAssertEqual(model.state.tasks[0].nativeState?.pendingOperation?.status,.confirmed)
    }

    @MainActor func testInterruptedTurnWaitsForBackgroundCleanupConfirmation() async throws {
        let (model,runtime,_,_,root,instance) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at:root) }
        await model.start(instanceID:instance.id,text:"hello")
        let id = try XCTUnwrap(model.state.tasks.first?.id)
        runtime.beforeRequest = { method, _ in
            if method == "native_cancel" {
                runtime.emit(taskID:id,instanceID:instance.id,method:"turn/completed",params:["threadId":"native-thread","turn":["id":"native-turn","status":"interrupted"]])
                XCTAssertEqual(model.state.tasks[0].status,.cancelling,"turn confirmation alone does not stop background commands")
            }
        }
        await model.cancel(id)
        XCTAssertEqual(model.state.tasks[0].status,.cancelled)
        XCTAssertEqual(model.state.tasks[0].nativeState?.pendingOperation?.status,.confirmed)
    }

    @MainActor func testCleanupFailureRemainsUnknownDespiteInterruptedTurn() async throws {
        let (model,runtime,_,_,root,instance) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at:root) }
        await model.start(instanceID:instance.id,text:"hello")
        let id = try XCTUnwrap(model.state.tasks.first?.id)
        runtime.results["native_cancel"] = ["requested":true,"backgroundStopped":false]
        runtime.beforeRequest = { method, _ in
            if method == "native_cancel" { runtime.emit(taskID:id,instanceID:instance.id,method:"turn/completed",params:["threadId":"native-thread","turn":["id":"native-turn","status":"interrupted"]]) }
        }
        await model.cancel(id)
        XCTAssertEqual(model.state.tasks[0].status,.unknown)
        runtime.emit(taskID:id,instanceID:instance.id,method:"turn/completed",params:["threadId":"native-thread","turn":["id":"native-turn","status":"interrupted"]])
        XCTAssertEqual(model.state.tasks[0].status,.unknown)
        XCTAssertFalse(model.canReply(id))
    }

    @MainActor func testCompletedTurnCanStopOwnedBackgroundCommandsAfterAudit() async throws {
        let (model,runtime,_,audit,root,instance) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at:root) }
        await model.start(instanceID:instance.id,text:"hello")
        let id = try XCTUnwrap(model.state.tasks.first?.id)
        runtime.emit(taskID:id,instanceID:instance.id,method:"turn/completed",params:["threadId":"native-thread","turn":["id":"native-turn","status":"completed"]])
        runtime.results["native_background_stop"] = ["stopped":true,"terminatedCount":1]
        runtime.beforeRequest = { method, params in
            if method == "native_background_stop" {
                XCTAssertEqual(Set(params.keys),["taskId"])
                XCTAssertTrue(audit.saved.contains { $0["kind"] as? String == "native.interrupt.requested" && $0["scope"] as? String == "backgroundTerminals" })
            }
        }
        await model.stopNativeBackgroundTasks(id)
        XCTAssertEqual(model.state.tasks[0].status,.completed)
        XCTAssertEqual(model.state.tasks[0].nativeState?.pendingOperation?.status,.confirmed)
        XCTAssertTrue(model.state.tasks[0].nativeState?.historyNotice?.contains("后台命令") == true)
    }


    @MainActor func testStaleInterruptFailureCannotOverwriteRecoveredNextTurn() async throws {
        for shouldFail in [true, false] { try await assertStaleControlCannotOverwriteNextTurn(method:"native_cancel", shouldFail:shouldFail) }
    }

    @MainActor func testStaleBackgroundStopFailureCannotOverwriteRecoveredNextTurn() async throws {
        for shouldFail in [true, false] { try await assertStaleControlCannotOverwriteNextTurn(method:"native_background_stop", shouldFail:shouldFail) }
    }

    @MainActor private func assertStaleControlCannotOverwriteNextTurn(method: String, shouldFail: Bool) async throws {
        let (model,runtime,_,_,root,instance) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at:root) }
        await model.start(instanceID:instance.id,text:"hello")
        let id = try XCTUnwrap(model.state.tasks.first?.id)
        if method == "native_background_stop" {
            runtime.emit(taskID:id,instanceID:instance.id,method:"turn/completed",params:["threadId":"native-thread","turn":["id":"native-turn","status":"completed"]])
        }
        runtime.duringRequest = { requested, _ in
            guard requested == method else { return }
            runtime.onExit?()
            runtime.results["native_resume"] = ["threadId":"native-thread","turns":[["id":"native-turn","status":"interrupted"]],"items":[],"backgroundCount":0]
            await model.recoverNative(taskID:id)
            runtime.results["native_prompt"] = ["turnId":"second-turn"]
            let sent = await model.followUp(taskID:id,text:"continue after recovery")
            XCTAssertTrue(sent)
            if shouldFail { throw WorkbenchFailure("old control callback") }
        }
        runtime.results["native_background_stop"] = ["stopped":true,"terminatedCount":0]
        if method == "native_cancel" { await model.cancel(id) }
        else { await model.stopNativeBackgroundTasks(id) }
        XCTAssertEqual(model.state.tasks[0].status,.running)
        XCTAssertEqual(model.state.tasks[0].nativeState?.turnID,"second-turn")
        XCTAssertEqual(model.state.tasks[0].nativeState?.pendingOperation?.kind,.prompt)
        XCTAssertEqual(model.state.tasks[0].nativeState?.pendingOperation?.status,.accepted)
        XCTAssertFalse(model.nativeInterruptUnverified.contains(id))
        XCTAssertFalse(model.nativeBackgroundStopping.contains(id))
    }

    @MainActor func testApprovalCardCancelUsesConfirmedBackgroundCleanup() async throws {
        let (model,runtime,_,audit,root,instance) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at:root) }
        await model.start(instanceID:instance.id,text:"hello")
        let task = try XCTUnwrap(model.state.tasks.first)
        emitPermission(runtime,task:task)
        let request = try XCTUnwrap(model.permissions.first)
        let cancel = try XCTUnwrap(request.options.first { $0.id == "cancel" })
        runtime.beforeRequest = { method, _ in
            if method == "native_cancel" {
                XCTAssertTrue(audit.saved.contains { $0["kind"] as? String == "native.approval.cancelRequested" && $0["requestHash"] as? String == "bound-hash" })
                runtime.emit(taskID:task.id,instanceID:instance.id,method:"turn/completed",params:["threadId":"native-thread","turn":["id":"native-turn","status":"interrupted"]])
                XCTAssertEqual(model.state.tasks[0].status,.cancelling)
            }
        }
        await model.respond(request,option:cancel)
        XCTAssertEqual(runtime.requests.filter { $0.0 == "native_cancel" }.count,1)
        XCTAssertFalse(runtime.requests.contains { $0.0 == "native_permission" })
        XCTAssertEqual(model.state.tasks[0].status,.cancelled)
        XCTAssertTrue(model.permissions.isEmpty)
    }


    @MainActor func testApprovalCannotSupersedePendingInterrupt() async throws {
        let (model,runtime,_,_,root,instance) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at:root) }
        await model.start(instanceID:instance.id,text:"hello")
        let task = try XCTUnwrap(model.state.tasks.first)
        emitPermission(runtime,task:task)
        let request = try XCTUnwrap(model.permissions.first)
        runtime.duringRequest = { method, _ in
            if method == "native_cancel" {
                await model.respond(request,option:request.options[0])
                runtime.emit(taskID:task.id,instanceID:instance.id,method:"turn/completed",params:["threadId":"native-thread","turn":["id":"native-turn","status":"interrupted"]])
            }
        }
        await model.cancel(task.id)
        XCTAssertFalse(runtime.requests.contains { $0.0 == "native_permission" })
        XCTAssertEqual(model.state.tasks[0].status,.cancelled)
        XCTAssertFalse(model.nativeInterruptPending.contains(task.id))
    }

    @MainActor func testDetachExcludesFollowUpAndRecoveryUntilItCompletes() async throws {
        let (model,runtime,_,_,root,instance) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at:root) }
        await model.start(instanceID:instance.id,text:"hello")
        let task = try XCTUnwrap(model.state.tasks.first)
        runtime.emit(taskID:task.id,instanceID:instance.id,method:"turn/completed",params:["threadId":"native-thread","turn":["id":"native-turn","status":"completed"]])
        runtime.duringRequest = { method, _ in
            if method == "native_detach" {
                XCTAssertFalse(model.canReply(task.id))
                let sent = await model.followUp(taskID:task.id,text:"must not send while detaching")
                XCTAssertFalse(sent)
                await model.recoverNative(taskID:task.id)
            }
        }
        await model.detachNative(task.id)
        XCTAssertEqual(runtime.requests.filter { $0.0 == "native_prompt" }.count,1)
        XCTAssertFalse(runtime.requests.contains { $0.0 == "native_resume" })
        XCTAssertFalse(model.isLive(task.id))
        XCTAssertEqual(model.state.tasks[0].nativeState?.connection,.disconnected)
    }

    @MainActor func testRecoveryExcludesDetachWhileSnapshotIsPending() async throws {
        let (model,runtime,_,_,root,instance) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at:root) }
        await model.start(instanceID:instance.id,text:"hello")
        let task = try XCTUnwrap(model.state.tasks.first)
        runtime.onExit?()
        runtime.results["native_resume"] = ["threadId":"native-thread","turns":[["id":"native-turn","status":"completed"]],"items":[]]
        runtime.duringRequest = { method, _ in
            if method == "native_resume" { await model.detachNative(task.id) }
        }
        await model.recoverNative(taskID:task.id)
        XCTAssertFalse(runtime.requests.contains { $0.0 == "native_detach" })
        XCTAssertTrue(model.isLive(task.id))
        XCTAssertTrue(model.canReply(task.id))
        XCTAssertEqual(model.state.tasks[0].nativeState?.connection,.connected)
    }

}
