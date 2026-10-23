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

    @MainActor func testCompletedTurnKeepsFreshBackgroundCountSeparateFromTerminalState() async throws {
        let (model,runtime,_,audit,root,instance) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at:root) }
        await model.start(instanceID:instance.id,text:"hello")
        let id = try XCTUnwrap(model.state.tasks.first?.id)
        runtime.emit(taskID:id,instanceID:instance.id,method:"turn/completed",params:["threadId":"native-thread","turn":["id":"native-turn","status":"completed"]])
        XCTAssertNil(model.freshNativeBackgroundObservation(id))
        XCTAssertEqual(model.nativeBackgroundStatusTitle(id),"后台命令待核对")
        runtime.results["native_background_status"] = ["threadId":"native-thread","count":1,"itemIds":["background-item"]]
        let auditCount = audit.saved.count
        await model.refreshNativeBackgroundStatus(id)
        XCTAssertEqual(model.freshNativeBackgroundObservation(id)?.count,1)
        XCTAssertEqual(model.freshNativeBackgroundObservation(id)?.itemIDs,["background-item"])
        XCTAssertEqual(model.nativeBackgroundStatusTitle(id),"后台命令：1 个")
        XCTAssertEqual(model.state.tasks[0].status,.completed)
        XCTAssertTrue(model.canStopNativeBackgroundTasks(id))
        await model.refreshNativeBackgroundStatus(id)
        XCTAssertEqual(audit.saved.count,auditCount,"routine read-only polls do not append audit records")
        let params = try XCTUnwrap(runtime.requests.last?.1)
        XCTAssertEqual(Set(params.keys),["taskId"])
        let snapshot = String(decoding:try JSONEncoder().encode(model.state),as:UTF8.self)
        XCTAssertFalse(snapshot.contains("background-item"),"current observations never enter the persisted snapshot")
    }

    @MainActor func testBackgroundFailureMeansUnknownWithoutChangingCompletedTurn() async throws {
        let (model,runtime,_,_,root,instance) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at:root) }
        await model.start(instanceID:instance.id,text:"hello")
        let id = try XCTUnwrap(model.state.tasks.first?.id)
        model.mutate(id) { $0.status = .completed }
        runtime.results["native_background_status"] = ["threadId":"native-thread","count":0,"itemIds":[]]
        await model.refreshNativeBackgroundStatus(id)
        XCTAssertEqual(model.freshNativeBackgroundObservation(id)?.count,0)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let original = try encoder.encode(model.state.tasks[0])
        runtime.failMethod = "native_background_status"
        await model.refreshNativeBackgroundStatus(id)
        XCTAssertNil(model.freshNativeBackgroundObservation(id))
        XCTAssertEqual(model.nativeBackgroundStatusTitle(id),"后台命令待核对")
        XCTAssertEqual(try encoder.encode(model.state.tasks[0]),original)
        XCTAssertNil(model.error)
    }

    @MainActor func testBackgroundObservationExpiresAfterTenSecondsAndValidatesResponse() async throws {
        let (model,runtime,_,_,root,instance) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at:root) }
        await model.start(instanceID:instance.id,text:"hello")
        let id = try XCTUnwrap(model.state.tasks.first?.id)
        runtime.results["native_background_status"] = ["threadId":"native-thread","count":0,"itemIds":[]]
        await model.refreshNativeBackgroundStatus(id)
        let checked = try XCTUnwrap(model.freshNativeBackgroundObservation(id)?.checkedAt)
        XCTAssertNotNil(model.freshNativeBackgroundObservation(id,now:checked.addingTimeInterval(9)))
        XCTAssertNil(model.freshNativeBackgroundObservation(id,now:checked.addingTimeInterval(11)))
        for result: [String:Any] in [["threadId":"foreign","count":0,"itemIds":[]], ["threadId":"native-thread","count":1,"itemIds":[]], ["threadId":"native-thread","count":true,"itemIds":["i"]], ["threadId":"native-thread","count":2,"itemIds":["i","i"]]] {
            runtime.results["native_background_status"] = result
            await model.refreshNativeBackgroundStatus(id)
            XCTAssertNil(model.freshNativeBackgroundObservation(id))
        }
    }

    @MainActor func testConcurrentBackgroundRefreshCoalescesWithoutCancellingTurn() async throws {
        let (model,runtime,_,_,root,instance) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at:root) }
        await model.start(instanceID:instance.id,text:"hello")
        let id = try XCTUnwrap(model.state.tasks.first?.id)
        runtime.results["native_background_status"] = ["threadId":"native-thread","count":0,"itemIds":[]]
        runtime.duringRequest = { method, _ in
            guard method == "native_background_status" else { return }
            XCTAssertEqual(model.nativeBackgroundStatusTitle(id),"正在核对…")
            await model.refreshNativeBackgroundStatus(id)
        }
        await model.refreshNativeBackgroundStatus(id)
        XCTAssertEqual(runtime.requests.filter { $0.0 == "native_background_status" }.count,1)
        XCTAssertEqual(model.state.tasks[0].status,.running)
    }

    @MainActor func testBackgroundOldSuccessAndFailureCannotPublishAcrossContextChanges() async throws {
        for change in ["disconnect","resume","prompt","stop","execution","shutdown"] {
            for fail in [false,true] {
                let (model,runtime,_,_,root,instance) = try fixture()
                await model.start(instanceID:instance.id,text:"hello")
                let id = try XCTUnwrap(model.state.tasks.first?.id)
                model.mutate(id) { $0.status = .completed }
                runtime.results["native_background_status"] = ["threadId":"native-thread","count":7,"itemIds":(0..<7).map { "old-\($0)" }]
                runtime.results["native_resume"] = ["threadId":"native-thread","turns":[["id":"native-turn","status":"completed"]],"items":[],"backgroundCount":0]
                runtime.results["native_background_stop"] = ["stopped":true,"terminatedCount":0]
                runtime.duringRequest = { method, _ in
                    guard method == "native_background_status" else { return }
                    switch change {
                    case "disconnect": runtime.onExit?()
                    case "resume": await model.recoverNative(taskID:id)
                    case "prompt": _ = await model.followUp(taskID:id,text:"next")
                    case "stop": await model.stopNativeBackgroundTasks(id)
                    case "execution": model.mutate(id) { $0.nativeState?.executionID = UUID() }
                    default: model.shutdown()
                    }
                    if fail { throw WorkbenchFailure("old failure") }
                }
                await model.refreshNativeBackgroundStatus(id)
                XCTAssertNil(model.freshNativeBackgroundObservation(id),"\(change) fail=\(fail)")
                XCTAssertFalse(model.state.tasks[0].messages.contains { $0.text.contains("old failure") })
                if change != "shutdown" { model.shutdown() }
                try? FileManager.default.removeItem(at:root)
            }
        }
    }

    @MainActor func testVisibleBackgroundObservationRejectsResultAfterViewExit() async throws {
        let (model,runtime,_,_,root,instance) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at:root) }
        await model.start(instanceID:instance.id,text:"hello")
        let id = try XCTUnwrap(model.state.tasks.first?.id)
        runtime.results["native_background_status"] = ["threadId":"native-thread","count":0,"itemIds":[]]
        let token = model.beginNativeBackgroundObservation(id)
        runtime.duringRequest = { method, _ in
            if method == "native_background_status" { model.endNativeBackgroundObservation(id,token:token) }
        }
        await model.refreshNativeBackgroundStatus(id,visibilityToken:token)
        XCTAssertNil(model.freshNativeBackgroundObservation(id))
        let count = runtime.requests.count
        await model.refreshNativeBackgroundStatus(id,visibilityToken:token)
        XCTAssertEqual(runtime.requests.count,count)
    }

    @MainActor func testCompletionQueuesFreshVisibleReadUntilUncancelledOldReadReleasesSlot() async throws {
        let (model,runtime,_,_,root,instance) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at:root) }
        await model.start(instanceID:instance.id,text:"hello")
        let id = try XCTUnwrap(model.state.tasks.first?.id)
        var releaseOld: CheckedContinuation<Void,Never>?
        var readCount = 0, activeReads = 0, maximumActiveReads = 0
        runtime.duringRequest = { method, _ in
            guard method == "native_background_status" else { return }
            readCount += 1; activeReads += 1; maximumActiveReads = max(maximumActiveReads,activeReads)
            if readCount == 1 {
                await withCheckedContinuation { releaseOld = $0 }
                runtime.results[method] = ["threadId":"native-thread","count":1,"itemIds":["stale-item"]]
            } else { runtime.results[method] = ["threadId":"native-thread","count":0,"itemIds":[]] }
            activeReads -= 1
        }
        let oldToken = model.beginNativeBackgroundObservation(id)
        let old = Task { await model.refreshNativeBackgroundStatus(id,visibilityToken:oldToken) }
        for _ in 0..<100 where releaseOld == nil { await Task.yield() }
        XCTAssertNotNil(releaseOld)
        old.cancel() // The runtime deliberately ignores this cancellation until its response arrives.
        runtime.emit(taskID:id,instanceID:instance.id,method:"turn/completed",params:["threadId":"native-thread","turn":["id":"native-turn","status":"completed"]])
        let currentToken = model.beginNativeBackgroundObservation(id)
        let current = Task { await model.refreshNativeBackgroundStatus(id,visibilityToken:currentToken) }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(readCount,1,"the new visible request must wait for the old IPC slot")
        releaseOld?.resume(); await old.value; await current.value
        XCTAssertEqual(readCount,2,"completion refresh must run immediately after the old slot releases, with no five-second poll sleep")
        XCTAssertEqual(maximumActiveReads,1)
        XCTAssertEqual(model.freshNativeBackgroundObservation(id)?.count,0)
        XCTAssertEqual(model.freshNativeBackgroundObservation(id)?.itemIDs,[])
        XCTAssertEqual(model.state.tasks[0].status,.completed)
    }

    @MainActor func testQueuedVisibleRefreshDropsWhenHiddenCancelledOrBindingChanges() async throws {
        for invalidation in ["hidden","cancelled","binding"] {
            let (model,runtime,_,_,root,instance) = try fixture()
            await model.start(instanceID:instance.id,text:"hello")
            let id = try XCTUnwrap(model.state.tasks.first?.id)
            var releaseOld: CheckedContinuation<Void,Never>?
            var readCount = 0
            runtime.results["native_background_status"] = ["threadId":"native-thread","count":1,"itemIds":["stale-item"]]
            runtime.duringRequest = { method, _ in
                guard method == "native_background_status" else { return }
                readCount += 1
                if readCount == 1 { await withCheckedContinuation { releaseOld = $0 } }
            }
            let oldToken = model.beginNativeBackgroundObservation(id)
            let old = Task { await model.refreshNativeBackgroundStatus(id,visibilityToken:oldToken) }
            for _ in 0..<100 where releaseOld == nil { await Task.yield() }
            XCTAssertNotNil(releaseOld)
            runtime.emit(taskID:id,instanceID:instance.id,method:"turn/completed",params:["threadId":"native-thread","turn":["id":"native-turn","status":"completed"]])
            let token = model.beginNativeBackgroundObservation(id)
            let current = Task { await model.refreshNativeBackgroundStatus(id,visibilityToken:token) }
            for _ in 0..<10 { await Task.yield() }
            switch invalidation {
            case "hidden": model.endNativeBackgroundObservation(id,token:token)
            case "cancelled": current.cancel()
            default: model.mutate(id) { $0.nativeState?.executionID = UUID() }
            }
            releaseOld?.resume(); await old.value; await current.value
            XCTAssertEqual(readCount,1,invalidation)
            XCTAssertNil(model.freshNativeBackgroundObservation(id),invalidation)
            model.shutdown(); try? FileManager.default.removeItem(at:root)
        }
    }

    @MainActor func testOldViewExitCannotInvalidateNewVisibleObservation() async throws {
        let (model,runtime,_,_,root,instance) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at:root) }
        await model.start(instanceID:instance.id,text:"hello")
        let id = try XCTUnwrap(model.state.tasks.first?.id)
        let old = model.beginNativeBackgroundObservation(id)
        let current = model.beginNativeBackgroundObservation(id)
        runtime.results["native_background_status"] = ["threadId":"native-thread","count":0,"itemIds":[]]
        await model.refreshNativeBackgroundStatus(id,visibilityToken:current)
        model.endNativeBackgroundObservation(id,token:old)
        XCTAssertEqual(model.freshNativeBackgroundObservation(id)?.count,0)
        XCTAssertEqual(model.nativeBackgroundVisibility[id],current)
        model.endNativeBackgroundObservation(id,token:current)
        XCTAssertNil(model.freshNativeBackgroundObservation(id))
    }

    @MainActor func testBackgroundReadinessAndStopConflictGuards() async throws {
        let (model,runtime,_,_,root,instance) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at:root) }
        await model.start(instanceID:instance.id,text:"hello")
        let id = try XCTUnwrap(model.state.tasks.first?.id)
        XCTAssertFalse(model.canStopNativeBackgroundTasks(id))
        model.mutate(id) { $0.status = .completed }
        XCTAssertTrue(model.canStopNativeBackgroundTasks(id))
        model.nativeInterruptPending.insert(id)
        XCTAssertFalse(model.canStopNativeBackgroundTasks(id))
        model.nativeInterruptPending.remove(id)
        let count = runtime.requests.count
        model.loadFailed = true
        await model.refreshNativeBackgroundStatus(id)
        XCTAssertFalse(model.canStopNativeBackgroundTasks(id))
        XCTAssertEqual(runtime.requests.count,count)
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

    @MainActor func testLateKnownOldTurnCompletionUpdatesOnlyItsProcess() async throws {
        let (model,runtime,_,_,root,instance) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at:root) }
        await model.start(instanceID:instance.id,text:"hello")
        let id = try XCTUnwrap(model.state.tasks.first?.id)
        runtime.emit(taskID:id,instanceID:instance.id,method:"item/started",params:["threadId":"native-thread","turnId":"native-turn","item":["id":"old-tool","type":"commandExecution","status":"inProgress"]])
        model.mutate(id) { $0.nativeState?.turnID = "next-turn"; $0.status = .running }
        for (itemID,turn) in [("old-tool","wrong-turn"),("unknown","native-turn"),("old-tool","native-turn")] {
            runtime.emit(taskID:id,instanceID:instance.id,method:"item/completed",params:["threadId":"native-thread","turnId":turn,"item":["id":itemID,"type":"commandExecution","status":"completed"]])
        }
        let task = try XCTUnwrap(model.state.tasks.first)
        emitPermission(runtime,task:task)
        XCTAssertTrue(model.permissions.isEmpty,"old approvals remain rejected")
        XCTAssertEqual(task.nativeState?.items.count,1)
        XCTAssertEqual(task.nativeState?.items.first?.status,"completed")
        XCTAssertEqual(task.nativeState?.turnID,"next-turn")
        XCTAssertEqual(task.status,.running)
    }

    @MainActor func testFinalItemSurvivesOldStartedSnapshotAndDelta() async throws {
        let (model,runtime,_,_,root,instance) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at:root) }
        await model.start(instanceID:instance.id,text:"hello")
        let id = try XCTUnwrap(model.state.tasks.first?.id)
        runtime.emit(taskID:id,instanceID:instance.id,method:"item/completed",params:["threadId":"native-thread","turnId":"native-turn","item":["id":"tool","type":"commandExecution","status":"completed","aggregatedOutput":"final"]])
        runtime.emit(taskID:id,instanceID:instance.id,method:"item/started",params:["threadId":"native-thread","turnId":"native-turn","item":["id":"tool","type":"commandExecution","status":"inProgress","aggregatedOutput":"old"]])
        runtime.emit(taskID:id,instanceID:instance.id,method:"item/commandExecution/outputDelta",params:["threadId":"native-thread","turnId":"native-turn","itemId":"tool","delta":"old-delta"])
        model.mergeNativeItem(id,item:["id":"tool","type":"commandExecution","status":"inProgress"],turnID:"native-turn")
        XCTAssertEqual(model.state.tasks[0].nativeState?.items.first?.status,"completed")
        XCTAssertEqual(model.state.tasks[0].nativeState?.items.first?.detail,"final")
    }

    @MainActor func testHistoryWithoutValidStatusNeverDefaultsToCompleted() async throws {
        let (model,_,_,_,root,instance) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at:root) }
        await model.start(instanceID:instance.id,text:"hello")
        let id = try XCTUnwrap(model.state.tasks.first?.id)
        model.mergeNativeItem(id,item:["id":"missing","type":"commandExecution"],turnID:"native-turn")
        XCTAssertEqual(model.state.tasks[0].nativeState?.items.first?.status,"unknown")
    }

    @MainActor func testCompletionReconcilesOnlyProcessEvidenceWithoutMessagesOrAuditRewrite() async throws {
        let (model,runtime,_,audit,root,instance) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at:root) }
        await model.start(instanceID:instance.id,text:"hello")
        let id = try XCTUnwrap(model.state.tasks.first?.id)
        model.mergeNativeItem(id,item:["id":"tool","type":"commandExecution","command":"original command","status":"inProgress"],turnID:"native-turn")
        model.mergeNativeItem(id,item:["id":"reply","type":"agentMessage","text":"original reply"],turnID:"native-turn")
        runtime.results["native_reconcile"] = ["threadId":"native-thread","turns":[["id":"native-turn","status":"completed"]],"items":[
            ["turnId":"native-turn","item":["id":"tool","type":"commandExecution","command":"replacement command","status":"completed"]],
            ["turnId":"native-turn","item":["id":"reply","type":"agentMessage","text":"replacement reply"]]]]
        runtime.emit(taskID:id,instanceID:instance.id,method:"turn/completed",params:["threadId":"native-thread","turn":["id":"native-turn","status":"completed"]])
        let messages = model.state.tasks[0].messages
        let auditBytes = try JSONSerialization.data(withJSONObject:audit.saved,options:.sortedKeys)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(runtime.requests.contains { $0.0 == "native_reconcile" },"completion schedules one bounded official read")
        XCTAssertEqual(model.state.tasks[0].nativeState?.items.first?.status,"inProgress")
        XCTAssertEqual(model.state.tasks[0].nativeState?.items.first?.reconciledStatus,"completed")
        XCTAssertEqual(model.state.tasks[0].nativeState?.items.first?.detail,"original command")
        XCTAssertEqual(model.state.tasks[0].messages,messages)
        XCTAssertEqual(try JSONSerialization.data(withJSONObject:audit.saved,options:.sortedKeys),auditBytes)
        XCTAssertEqual(model.state.tasks[0].status,.completed)
    }

    @MainActor func testTurnFinalDoesNotRegressOnLateStarted() async throws {
        let (model,runtime,_,_,root,instance) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at:root) }
        await model.start(instanceID:instance.id,text:"hello")
        let id = try XCTUnwrap(model.state.tasks.first?.id)
        runtime.emit(taskID:id,instanceID:instance.id,method:"turn/completed",params:["threadId":"native-thread","turn":["id":"native-turn","status":"completed"]])
        runtime.emit(taskID:id,instanceID:instance.id,method:"turn/started",params:["threadId":"native-thread","turn":["id":"native-turn","status":"inProgress"]])
        XCTAssertEqual(model.state.tasks[0].status,.completed)
    }

    @MainActor func testHistoryReadPreservesRawProcessAndShowsFinalOnlyWithOfficialStatus() async throws {
        let (model,runtime,_,audit,root,instance) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at:root) }
        await model.start(instanceID:instance.id,text:"hello")
        let id = try XCTUnwrap(model.state.tasks.first?.id)
        model.mergeNativeItem(id,item:["id":"tool","type":"commandExecution","status":"inProgress","command":"original"],turnID:"native-turn")
        model.mutate(id) { $0.status = .completed }
        let originalMessages = model.state.tasks[0].messages
        let originalAudit = try JSONSerialization.data(withJSONObject:audit.saved,options:.sortedKeys)
        for status in [nil,"bogus","error","cancelled","completed"] as [String?] {
            var official: [String:Any] = ["id":"tool","type":"commandExecution"]
            official["status"] = status
            runtime.results["native_reconcile"] = ["threadId":"native-thread","turns":[["id":"native-turn","status":"completed"]],"items":[["turnId":"native-turn","item":official]]]
            await model.reconcileNativeHistory(id)
            let item = try XCTUnwrap(model.state.tasks[0].nativeState?.items.first)
            XCTAssertEqual(item.status,"inProgress","history queries keep the original process field")
            XCTAssertEqual(model.nativeProcessStatusTitle(id,item:item),status == "completed" ? "已完成" : "待核对（最后记录：执行中）")
        }
        XCTAssertEqual(model.state.tasks[0].messages,originalMessages)
        XCTAssertEqual(try JSONSerialization.data(withJSONObject:audit.saved,options:.sortedKeys),originalAudit)
        XCTAssertEqual(model.state.tasks[0].status,.completed)
        let request = try XCTUnwrap(runtime.requests.last)
        XCTAssertEqual(request.0,"native_reconcile"); XCTAssertEqual(Set(request.1.keys),["taskId"])
    }

    @MainActor func testZeroBackgroundAndExpiredObservationNeverCompleteHistoricalItem() async throws {
        let (model,runtime,_,_,root,instance) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at:root) }
        await model.start(instanceID:instance.id,text:"hello")
        let id = try XCTUnwrap(model.state.tasks.first?.id)
        model.mergeNativeItem(id,item:["id":"tool","type":"commandExecution","status":"inProgress"],turnID:"native-turn")
        model.mutate(id) { $0.status = .completed }
        let item = try XCTUnwrap(model.state.tasks[0].nativeState?.items.first)
        XCTAssertEqual(model.nativeProcessStatusTitle(id,item:item),"待核对（最后记录：执行中）")
        runtime.results["native_background_status"] = ["threadId":"native-thread","count":1,"itemIds":["tool"]]
        await model.refreshNativeBackgroundStatus(id)
        let checked = try XCTUnwrap(model.freshNativeBackgroundObservation(id)?.checkedAt)
        XCTAssertEqual(model.nativeProcessStatusTitle(id,item:item,now:checked),"后台运行")
        XCTAssertEqual(model.nativeProcessStatusTitle(id,item:item,now:checked.addingTimeInterval(11)),"待核对（最后记录：执行中）")
        runtime.results["native_background_status"] = ["threadId":"native-thread","count":0,"itemIds":[]]
        await model.refreshNativeBackgroundStatus(id)
        XCTAssertEqual(model.nativeProcessStatusTitle(id,item:item),"待核对（最后记录：执行中）")
        XCTAssertFalse(item.hasTerminalEvidence)
    }

    @MainActor func testFreshBackgroundEvidenceOverridesFinalDisplayWithoutChangingTerminalEvidence() async throws {
        for (status, title) in [("completed", "已完成"), ("failed", "失败")] {
            let (model,runtime,_,_,root,instance) = try fixture()
            defer { model.shutdown(); try? FileManager.default.removeItem(at:root) }
            await model.start(instanceID:instance.id,text:"hello")
            let id = try XCTUnwrap(model.state.tasks.first?.id)
            model.mergeNativeItem(id,item:["id":"tool","type":"commandExecution","status":status,"aggregatedOutput":"original final"],turnID:"native-turn")
            model.mutate(id) { $0.status = .completed }
            let final = try XCTUnwrap(model.state.tasks[0].nativeState?.items.first)
            XCTAssertTrue(final.hasTerminalEvidence)
            XCTAssertEqual(model.nativeProcessStatusTitle(id,item:final),title,"unknown background preserves the final display")
            runtime.results["native_background_status"] = ["threadId":"native-thread","count":1,"itemIds":["tool"]]
            await model.refreshNativeBackgroundStatus(id)
            let checked = try XCTUnwrap(model.freshNativeBackgroundObservation(id)?.checkedAt)
            XCTAssertEqual(model.nativeProcessStatusTitle(id,item:final,now:checked),"后台运行",status)
            XCTAssertEqual(model.nativeProcessStatusTitle(id,item:final,now:checked.addingTimeInterval(11)),title,"expired observation preserves final evidence")
            runtime.failMethod = "native_background_status"
            await model.refreshNativeBackgroundStatus(id)
            XCTAssertEqual(model.nativeProcessStatusTitle(id,item:final),title,"failed read is unknown, not a reason to remove final evidence")
            runtime.failMethod = nil
            runtime.results["native_background_status"] = ["threadId":"native-thread","count":0,"itemIds":[]]
            await model.refreshNativeBackgroundStatus(id)
            XCTAssertEqual(model.nativeProcessStatusTitle(id,item:final),title,"zero background processes cannot rewrite final evidence")
            runtime.results["native_background_status"] = ["threadId":"native-thread","count":1,"itemIds":["tool"]]
            await model.refreshNativeBackgroundStatus(id)
            model.mutate(id) { $0.nativeState?.executionID = UUID() }
            XCTAssertEqual(model.nativeProcessStatusTitle(id,item:final),title,"a different binding cannot override final evidence")
            XCTAssertEqual(model.state.tasks[0].nativeState?.items.first,final)
            XCTAssertEqual(model.state.tasks[0].status,.completed)
        }
    }

    @MainActor func testStaleReconciliationCannotPolluteNewBindingOrNewFinal() async throws {
        for change in ["execution","turn","thread","connection","operation","final"] {
            let (model,runtime,_,_,root,instance) = try fixture()
            defer { model.shutdown(); try? FileManager.default.removeItem(at:root) }
            await model.start(instanceID:instance.id,text:"hello")
            let id = try XCTUnwrap(model.state.tasks.first?.id)
            model.mergeNativeItem(id,item:["id":"tool","type":"commandExecution","status":"inProgress"],turnID:"native-turn")
            runtime.results["native_reconcile"] = ["threadId":"native-thread","turns":[["id":"native-turn","status":"inProgress"]],"items":[["turnId":"native-turn","item":["id":"tool","type":"commandExecution","status":"completed"]]]]
            runtime.duringRequest = { method,_ in
                guard method == "native_reconcile" else { return }
                if change == "final" {
                    runtime.emit(taskID:id,instanceID:instance.id,method:"item/completed",params:["threadId":"native-thread","turnId":"native-turn","item":["id":"tool","type":"commandExecution","status":"failed","aggregatedOutput":"final error"]])
                } else if change == "connection" { model.nativeConnectionGenerations[instance.id] = UUID() }
                else { model.mutate(id) { task in
                    switch change {
                    case "execution": task.nativeState?.executionID = UUID()
                    case "turn": task.nativeState?.turnID = "new-turn"
                    case "thread": task.nativeState?.threadID = "new-thread"
                    default: task.nativeState?.pendingOperation = .init(kind:.prompt,targetID:"new-operation")
                    }
                } }
            }
            await model.reconcileNativeHistory(id)
            let saved = try XCTUnwrap(model.state.tasks[0].nativeState)
            XCTAssertEqual(saved.items[0].status,change == "final" ? "failed" : "inProgress",change)
            if change == "final" { XCTAssertEqual(model.nativeProcessStatusTitle(id,item:saved.items[0]),"失败"); XCTAssertEqual(saved.items[0].detail,"final error") }
            else { XCTAssertNil(saved.lastReconciledAt,change) }
        }
    }

    @MainActor func testFailedAndMalformedReconciliationLeaveTaskAndAuditUnchanged() async throws {
        let (model,runtime,_,audit,root,instance) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at:root) }
        await model.start(instanceID:instance.id,text:"hello")
        let id = try XCTUnwrap(model.state.tasks.first?.id)
        model.mutate(id) { $0.status = .completed }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let original = try encoder.encode(model.state.tasks[0])
        let auditBytes = try JSONSerialization.data(withJSONObject:audit.saved,options:.sortedKeys)
        for response: [String:Any] in [[:],["threadId":"foreign","turns":[],"items":[]],["threadId":"native-thread","turns":[["id":"same"],["id":"same"]],"items":[]],["threadId":"native-thread","turns":[],"items":[["turnId":"old","item":["id":"same","type":"commandExecution"]],["turnId":"old","item":["id":"same","type":"commandExecution"]]]]] {
            runtime.results["native_reconcile"] = response
            await model.reconcileNativeHistory(id)
            XCTAssertEqual(try encoder.encode(model.state.tasks[0]),original)
        }
        runtime.failMethod = "native_reconcile"
        await model.reconcileNativeHistory(id)
        XCTAssertEqual(try encoder.encode(model.state.tasks[0]),original)
        XCTAssertEqual(try JSONSerialization.data(withJSONObject:audit.saved,options:.sortedKeys),auditBytes)
        XCTAssertNil(model.error)
    }

    @MainActor func testLateKnownCompletionDuringPromptAcceptanceGapRemainsProcessOnly() async throws {
        let (model,runtime,_,_,root,instance) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at:root) }
        await model.start(instanceID:instance.id,text:"hello")
        let id = try XCTUnwrap(model.state.tasks.first?.id)
        model.mergeNativeItem(id,item:["id":"old","type":"commandExecution","status":"inProgress"],turnID:"native-turn")
        model.mutate(id) { $0.nativeState?.turnID = nil; $0.nativeState?.pendingOperation = .init(kind:.prompt,targetID:"native-thread") }
        runtime.emit(taskID:id,instanceID:instance.id,method:"item/completed",params:["threadId":"native-thread","turnId":"native-turn","item":["id":"old","type":"commandExecution","status":"completed"]])
        XCTAssertEqual(model.state.tasks[0].nativeState?.items[0].status,"completed")
        XCTAssertNil(model.state.tasks[0].nativeState?.turnID)
        XCTAssertEqual(model.state.tasks[0].nativeState?.pendingOperation?.status,.requested)
    }

    @MainActor func testCompletionTimestampEvidenceIsStrictAndDoesNotInventTypedStatus() async throws {
        let (model,runtime,_,_,root,instance) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at:root) }
        await model.start(instanceID:instance.id,text:"hello")
        let id = try XCTUnwrap(model.state.tasks.first?.id)
        model.mutate(id) {
            $0.status = .completed
            $0.nativeState?.upsert(.init(id:"search",turnID:"native-turn",kind:"webSearch",title:"search",detail:"raw",status:"completed"))
            $0.nativeState?.upsert(.init(id:"tool",turnID:"native-turn",kind:"commandExecution",title:"command",detail:"raw",status:"inProgress"))
        }
        let invalid: [Any?] = [nil,true,-1,1.5,Double.nan,Double.infinity,Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000,"123"]
        for value in invalid {
            var entry: [String:Any] = ["turnId":"native-turn","item":["id":"search","type":"webSearch"]]
            entry["completedAtMs"] = value
            runtime.results["native_reconcile"] = ["threadId":"native-thread","turns":[],"items":[entry]]
            await model.reconcileNativeHistory(id)
            XCTAssertFalse(try XCTUnwrap(model.state.tasks[0].nativeState?.items.first).hasTerminalEvidence)
        }
        runtime.results["native_reconcile"] = ["threadId":"native-thread","turns":[],"items":[
            ["turnId":"native-turn","completedAtMs":1000,"item":["id":"search","type":"webSearch"]],
            ["turnId":"native-turn","completedAtMs":1000,"item":["id":"tool","type":"commandExecution"]]]]
        await model.reconcileNativeHistory(id)
        let items = try XCTUnwrap(model.state.tasks[0].nativeState?.items)
        XCTAssertEqual(items[0].status,"completed","legacy raw status stays intact")
        XCTAssertEqual(model.nativeProcessStatusTitle(id,item:items[0]),"已完成","valid official completion time supplies evidence for a statusless kind")
        XCTAssertEqual(model.nativeProcessStatusTitle(id,item:items[1]),"待核对（最后记录：执行中）","typed commands still require a valid official status")
    }

    @MainActor func testRecoverySnapshotCannotReviveAnObservedFinalTurn() async throws {
        let (model,runtime,_,_,root,instance) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at:root) }
        await model.start(instanceID:instance.id,text:"hello")
        let id = try XCTUnwrap(model.state.tasks.first?.id)
        model.mutate(id) { $0.status = .completed; $0.nativeState?.recordTurnStatus("native-turn",status:"completed") }
        runtime.onExit?()
        runtime.results["native_resume"] = ["threadId":"native-thread","turnId":"native-turn","turns":[["id":"native-turn","status":"inProgress"]],"items":[]]
        await model.recoverNative(taskID:id)
        XCTAssertEqual(model.state.tasks[0].status,.completed)
        XCTAssertEqual(model.state.tasks[0].nativeState?.turnStatuses?["native-turn"],"completed")
    }

    @MainActor func testRecoveryWithoutOfficialTurnStatusDoesNotInventSuccess() async throws {
        let (model,runtime,_,_,root,instance) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at:root) }
        await model.start(instanceID:instance.id,text:"hello")
        let id = try XCTUnwrap(model.state.tasks.first?.id)
        runtime.onExit?()
        runtime.results["native_resume"] = ["threadId":"native-thread","turns":[],"items":[]]
        await model.recoverNative(taskID:id)
        XCTAssertEqual(model.state.tasks[0].status,.unknown)
    }

    @MainActor func testReconciledFailureAppearsInProcessSummaryWithoutChangingRawStatus() async throws {
        let (model,runtime,_,_,root,instance) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at:root) }
        await model.start(instanceID:instance.id,text:"hello")
        let id = try XCTUnwrap(model.state.tasks.first?.id)
        model.mergeNativeItem(id,item:["id":"tool","type":"commandExecution","status":"inProgress"],turnID:"native-turn")
        runtime.results["native_reconcile"] = ["threadId":"native-thread","turns":[],"items":[["turnId":"native-turn","item":["id":"tool","type":"commandExecution","status":"failed"]]]]
        await model.reconcileNativeHistory(id)
        XCTAssertTrue(WorkbenchConversationPresentation.hasProcessFailure(model.state.tasks[0]))
        XCTAssertEqual(model.state.tasks[0].nativeState?.items.first?.status,"inProgress")
    }

    @MainActor func testOldStartedCannotBindTheGapBeforeNewPromptResponse() async throws {
        let (model,runtime,_,_,root,instance) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at:root) }
        await model.start(instanceID:instance.id,text:"hello")
        let id = try XCTUnwrap(model.state.tasks.first?.id)
        model.mutate(id) {
            $0.nativeState?.recordTurnStatus("native-turn",status:"completed")
            $0.nativeState?.turnID = nil
            $0.nativeState?.pendingOperation = .init(kind:.prompt,targetID:"native-thread")
        }
        runtime.emit(taskID:id,instanceID:instance.id,method:"turn/started",params:["threadId":"native-thread","turn":["id":"native-turn","status":"inProgress"]])
        XCTAssertNil(model.state.tasks[0].nativeState?.turnID)
        XCTAssertEqual(model.state.tasks[0].nativeState?.pendingOperation?.status,.requested)
    }

    @MainActor func testInvalidTurnCompletionLeavesApprovalAndControlIntactButIsAudited() async throws {
        for status: Any in ["bogus", true, 1, ["type":"completed"], NSNull()] {
            let (model,runtime,_,audit,root,instance) = try fixture()
            defer { model.shutdown(); try? FileManager.default.removeItem(at:root) }
            await model.start(instanceID:instance.id,text:"hello")
            let task = try XCTUnwrap(model.state.tasks.first)
            emitPermission(runtime,task:task)
            let original = model.state.tasks[0].nativeState
            let auditCount = audit.saved.count
            runtime.emit(taskID:task.id,instanceID:instance.id,method:"turn/completed",params:["threadId":"native-thread","turn":["id":"native-turn","status":status]])
            XCTAssertEqual(model.state.tasks[0].status,.awaitingPermission)
            XCTAssertEqual(model.state.tasks[0].nativeState,original)
            XCTAssertEqual(model.permissions.count,1)
            XCTAssertEqual(audit.saved.count,auditCount+1,"raw invalid notification remains observable")
            XCTAssertEqual(audit.saved.last?["method"] as? String,"turn/completed")
            XCTAssertFalse(runtime.requests.contains { $0.0 == "native_reconcile" })
        }
    }

    @MainActor func testLiveFinalCanCompleteQueryProvenProcessExactlyOnceWithoutRegression() async throws {
        let (model,runtime,_,_,root,instance) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at:root) }
        await model.start(instanceID:instance.id,text:"hello")
        let id = try XCTUnwrap(model.state.tasks.first?.id)
        model.mergeNativeItem(id,item:["id":"tool","type":"commandExecution","status":"inProgress","command":"printf full","aggregatedOutput":"partial"],turnID:"native-turn")
        runtime.results["native_reconcile"] = ["threadId":"native-thread","turns":[],"items":[["turnId":"native-turn","item":["id":"tool","type":"commandExecution","status":"completed","aggregatedOutput":"query body must not replace raw body"]]]]
        await model.reconcileNativeHistory(id)
        let queryProven = try XCTUnwrap(model.state.tasks[0].nativeState?.items.first)
        XCTAssertTrue(queryProven.hasTerminalEvidence)
        XCTAssertEqual(queryProven.detail,"printf full\npartial")
        for (turn,kind,status) in [("wrong-turn","commandExecution","completed"),("native-turn","fileChange","completed"),("native-turn","commandExecution","failed")] {
            runtime.emit(taskID:id,instanceID:instance.id,method:"item/completed",params:["threadId":"native-thread","turnId":turn,"item":["id":"tool","type":kind,"status":status,"aggregatedOutput":"must reject"]])
            XCTAssertEqual(model.state.tasks[0].nativeState?.items.first?.detail,queryProven.detail)
        }
        runtime.emit(taskID:id,instanceID:instance.id,method:"item/completed",params:["threadId":"native-thread","turnId":"native-turn","item":["id":"tool","type":"commandExecution","status":"completed","command":"printf full","aggregatedOutput":"full output"]])
        let final = try XCTUnwrap(model.state.tasks[0].nativeState?.items.first)
        XCTAssertEqual(final.detail,"printf full\nfull output","real final event may finish the body after query supplied status evidence")
        XCTAssertTrue(final.hasTerminalEvidence)
        XCTAssertEqual(final.evidenceStatus,queryProven.evidenceStatus)
        runtime.emit(taskID:id,instanceID:instance.id,method:"item/started",params:["threadId":"native-thread","turnId":"native-turn","item":["id":"tool","type":"commandExecution","status":"inProgress","aggregatedOutput":"stale"]])
        runtime.emit(taskID:id,instanceID:instance.id,method:"item/commandExecution/outputDelta",params:["threadId":"native-thread","turnId":"native-turn","itemId":"tool","delta":"stale"])
        runtime.emit(taskID:id,instanceID:instance.id,method:"item/completed",params:["threadId":"native-thread","turnId":"native-turn","item":["id":"tool","type":"commandExecution","status":"completed","aggregatedOutput":"short duplicate"]])
        model.mergeNativeItem(id,item:["id":"tool","type":"commandExecution","status":"inProgress","aggregatedOutput":"snapshot"],turnID:"native-turn")
        await model.reconcileNativeHistory(id)
        XCTAssertEqual(model.state.tasks[0].nativeState?.items.first,final,"duplicates, old started/delta and snapshots cannot truncate the accepted final")
    }

    @MainActor func testReconciledTerminalProofRejectsLatePermissionButAllowsNewActiveTurn() async throws {
        let (model,runtime,_,audit,root,instance) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at:root) }
        await model.start(instanceID:instance.id,text:"hello")
        let task = try XCTUnwrap(model.state.tasks.first)
        runtime.results["native_reconcile"] = ["threadId":"native-thread","turns":[["id":"native-turn","status":"completed"]],"items":[]]
        await model.reconcileNativeHistory(task.id)
        XCTAssertEqual(model.state.tasks[0].status,.running)
        XCTAssertEqual(model.state.tasks[0].nativeState?.turnID,"native-turn")
        emitPermission(runtime,task:task)
        XCTAssertTrue(model.permissions.isEmpty)
        XCTAssertEqual(model.state.tasks[0].status,.running)
        XCTAssertEqual(audit.saved.last?["method"] as? String,"permission","the incoming notification is still auditable")
        model.mutate(task.id) { $0.nativeState?.turnID = "next-turn"; $0.status = .running }
        emitPermission(runtime,task:task,turnID:"next-turn")
        let current = try XCTUnwrap(model.permissions.first)
        await model.respond(current,option:current.options[0])
        XCTAssertEqual(runtime.requests.filter { $0.0 == "native_permission" }.count,1,"a new active turn retains normal approval control")
    }

    @MainActor func testReconciledTerminalProofBlocksSavedApprovalClicksWithoutQueryMutations() async throws {
        let (model,runtime,_,audit,root,instance) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at:root) }
        await model.start(instanceID:instance.id,text:"hello")
        let task = try XCTUnwrap(model.state.tasks.first)
        emitPermission(runtime,task:task)
        let request = try XCTUnwrap(model.permissions.first)
        let originalPending = model.state.tasks[0].nativeState?.pendingOperation
        let originalMessages = model.state.tasks[0].messages
        let auditBytes = try JSONSerialization.data(withJSONObject:audit.saved,options:.sortedKeys)
        runtime.results["native_reconcile"] = ["threadId":"native-thread","turns":[["id":"native-turn","status":"completed"]],"items":[]]
        await model.reconcileNativeHistory(task.id)
        XCTAssertEqual(model.permissions.map(\.id),[request.id],"query preserves the original approval card")
        XCTAssertEqual(model.state.tasks[0].status,.awaitingPermission)
        XCTAssertEqual(model.state.tasks[0].nativeState?.pendingOperation,originalPending)
        XCTAssertEqual(model.state.tasks[0].messages,originalMessages)
        XCTAssertEqual(try JSONSerialization.data(withJSONObject:audit.saved,options:.sortedKeys),auditBytes)
        for option in request.options { await model.respond(request,option:option) }
        XCTAssertFalse(runtime.requests.contains { ["native_permission","native_cancel"].contains($0.0) })
        XCTAssertEqual(model.permissions.map(\.id),[request.id],"proof checking cannot delete the preserved approval")
        XCTAssertEqual(model.state.tasks[0].status,.awaitingPermission)
        XCTAssertEqual(model.state.tasks[0].nativeState?.pendingOperation,originalPending)
        XCTAssertEqual(model.state.tasks[0].messages,originalMessages)
        XCTAssertEqual(try JSONSerialization.data(withJSONObject:audit.saved,options:.sortedKeys),auditBytes)
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

    @MainActor private func emitPermission(_ runtime: NativeTestRuntime, task: WorkbenchTask, turnID: String = "native-turn", expiry: Date = Date().addingTimeInterval(300)) {
        runtime.emit(taskID:task.id,instanceID:task.instanceID,method:"permission",params:[
            "threadId":"native-thread","turnId":turnID,"itemId":"tool","requestId":"permission-id",
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
