import Foundation
import XCTest
import TravelStorage
@testable import TravelCatApp

@MainActor
final class AgentXHostRuntimeLifecycleTests: XCTestCase {
    func testScopeFencesSynchronouslyAndWaitsForRealCompletion() async {
        let scope = AgentXOwnedTaskScope()
        var continuation: CheckedContinuation<Void, Never>?
        let started = expectation(description: "started")
        scope.start { await withCheckedContinuation { continuation = $0; started.fulfill() } }
        await fulfillment(of: [started], timeout: 2)
        scope.fence()
        XCTAssertFalse(scope.isEnabled)
        XCTAssertNil(scope.start { XCTFail("disabled work") })
        var drained = false
        let stop = Task { await scope.suspendAndWait(); drained = true }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(drained)
        XCTAssertFalse(scope.isIdle)
        XCTAssertFalse(scope.resumeWithoutRunning())
        continuation?.resume()
        await stop.value
        XCTAssertTrue(scope.isIdle)
        XCTAssertTrue(scope.resumeWithoutRunning())
        XCTAssertTrue(scope.isIdle)
    }
    func testDisabledNotificationDoesNotSendAndDrainWaitsForTransport() async {
        var continuation: CheckedContinuation<Void, Never>?
        let started = expectation(description: "send started")
        var sends = 0
        let service = NotificationService(center: nil, send: { _ in
            sends += 1
            if sends == 1 { await withCheckedContinuation { continuation = $0; started.fulfill() } }
        }, authorized: true)
        let delivery = PetTravelPromptDelivery.summary(promptIDs: ["fixture"], count: 1)
        let sending = Task { await service.postTravelPromptFallback(delivery) }
        await fulfillment(of: [started], timeout: 2)
        service.fence()
        var drained = false
        let stop = Task { await service.suspendAndWait(); drained = true }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(drained)
        continuation?.resume()
        let acknowledged = await sending.value
        XCTAssertFalse(acknowledged)
        await stop.value
        let disabled = await service.postTravelPromptFallback(delivery)
        XCTAssertFalse(disabled)
        XCTAssertEqual(sends, 1)
        XCTAssertTrue(service.resumeWithoutRunning())
        XCTAssertEqual(sends, 1)
    }

