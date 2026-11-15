import XCTest
@testable import TravelCatApp

@MainActor final class AgentXStopGovernanceTests: XCTestCase {
    func testStopIntentSurvivesRestartAndPreventsEnable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = AgentXRepository(root: root)
        let c = AgentXController(repository: repository, credentials: AgentXTestCredentials(), autoRefreshCatalogs: false)
        do { try await c.setApplicationEnabled("blackcat", enabled: false) } catch {}
        let restored = AgentXController(repository: repository, credentials: AgentXTestCredentials(), autoRefreshCatalogs: false)
        do { try await restored.setApplicationEnabled("blackcat", enabled: true); XCTFail("Unverified stop must survive restart") } catch {}
    }
    func testStoreRejectsSymlinkAndPreservesOperationHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("manager"), withDestinationURL: outside)
        let store = AgentXStopOperationStore(root: root)
        XCTAssertThrowsError(try store.save(["a": .init(appID: "a", items: [])]))
    }
    func testTimeoutIsBoundedAndLateExitConfirmsSameOperation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let c = AgentXController(repository: .init(root: root), credentials: AgentXTestCredentials(), autoRefreshCatalogs: false)
        c.stopWaitSeconds = 0.03
        var continuation: CheckedContinuation<Void, Never>?
        var calls = 0
        c.externalRuntimeStop = { _ in calls += 1; await withCheckedContinuation { continuation = $0 } }
        do { try await c.setApplicationEnabled("blackcat", enabled: false); XCTFail() } catch {}
        let id = try XCTUnwrap(c.stopOperations["blackcat"]?.id)
        XCTAssertEqual(c.stopOperations["blackcat"]?.status, .unverified)
        do { try await c.setApplicationEnabled("blackcat", enabled: false); XCTFail() } catch {}
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(c.stopOperations["blackcat"]?.id, id)
        continuation?.resume()
        for _ in 0..<100 { if c.applicationStopStates["blackcat"] == .stopped { break }; await Task.yield() }
        XCTAssertEqual(c.applicationStopStates["blackcat"], .stopped)
    }
    func testReplacedRuntimeCannotConfirmOldDrain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let c = AgentXController(repository: .init(root: root), credentials: AgentXTestCredentials(), autoRefreshCatalogs: false)
        let host = AgentXHostRuntimeLifecycle(controller: c)
        var continuation: CheckedContinuation<Void, Never>?
        host.register("blackcat", runtime: .init(fence: {}, drain: { await withCheckedContinuation { continuation = $0 } }, isIdle: { true }, hasExited: { true }, resume: {}))
        let task = Task { try await host.stop("blackcat") }
        while continuation == nil { await Task.yield() }
        host.register("blackcat", runtime: .init(fence: {}, drain: {}, isIdle: { false }, hasExited: { false }, resume: {}))
        continuation?.resume()
        do { try await task.value; XCTFail("Old generation cannot confirm new runtime") } catch {}
    }
    func testProcessIdentityDistinguishesReusedPIDAndInaccessibleProcess() {
        let identity = AgentXStopProcessIdentity(pid: 42, seconds: 10, microseconds: 1)
        XCTAssertFalse(identity.definitelyExited(read: { _ in identity }, absent: { _ in false }))
        XCTAssertFalse(identity.definitelyExited(read: { _ in nil }, absent: { _ in false }))
        XCTAssertTrue(identity.definitelyExited(read: { _ in .init(pid: 42, seconds: 11, microseconds: 1) }, absent: { _ in false }))
        XCTAssertTrue(identity.definitelyExited(read: { _ in nil }, absent: { _ in true }))
    }
    func testCompletedOperationsKeepHistoryAndCorruptStoreFencesStartup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentXStopOperationStore(root: root)
        let first = AgentXStopOperation(appID: "a", status: .stopped, items: [])
        let second = AgentXStopOperation(appID: "a", items: [])
        try store.save(["a": first]); try store.save(["a": second])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("manager/stop-history/" + first.id.uuidString + ".json").path))
        try Data("broken".utf8).write(to: root.appendingPathComponent("manager/stop-operations.json"))
        let c = AgentXController(repository: .init(root: root), credentials: AgentXTestCredentials(), autoRefreshCatalogs: false)
        XCTAssertFalse(c.isLoaded)
    }
    func testIntentFailureDoesNotCancelOrDisable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let c = AgentXController(repository: .init(root: root), credentials: AgentXTestCredentials(), autoRefreshCatalogs: false)
        var calls = 0; c.externalRuntimeStop = { _ in calls += 1 }
        let path = root.appendingPathComponent("manager/stop-operations.json")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        do { try await c.setApplicationEnabled("blackcat", enabled: false); XCTFail() } catch {}
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(c.state.apps.first { $0.id == "blackcat" }!.enabled)
    }
    func testResultPersistenceFailureCannotClaimStoppedOrEnable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let c = AgentXController(repository: .init(root: root), credentials: AgentXTestCredentials(), autoRefreshCatalogs: false)
        c.externalRuntimeStop = { _ in
            let path = root.appendingPathComponent("manager/stop-operations.json")
            try FileManager.default.removeItem(at: path)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
        do { try await c.setApplicationEnabled("blackcat", enabled: false); XCTFail() } catch {}
        XCTAssertNotNil(c.stopOperations["blackcat"]?.persistenceFailure)
        XCTAssertNotEqual(c.applicationStopStates["blackcat"], .stopped)
        do { try await c.setApplicationEnabled("blackcat", enabled: true); XCTFail() } catch {}
    }
    func testRestartReconcilesHTTPTaskOnlyWithExitedOwnerEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = AgentXRepository(root: root)
        var state = AgentXState(); state.apps = [.init(id: "a", name: "A", kind: .chat, enabled: false)]
        try repo.save(state)
        var owner = try XCTUnwrap(AgentXStopProcessIdentity.read(getpid()))
        owner.seconds = 0 // Same PID but a different, provably stale start identity.
        let op = AgentXStopOperation(appID: "a", status: .unverified, items: [.init(id: "old", title: "宿主任务", kind: .task, status: .unverified, owner: owner, runtimeCore: "native-http")])
        try AgentXStopOperationStore(root: root).save(["a": op])
        let c = AgentXController(repository: repo, credentials: AgentXTestCredentials(), autoRefreshCatalogs: false)
        for _ in 0..<200 { if c.applicationStopStates["a"] == .stopped { break }; await Task.yield() }
        XCTAssertEqual(c.applicationStopStates["a"], .stopped)
        XCTAssertFalse(c.state.apps[0].enabled)
        XCTAssertEqual(c.stopOperations["a"]?.id, op.id)
        try await c.setApplicationEnabled("a", enabled: true)
        XCTAssertTrue(c.state.runs.isEmpty)
        XCTAssertNil(c.runtimeObservations["a"])
    }
    private func configured(_ respond: @escaping AgentXController.Responder) throws -> AgentXController {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repo = AgentXRepository(root: root)
        var state = AgentXState(); state.apps = [.init(id: "a", name: "A", kind: .chat), .init(id: "b", name: "B", kind: .chat)]
        state.providers = [.init(id: "p", name: "P", baseURL: "http://localhost:1234", models: ["m"])]
        state.definitions = [.init(id: "d", name: "D", prompt: "Write")]
        state.instances = ["one", "two"].map { .init(id: $0, name: $0, appID: "a", definitionID: "d", providerID: "p", model: "m") }
        try repo.save(state)
        return AgentXController(repository: repo, credentials: AgentXTestCredentials(), respond: respond, autoRefreshCatalogs: false)
    }
    func testSuccessfulReplyWinsCancellationRaceForTextAndWorkflow() async throws {
        for workflow in [false, true] {
            var reply: CheckedContinuation<String, Never>?
            let c = try configured { _, _, _, _ in await withCheckedContinuation { reply = $0 } }
            if workflow {
                try c.saveWorkflowDraft(appID: "a", definition: .init(name: "Flow", steps: [.init(name: "Step", instanceID: "one", instruction: "Write")]), expectedDraft: nil)
                try c.publishWorkflow(appID: "a"); c.startWorkflow("test", appID: "a")
            } else { c.send("test", instanceID: "one") }
            while reply == nil { await Task.yield() }
            c.cancel(c.state.runs[0].id)
            reply?.resume(returning: "successful result")
            await c.waitForRuns()
            XCTAssertEqual(c.state.runs[0].status, .completed)
            XCTAssertEqual(c.state.runs[0].response, "successful result")
            if workflow { XCTAssertEqual(c.state.runs[0].workflowSteps?.first?.status, .completed) }
        }
    }
    func testIndependentTaskConfirmationAndRuntimeReplacementAfterDrain() async throws {
        var replies: [String: CheckedContinuation<String, Never>] = [:]
        let c = try configured { _, _, _, messages in await withCheckedContinuation { replies[messages.last!.content] = $0 } }
        let host = AgentXHostRuntimeLifecycle(controller: c)
        host.register("a", runtime: .init(fence: {}, drain: {}, isIdle: { true }, hasExited: { true }, resume: {}))
        c.send("one", instanceID: "one"); c.send("two", instanceID: "two")
        while replies.count != 2 { await Task.yield() }
        let stopping = Task { try await c.setApplicationEnabled("a", enabled: false) }
        while c.stopOperations["a"]?.items.first(where: { $0.id == "runtime" })?.status != .confirmed { await Task.yield() }
        let secondID = c.state.runs.first { $0.prompt == "two" }!.id
        replies.removeValue(forKey: "two")!.resume(returning: "two")
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(c.stopOperations["a"]?.items.first { $0.id == secondID }?.status, .confirmed)
        host.register("a", runtime: .init(fence: {}, drain: {}, isIdle: { false }, hasExited: { false }, resume: {}))
        replies.removeValue(forKey: "one")!.resume(returning: "one")
        do { try await stopping.value; XCTFail("Replaced runtime cannot remain confirmed") } catch {}
        XCTAssertNotEqual(c.applicationStopStates["a"], .stopped)
    }
    func testOtherApplicationPersistenceFailureDoesNotPoisonCompletedStop() async throws {
        let c = try configured { _, _, _, _ in "ok" }
        try await c.setApplicationEnabled("a", enabled: false)
        c.externalRuntimeStop = { id in
            if id == "b" {
                let file = c.repository.root.appendingPathComponent("manager/stop-operations.json")
                try FileManager.default.removeItem(at: file)
                try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
            }
        }
        do { try await c.setApplicationEnabled("b", enabled: false); XCTFail() } catch {}
        XCTAssertEqual(c.applicationStopStates["a"], .stopped)
        XCTAssertNil(c.stopOperations["a"]?.persistenceFailure)
        try FileManager.default.removeItem(at: c.repository.root.appendingPathComponent("manager/stop-operations.json"))
        c.externalRuntimeStop = { _ in }
        try await c.setApplicationEnabled("b", enabled: false)
        XCTAssertEqual(c.applicationStopStates["b"], .stopped)
        XCTAssertNoThrow(try c.requirePackageSnapshotIdle())
    }
}
