import XCTest
@testable import TravelCatApp

@MainActor
final class AgentXExternalObservationTests: XCTestCase {
    func testSingleFlightAndFailureReplacesSuccess() async throws {
        let observer = AgentXExternalObserver()
        var calls = 0
        let probe: AgentXExternalObserver.Probe = {
            calls += 1
            try await Task.sleep(for: .milliseconds(30))
            return [.init(id: "native", kind: .native, state: .responsive, reason: .none)]
        }
        observer.refresh("a", generation: { nil }, probe: probe)
        observer.refresh("a", generation: { nil }, probe: probe)
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(observer.samples["a"]?.items.first?.state, .responsive)
        let success = observer.samples["a"]?.lastSuccess
        observer.refresh("a", generation: { nil }) { throw AgentXProbeFailure(.disconnected) }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(observer.samples["a"]?.items.first?.state, .unknown)
        XCTAssertEqual(observer.samples["a"]?.items.first?.reason, .disconnected)
        XCTAssertEqual(observer.samples["a"]?.lastSuccess, success)
    }
    func testTimeoutDiscardsLateResultAndDoesNotOverlapWorker() async throws {
        let observer = AgentXExternalObserver(timeout: .milliseconds(20))
        var calls = 0
        let probe: AgentXExternalObserver.Probe = {
            calls += 1
            try? await Task.sleep(for: .milliseconds(100))
            return [.init(id: "native", kind: .native, state: .responsive, reason: .none)]
        }
        observer.refresh("a", generation: { nil }, probe: probe)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(observer.samples["a"]?.items.first?.reason, .timeout)
        observer.refresh("a", generation: { nil }, probe: probe)
        XCTAssertEqual(calls, 1)
        try await Task.sleep(for: .milliseconds(90))
        XCTAssertEqual(observer.samples["a"]?.items.first?.reason, .timeout)
    }
    func testClosingOrChangingGenerationRejectsLateReply() async throws {
        let observer = AgentXExternalObserver()
        var generation = UUID()
        observer.refresh("a", generation: { generation }) {
            try? await Task.sleep(for: .milliseconds(30))
            return [.init(id: "native", kind: .native, state: .responsive, reason: .none)]
        }
        generation = UUID()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertNotEqual(observer.samples["a"]?.items.first?.state, .responsive)
        observer.refresh("b", generation: { nil }) {
            try? await Task.sleep(for: .milliseconds(30))
            return [.init(id: "native", kind: .native, state: .responsive, reason: .none)]
        }
        observer.close("b")
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertNil(observer.samples["b"])
    }
    func testWireValidationAndStaleness() throws {
        XCTAssertThrowsError(try AgentXExternalProbeItem.decode(["items": [["id": "x", "kind": "native", "state": "online", "reason": "secret"]]]))
        let item = AgentXExternalProbeItem(id: "x", kind: .native, state: .responsive, reason: .none)
        let sample = AgentXExternalProbeSample(started: .distantPast, finished: .distantPast, lastSuccess: nil, items: [item], refreshing: false)
        XCTAssertTrue(sample.isStale(at: .now))
        XCTAssertFalse(sample.isStale(at: .distantPast))
    }
}

@MainActor private final class ObservationOnlyClient: AgentRuntimeClient {
    var onEvent: (([String: Any]) -> Void)?
    var onExit: (() -> Void)?
    var mutations = 0
    func launch(python: String) throws { mutations += 1 }
    func request(_ method: String, _ params: [String: Any], timeout: UInt64) async throws -> [String: Any] { mutations += 1; return [:] }
    func shutdown() { mutations += 1 }
    func observeRuntime() async throws -> [String: Any] { ["items": []] }
}