    func testHostFencesBeforeDrainAndRequiresPositiveExit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = AgentXController(repository: .init(root: root), credentials: AgentXTestCredentials(), autoRefreshCatalogs: false)
        let host = AgentXHostRuntimeLifecycle(controller: controller)
        var fenced = false, exited = false, resumes = 0
        host.register("blackcat", runtime: .init(fence: { fenced = true }, drain: {}, isIdle: { true }, hasExited: { exited }, resume: { resumes += 1 }))
        controller.didChange = { host.synchronize() }
        host.synchronize()
        do { try await controller.setApplicationEnabled("blackcat", enabled: false); XCTFail("Exit unverified") } catch {}
        XCTAssertTrue(fenced)
        XCTAssertThrowsError(try host.requireIdle("blackcat"))
        exited = true
        try await controller.setApplicationEnabled("blackcat", enabled: false)
        XCTAssertNoThrow(try host.requireIdle("blackcat"))
        try await controller.setApplicationEnabled("blackcat", enabled: true)
        XCTAssertEqual(resumes, 1)
    }
    func testHostPackageBarrierRejectsLateScopeButAllowsNeverStartedNewID() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = AgentXController(repository: .init(root: root), credentials: AgentXTestCredentials(), autoRefreshCatalogs: false)
        let host = AgentXHostRuntimeLifecycle(controller: controller)
        let scope = AgentXOwnedTaskScope()
        host.register("blackcat", runtime: .init(fence: scope.fence, drain: scope.suspendAndWait, isIdle: { scope.isIdle }, hasExited: { true }, resume: { _ = scope.resumeWithoutRunning() }))
        XCTAssertNoThrow(try host.requireIdle("new-app"))
        XCTAssertNoThrow(try host.requireIdle("new-app"), "Unrelated native runtime must not block a new text app")
        var continuation: CheckedContinuation<Void, Never>?
        let started = expectation(description: "late task")
        scope.start { await withCheckedContinuation { continuation = $0; started.fulfill() } }
        await fulfillment(of: [started], timeout: 2)
        scope.fence()
        XCTAssertThrowsError(try host.requireIdle("blackcat"))
        XCTAssertNoThrow(try host.requireIdle("new-app"))
        continuation?.resume()
        await scope.suspendAndWait()
        XCTAssertNoThrow(try host.requireIdle("new-app"))
    }
    func testExistingEmptyAppsRootWithoutSettingsDoesNotBootstrapBuiltin() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("apps"), withIntermediateDirectories: true)
        let controller = AgentXController(repository: .init(root: root), credentials: AgentXTestCredentials(), autoRefreshCatalogs: false)
        XCTAssertTrue(controller.state.apps.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("apps/blackcat").path))
    }

    func testUnrelatedRuntimeDoesNotBlockInstallAndReloadKeepsNewApp() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = AgentXRepository(root: root)
        var state = AgentXState()
        state.providers = [.init(id: "local", name: "Local", baseURL: "http://localhost:1234", models: ["model"])]
        try repo.save(state)
        let controller = AgentXController(repository: repo, credentials: AgentXTestCredentials(), autoRefreshCatalogs: false)
        let host = AgentXHostRuntimeLifecycle(controller: controller)
        host.register("blackcat", runtime: .init(fence: {}, drain: {}, isIdle: { false }, hasExited: { false }, resume: {}))
        let service = host.applicationService()
        let preview = try service.previewTemplate(.conversation, appID: "new-app", providerID: "local", model: "model")
        try service.install(preview)
        XCTAssertTrue(controller.state.apps.contains { $0.id == "new-app" })
        try await controller.setApplicationEnabled("new-app", enabled: false)
        let receipt = try service.uninstall("new-app")
        XCTAssertFalse(controller.state.apps.contains { $0.id == "new-app" })
        try controller.setBlackCatEnabled(false)
        XCTAssertFalse(try repo.load().apps.contains { $0.id == "new-app" })
        // Wait for the same readiness gate used by package mutations. The undo
        // task starts asynchronously, so 5.1 seconds from here is not a receipt.
        let deadline = ContinuousClock.now + .seconds(15)
        var snapshotIdle = false
        while !snapshotIdle && ContinuousClock.now < deadline {
            do { try controller.requirePackageSnapshotIdle(); snapshotIdle = true }
            catch { try await Task.sleep(for: .milliseconds(10)) }
        }
        try controller.requirePackageSnapshotIdle()
        try service.restore(receipt)
        XCTAssertFalse(try XCTUnwrap(controller.state.apps.first { $0.id == "new-app" }).enabled)
        XCTAssertFalse(controller.state.blackCatEnabled)
    }
    func testUnregisteredBuiltinFailsClosedButChatStopIsScoped() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = AgentXRepository(root: root)
        var state = AgentXState(); state.apps.append(.init(id: "chat", name: "Chat", kind: .chat))
        try repo.save(state)
        let controller = AgentXController(repository: repo, credentials: AgentXTestCredentials(), autoRefreshCatalogs: false)
        let host = AgentXHostRuntimeLifecycle(controller: controller)
        try await controller.setApplicationEnabled("chat", enabled: false)
        XCTAssertEqual(controller.applicationStopStates["chat"], .stopped)
        XCTAssertThrowsError(try host.requireIdle("blackcat"))
        do { try await controller.setApplicationEnabled("blackcat", enabled: false); XCTFail("Missing builtin adapter") } catch {}
    }

    func testPackageBarrierRejectsInvalidatedButStillRunningCatalogTask() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = AgentXRepository(root: root)
        var state = AgentXState()
        state.providers = [.init(id: "router", name: "Router", baseURL: "https://openrouter.ai/api/v1", models: ["model"])]
        try repo.save(state)
        let started = expectation(description: "catalog entered")
        let transport = Task3cCatalogTransport(started: started)
        let controller = AgentXController(repository: repo, credentials: AgentXTestCredentials(),
            catalog: AgentXProviderCatalog { _ in await transport.fetch() }, autoRefreshCatalogs: false)
        let refresh = Task { await controller.refreshOpenRouterCatalog(providerID: "router", force: true) }
        await fulfillment(of: [started], timeout: 2)
        try controller.updateProvider(id: "router", name: "Router", address: "https://example.com/v1", models: "model", secret: "")
        XCTAssertTrue(controller.refreshingCatalogs.isEmpty)
        XCTAssertThrowsError(try controller.requirePackageSnapshotIdle())
        await transport.finish()
        await refresh.value
        XCTAssertNoThrow(try controller.requirePackageSnapshotIdle())
        XCTAssertEqual(controller.state.providers[0].baseURL, "https://example.com/v1")
    }

    func testFailedReloadFencesStaleSnapshotFromWritingOverDisk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = AgentXRepository(root: root)
        let controller = AgentXController(repository: repo, credentials: AgentXTestCredentials(), autoRefreshCatalogs: false)
        let host = AgentXHostRuntimeLifecycle(controller: controller)
        var fenced = false
        host.register("blackcat", runtime: .init(fence: { fenced = true }, drain: {}, isIdle: { true }, hasExited: { true }, resume: {}))
        controller.didChange = host.synchronize
        let file = root.appendingPathComponent("agentx.yaml")
        let broken = Data("invalid: [".utf8)
        try broken.write(to: file)
        XCTAssertThrowsError(try controller.reloadApplications())
        XCTAssertFalse(controller.isLoaded)
        XCTAssertTrue(fenced)
        XCTAssertThrowsError(try controller.setBlackCatEnabled(false))
        XCTAssertEqual(try Data(contentsOf: file), broken)
    }

    func testDisabledStartupExplicitOpenRestoresAuthorizationWithoutDeliveringPending() async {
        var sends = 0, requests = 0
        let service = NotificationService(center: nil, send: { _ in sends += 1 }, authorize: { requests += 1; return true })
        service.fence()
        await service.refreshAuthorizationForExplicitOpen()
        XCTAssertEqual(requests, 0)
        XCTAssertTrue(service.resumeWithoutRunning())
        XCTAssertEqual(requests, 0)
        await service.refreshAuthorizationForExplicitOpen()
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(sends, 0, "Authorization refresh must not replay pending notifications")
        let posted = await service.postTravelPromptFallback(.summary(promptIDs: ["future"], count: 1))
        XCTAssertTrue(posted)
        XCTAssertEqual(sends, 1)
    }
    func testAuthorizationDrainWaitsForLateResponseAndDoesNotReviveAfterReenable() async {
        var continuation: CheckedContinuation<Bool, Never>?
        let started = expectation(description: "authorization started")
        var sends = 0
        let service = NotificationService(center: nil, send: { _ in sends += 1 }, authorize: {
            await withCheckedContinuation { continuation = $0; started.fulfill() }
        })
        let authorization = Task { await service.requestAuthorization() }
        await fulfillment(of: [started], timeout: 2)
        service.fence()
        var drained = false
        let stop = Task { await service.suspendAndWait(); drained = true }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(drained)
        XCTAssertTrue(service.hasOwnedOperations)
        XCTAssertFalse(service.resumeWithoutRunning())
        continuation?.resume(returning: true)
        await authorization.value
        await stop.value
        XCTAssertTrue(service.resumeWithoutRunning())
        let posted = await service.postTravelPromptFallback(.summary(promptIDs: ["late"], count: 1))
        XCTAssertFalse(posted, "A cancelled authorization result cannot grant a later lifecycle permission")
        XCTAssertEqual(sends, 0)
    }

}

private actor Task3cCatalogTransport {
    let started: XCTestExpectation
    var continuation: CheckedContinuation<(Data, Int), Never>?
    init(started: XCTestExpectation) { self.started = started }
    func fetch() async -> (Data, Int) {
        await withCheckedContinuation { continuation = $0; started.fulfill() }
    }
    func finish() {
        continuation?.resume(returning: (Data(#"{"data":[{"id":"late-model"}]}"#.utf8), 200))
        continuation = nil
    }
}
