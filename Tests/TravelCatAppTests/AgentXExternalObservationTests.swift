import XCTest
import Combine
@testable import TravelCatApp

@MainActor
final class AgentXExternalObservationTests: XCTestCase {
    private func waitForSample(_ observer: AgentXExternalObserver, appID: String = "a",
                               matching predicate: @escaping (AgentXExternalProbeSample?) -> Bool) async {
        let changed = expectation(description: "expected sample published")
        let observation = observer.$samples.first { predicate($0[appID]) }.sink { _ in changed.fulfill() }
        await fulfillment(of: [changed], timeout: 5)
        observation.cancel()
    }

    func testSingleFlightAndFailureReplacesSuccess() async throws {
        let observer = AgentXExternalObserver(timeout: .seconds(30))
        let started = expectation(description: "single probe started")
        var calls = 0
        var release: CheckedContinuation<Void, Never>?
        let probe: AgentXExternalObserver.Probe = {
            calls += 1
            await withCheckedContinuation { release = $0; started.fulfill() }
            return [.init(id: "native", kind: .native, state: .responsive, reason: .none)]
        }
        observer.refresh("a", generation: { nil }, probe: probe)
        observer.refresh("a", generation: { nil }, probe: probe)
        await fulfillment(of: [started], timeout: 5)
        XCTAssertEqual(calls, 1)
        try XCTUnwrap(release).resume()
        await waitForSample(observer) { $0?.refreshing == false }
        XCTAssertEqual(observer.samples["a"]?.items.first?.state, .responsive)
        let success = observer.samples["a"]?.lastSuccess
        observer.refresh("a", generation: { nil }) { throw AgentXProbeFailure(.disconnected) }
        await waitForSample(observer) { $0?.refreshing == false }
        XCTAssertEqual(observer.samples["a"]?.items.first?.state, .unknown)
        XCTAssertEqual(observer.samples["a"]?.items.first?.reason, .disconnected)
        XCTAssertEqual(observer.samples["a"]?.lastSuccess, success)
    }
    func testTimeoutDiscardsLateResultAndDoesNotOverlapWorker() async throws {
        let observer = AgentXExternalObserver(timeout: .milliseconds(20))
        let started = expectation(description: "slow probe started")
        var calls = 0
        var release: CheckedContinuation<Void, Never>?
        var published: [AgentXExternalProbeItem] = []
        let history = observer.$samples.sink { published += $0["a"]?.items ?? [] }
        defer { history.cancel() }
        let probe: AgentXExternalObserver.Probe = {
            calls += 1
            await withCheckedContinuation { release = $0; started.fulfill() }
            return [.init(id: "late", kind: .native, state: .responsive, reason: .none)]
        }
        observer.refresh("a", generation: { nil }, probe: probe)
        await fulfillment(of: [started], timeout: 5)
        await waitForSample(observer) { $0?.items.first?.reason == .timeout }
        observer.refresh("a", generation: { nil }, probe: probe)
        XCTAssertEqual(calls, 1)
        try XCTUnwrap(release).resume()
        // A new accepted probe proves the old worker released its slot. Record
        // every publication so a transient late success cannot evade the check.
        let deadline = ContinuousClock.now + .seconds(5)
        var nextStarted = false
        while !nextStarted && ContinuousClock.now < deadline {
            observer.refresh("a", generation: { nil }) {
                nextStarted = true
                return [.init(id: "next", kind: .native, state: .responsive, reason: .none)]
            }
            await Task.yield()
        }
        XCTAssertTrue(nextStarted)
        XCTAssertFalse(published.contains { $0.id == "late" && $0.state == .responsive })
        observer.close("a")
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
        await waitForSample(observer) { $0?.refreshing == false }
        let date = try XCTUnwrap(observer.samples["a"]?.lastSuccessByID["n"])
        XCTAssertNil(observer.samples["a"]?.lastSuccessByID["d"])
        observer.refresh("a", generation: { nil }) { throw AgentXProbeFailure(.disconnected) }
        await waitForSample(observer) { $0?.refreshing == false }
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
        await waitForSample(observer) { $0?.refreshing == false }
        observer.endSession("a", id: old)
        XCTAssertNotNil(observer.samples["a"])
        observer.endSession("a", id: current)
        XCTAssertNil(observer.samples["a"])
    }
}


extension AgentXExternalObservationTests {
    func testHostAndConnectionGenerationsAreBothBound() async throws {
        // Keep the timer outside the assertion deadline: only a completed worker
        // may satisfy the rejection expectation, not the observer timeout.
        let observer = AgentXExternalObserver(timeout: .seconds(30))
        var host = UUID(), connection = UUID(), calls = 0
        for changeHost in [true, false] {
            let started = expectation(description: "probe started")
            let rejected = expectation(description: "stale generation discarded")
            var release: CheckedContinuation<Void, Never>?
            let observation = observer.$samples.dropFirst().sink { samples in
                if samples["a"] == nil { rejected.fulfill() }
            }
            observer.refresh("a", generation: { host }, connectionGeneration: { connection }) {
                calls += 1
                await withCheckedContinuation { release = $0; started.fulfill() }
                return [.init(id: "n", kind: .native, state: .responsive, reason: .none)]
            }
            await fulfillment(of: [started], timeout: 5)
            if changeHost { host = UUID() } else { connection = UUID() }
            try XCTUnwrap(release).resume()
            await fulfillment(of: [rejected], timeout: 5)
            observation.cancel()
            XCTAssertNil(observer.samples["a"])
        }
        XCTAssertEqual(calls, 2)
        // An unchanged generation must still accept the result.
        let accepted = expectation(description: "current generation accepted")
        let observation = observer.$samples.dropFirst().sink { samples in
            if samples["a"]?.refreshing == false { accepted.fulfill() }
        }
        observer.refresh("a", generation: { host }, connectionGeneration: { connection }) {
            [.init(id: "n", kind: .native, state: .responsive, reason: .none)]
        }
        await fulfillment(of: [accepted], timeout: 5)
        observation.cancel()
        XCTAssertEqual(observer.samples["a"]?.items.first?.state, .responsive)
    }
}