extension AgentXExternalObservationTests {
    func testObservationGateDoesNotClaimWorkOrLaunch() async throws {
        let underlying = ObservationOnlyClient(), gate = AgentWorkbenchRuntimeGate(ObservationOnlyClient())
        let observed = AgentWorkbenchRuntimeGate(underlying)
        _ = try await observed.observeRuntime()
        XCTAssertEqual(underlying.mutations, 0)
        XCTAssertFalse(observed.hasOwnedOperations)
        XCTAssertFalse(gate.hasOwnedOperations)
    }
    func testPartialSuccessRetainsPerObjectTimestampWhenOtherLayerFails() async throws {
        let observer = AgentXExternalObserver()
        observer.refresh("a", generation: { nil }) {
            [.init(id: "n", kind: .native, state: .responsive, reason: .none), .init(id: "d", kind: .docker, state: .unobserved, reason: .notConnected)]
        }
        try await Task.sleep(for: .milliseconds(20))
        let date = try XCTUnwrap(observer.samples["a"]?.lastSuccessByID["n"])
        XCTAssertNil(observer.samples["a"]?.lastSuccessByID["d"])
        observer.refresh("a", generation: { nil }) { throw AgentXProbeFailure(.disconnected) }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(observer.samples["a"]?.lastSuccessByID["n"], date)
        XCTAssertEqual(observer.samples["a"]?.items.first?.state, .unknown)
    }
    func testGenerationChangeRejectsTimeoutToo() async throws {
        let observer = AgentXExternalObserver(timeout: .milliseconds(20))
        var generation = UUID()
        observer.refresh("a", generation: { generation }) {
            try await Task.sleep(for: .milliseconds(60)); return []
        }
        generation = UUID()
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertNil(observer.samples["a"])
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertNil(observer.samples["a"])
    }
    func testActualSidecarReadWithoutStartingAnyEngine() async throws {
        let python = "/opt/homebrew/bin/python3"
        guard FileManager.default.isExecutableFile(atPath: python) else { throw XCTSkip("Python 3.11+ unavailable") }
        let client = AgentSidecarClient()
        do { _ = try await client.observeRuntime(); XCTFail("must not launch") }
        catch { XCTAssertEqual((error as? AgentXProbeFailure)?.reason, .notConnected) }
        try client.launch(python: python) // Isolated harness setup, not the observer.
        do {
            let items = try AgentXExternalProbeItem.decode(await client.observeRuntime())
            XCTAssertTrue(items.contains { $0.kind == .native && $0.state == .unobserved })
            XCTAssertTrue(items.contains { $0.kind == .docker && $0.state == .unobserved })
        } catch { client.shutdown(); _ = await client.waitForExit(timeout: .seconds(3)); throw error }
        client.shutdown()
        let exited = await client.waitForExit(timeout: .seconds(3))
        XCTAssertTrue(exited)
    }
}


extension AgentXExternalObservationTests {
    func testOldViewCleanupCannotClearReopenedSession() async throws {
        let observer = AgentXExternalObserver()
        let old = observer.beginSession("a"), current = observer.beginSession("a")
        observer.refresh("a", generation: { nil }) { [.init(id: "n", kind: .native, state: .responsive, reason: .none)] }
        try await Task.sleep(for: .milliseconds(20))
        observer.endSession("a", id: old)
        XCTAssertNotNil(observer.samples["a"])
        observer.endSession("a", id: current)
        XCTAssertNil(observer.samples["a"])
    }
}


extension AgentXExternalObservationTests {
    func testHostAndConnectionGenerationsAreBothBound() async throws {
        let observer = AgentXExternalObserver()
        var host = UUID(), connection = UUID()
        let probe: AgentXExternalObserver.Probe = {
            try await Task.sleep(for: .milliseconds(30))
            return [.init(id: "n", kind: .native, state: .responsive, reason: .none)]
        }
        observer.refresh("a", generation: { host }, connectionGeneration: { connection }, probe: probe)
        host = UUID()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertNil(observer.samples["a"])
        observer.refresh("a", generation: { host }, connectionGeneration: { connection }, probe: probe)
        connection = UUID()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertNil(observer.samples["a"])
    }
}
