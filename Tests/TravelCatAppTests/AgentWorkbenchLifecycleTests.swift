import Foundation
import XCTest
@testable import TravelCatApp

@MainActor private final class LifecycleRuntime: AgentRuntimeClient {
    var onEvent: (([String: Any]) -> Void)?
    var onExit: (() -> Void)?
    var calls: [String] = []
    var stopped = false
    var exited = false
    var shutdownCount = 0
    var cancelDuringExit = false
    var response: CheckedContinuation<[String: Any], Error>?
    func launch(python: String) throws {}
    func request(_ method: String, _ params: [String: Any], timeout: UInt64) async throws -> [String: Any] {
        calls.append(method)
        if method == "scan_local" { return try await withCheckedThrowingContinuation { response = $0 } }
        return ["stopped": stopped]
    }
    func shutdown() { shutdownCount += 1 }
    func waitForExit(timeout: Duration) async -> Bool {
        if cancelDuringExit { withUnsafeCurrentTask { $0?.cancel() } }
        return exited
    }
}

@MainActor private final class LifecycleCredentials: TravelServiceCredentialStoring {
    var values: [String: String] = [:]
    func read(id: String) throws -> String? { values[id] }
    func save(_ secret: String?, id: String) throws { values[id] = secret }
}

final class AgentWorkbenchLifecycleTests: XCTestCase {
    @MainActor func testDisabledModelRemainsFencedAndRetainsDataAcrossStopRetry() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/workbench-lifecycle-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = LifecycleRuntime()
        let model = AgentWorkbenchModel(root: root, credentials: LifecycleCredentials(), client: runtime)
        XCTAssertTrue(model.isStorageReady)
        await model.discover(host: "")
        do { try await model.suspendAndWait(verifyNativeExit: { true }); XCTFail("missing stop receipt") } catch {}
        XCTAssertTrue(model.hasOwnedOperations)
        let calls = runtime.calls
        await model.discover(host: "")
        await model.scanLocal()
        XCTAssertEqual(runtime.calls, calls)
        XCTAssertFalse(model.positivelyStopped)
        runtime.stopped = true; runtime.exited = true
        try await model.suspendAndWait(verifyNativeExit: { true })
        XCTAssertTrue(model.positivelyStopped)
        XCTAssertTrue(model.hasShutdown)
        XCTAssertFalse(model.hasOwnedOperations)
        let stoppedCalls = runtime.calls
        await model.discover(host: "")
        XCTAssertEqual(runtime.calls, stoppedCalls)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    @MainActor func testCancellationDuringExitCannotBecomePositiveStopEvidence() async throws {
        let runtime = LifecycleRuntime(), gate = AgentWorkbenchRuntimeGate(runtime)
        runtime.stopped = true; runtime.exited = true; runtime.cancelDuringExit = true
        try gate.launch(python: "fixture")
        let stop = Task { @MainActor in
            do { try await gate.suspendAndWait(verifyNativeExit: { true }); return true }
            catch { return false }
        }
        let succeeded = await stop.value
        XCTAssertFalse(succeeded)
        XCTAssertFalse(gate.positivelyStopped)
    }

    @MainActor func testFenceBlocksAllNewRequestsIncludingAfterAwaitAndAllowsCleanup() async throws {
        let runtime = LifecycleRuntime(), gate = AgentWorkbenchRuntimeGate(LifecycleRuntime())
        let subject = AgentWorkbenchRuntimeGate(runtime)
        try subject.launch(python: "fixture")
        let pending = Task { @MainActor in
            _ = try await subject.request("scan_local", [:])
            _ = try await subject.request("native_connect", [:])
        }
        while runtime.response == nil { await Task.yield() }
        subject.seal()
        runtime.response?.resume(returning: [:])
        do { _ = try await pending.value; XCTFail("await recovery must remain fenced") } catch {}
        for method in ["start", "probe", "prompt", "resume", "permission", "model_permission", "native_login", "native_start", "native_prompt", "native_resume", "native_permission"] {
            do { _ = try await subject.request(method, [:]); XCTFail(method) } catch {}
        }
        do { try subject.launch(python: "fixture"); XCTFail("sealed launch") } catch {}
        _ = try await subject.request("stop", [:])
        XCTAssertEqual(runtime.calls, ["scan_local", "stop"])
        XCTAssertFalse(subject.positivelyStopped)
        XCTAssertFalse(gate.positivelyStopped)
    }

    @MainActor func testStopRequiresRuntimeNativeAndProcessReceiptsAndCanRetry() async throws {
        let runtime = LifecycleRuntime(), gate = AgentWorkbenchRuntimeGate(runtime)
        try gate.launch(python: "fixture")
        do { try await gate.suspendAndWait(verifyNativeExit: { true }); XCTFail("missing runtime receipt") } catch {}
        XCTAssertEqual(runtime.shutdownCount, 0)
        XCTAssertFalse(gate.positivelyStopped)
        runtime.stopped = true
        do { try await gate.suspendAndWait(verifyNativeExit: { false }); XCTFail("native exit missing") } catch {}
        XCTAssertEqual(runtime.shutdownCount, 0)
        do { try await gate.suspendAndWait(verifyNativeExit: { true }); XCTFail("EOF is not exit") } catch {}
        XCTAssertFalse(gate.positivelyStopped)
        runtime.exited = true
        try await gate.suspendAndWait(verifyNativeExit: { true })
        XCTAssertTrue(gate.positivelyStopped)
        do { _ = try await gate.request("start", [:]); XCTFail("cannot reenable old model") } catch {}
    }
}
