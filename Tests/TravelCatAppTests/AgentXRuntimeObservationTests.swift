import Foundation
import XCTest
@testable import TravelCatApp

@MainActor
final class AgentXRuntimeObservationTests: XCTestCase {
    private func controller() throws -> AgentXController {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-observation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try AgentXRepository(root: root).save(.init())
        try AgentXStopOperationStore(root: root).save(["blackcat": .init(appID: "blackcat", status: .stopped, items: [])])
        return AgentXController(repository: .init(root: root), credentials: AgentXTestCredentials(), autoRefreshCatalogs: false)
    }
    func testPastStopAndEnabledPreferenceDoNotImplyCurrentRuntimeState() throws {
        let c = try controller()
        XCTAssertTrue(c.state.apps[0].enabled)
        XCTAssertEqual(c.stopOperations["blackcat"]?.status, .stopped)
        let unknown = c.currentRuntimeSnapshot(for: "blackcat", at: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(unknown.localRuntimeWork, .unobserved)
        XCTAssertEqual(unknown.externalStatus, "外部引擎：未探测")
        c.externalRuntimeHasOwnedWork = { _ in true }
        XCTAssertEqual(c.currentRuntimeSnapshot(for: "blackcat").localRuntimeWork, .busy)
        XCTAssertEqual(c.stopOperations["blackcat"]?.status, .stopped)
    }
    func testSamplingRefreshesCurrentWorkWithoutMutatingHistoryOrLifecycle() throws {
        let c = try controller(), host = AgentXHostRuntimeLifecycle(controller: c)
        var busy = true, mutations = 0, exitProbes = 0
        host.register("blackcat", runtime: .init(fence: { mutations += 1 }, drain: { mutations += 1 }, isIdle: { !busy }, hasExited: { exitProbes += 1; return true }, resume: { mutations += 1 }))
        let baseline = c.stopOperations
        let baselineMutations = mutations
        let file = c.repository.root.appendingPathComponent("manager/stop-operations.json")
        let bytes = try Data(contentsOf: file)
        let first = c.currentRuntimeSnapshot(for: "blackcat", at: Date(timeIntervalSince1970: 100))
        busy = false
        let second = c.currentRuntimeSnapshot(for: "blackcat", at: Date(timeIntervalSince1970: 102))
        XCTAssertEqual(first.localRuntimeWork, .busy)
        XCTAssertEqual(second.localRuntimeWork, .idle)
        XCTAssertEqual(second.sampledAt.timeIntervalSince1970, 102)
        XCTAssertEqual(second.externalStatus, "外部引擎：未探测")
        XCTAssertEqual(c.stopOperations, baseline)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertEqual(mutations, baselineMutations)
        XCTAssertEqual(exitProbes, 0)
        XCTAssertEqual(c.currentRuntimeSnapshot(for: "unregistered").localRuntimeWork, .unobserved)
    }
    func testHostTaskCountIsScopedAndExcludesTerminalHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-count-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var state = AgentXState()
        state.apps.append(.init(id: "chat", name: "Chat", kind: .chat))
        state.providers = [.init(id: "p", name: "Provider", baseURL: "https://example.com/v1", models: ["m"])]
        state.definitions = [.init(id: "d", name: "Definition", prompt: "test")]
        state.instances = ["blackcat", "chat"].map {
            .init(id: $0, name: $0, appID: $0, definitionID: "d", providerID: "p", model: "m")
        }
        state.runs = [.init(id: "finished", appID: "blackcat", instanceID: "blackcat", prompt: "old", status: .completed)]
        try AgentXRepository(root: root).save(state)
        let c = AgentXController(repository: .init(root: root), credentials: AgentXTestCredentials(), respond: { _, _, _, _ in
            try await Task.sleep(for: .seconds(30)); return "unused"
        }, autoRefreshCatalogs: false)
        c.send("one", instanceID: "blackcat")
        c.send("two", instanceID: "chat")
        XCTAssertEqual(c.currentRuntimeSnapshot(for: "blackcat").hostTaskCount, 1)
        XCTAssertEqual(c.currentRuntimeSnapshot(for: "chat").hostTaskCount, 1)
        c.cancelAll()
        await c.waitForRuns()
        XCTAssertEqual(c.currentRuntimeSnapshot(for: "blackcat").hostTaskCount, 0)
        XCTAssertEqual(c.currentRuntimeSnapshot(for: "chat").hostTaskCount, 0)
    }
    func testReleasedObserverDoesNotReportIdle() throws {
        let c = try controller()
        var host: AgentXHostRuntimeLifecycle? = AgentXHostRuntimeLifecycle(controller: c)
        host?.register("blackcat", runtime: .init(fence: {}, drain: {}, isIdle: { true }, hasExited: { true }, resume: {}))
        XCTAssertEqual(c.currentRuntimeSnapshot(for: "blackcat").localRuntimeWork, .idle)
        host = nil
        XCTAssertEqual(c.currentRuntimeSnapshot(for: "blackcat").localRuntimeWork, .unobserved)
    }
}
