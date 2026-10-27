import Foundation
import XCTest
@testable import TravelCatApp

@MainActor
private final class RecoveryDeniedCredentials: TravelServiceCredentialStoring {
    func read(id: String) throws -> String? { throw TravelServiceCredentialError.keychain(-25293) }
    func save(_ secret: String?, id: String) throws { XCTFail("Denied credentials must not be changed") }
}

@MainActor
private final class RecoveryRuntime: AgentRuntimeClient {
    var onEvent: (([String: Any]) -> Void)?
    var onExit: (() -> Void)?
    var launches = 0
    var calls: [String] = []
    func launch(python: String) throws { launches += 1 }
    func request(_ method: String, _ params: [String: Any], timeout: UInt64) async throws -> [String: Any] {
        calls.append(method)
        if method == "start" { return ["sessionId": "fixture-session"] }
        if method == "stop" { return ["stopped": true] }
        return ["tools": [], "contexts": [], "images": [], "containers": []]
    }
    func shutdown() {}
}

final class AgentWorkbenchRecoveryTests: XCTestCase {
    @MainActor func testKeychainDenialOffersInAppRetry() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AgentWorkbenchModel(root: root, credentials: RecoveryDeniedCredentials(), client: RecoveryRuntime())
        XCTAssertTrue(model.error?.contains("重试") == true)
        XCTAssertFalse(model.error?.contains("重新打开应用") == true)
        model.shutdown()
    }

    @MainActor func testUnavailableStorageBlocksRuntimeEntryPoints() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = RecoveryRuntime()
        let model = AgentWorkbenchModel(root: root, credentials: RecoveryDeniedCredentials(), client: runtime)
        let id = UUID()
        model.nativeLoginIDs[id] = "pending-login"
        await model.discover(host: "")
        await model.scanLocal()
        await model.cancel(id)
        await model.stop(id)
        await model.cancelNativeLogin(instanceID: id)
        XCTAssertEqual(runtime.launches, 0)
        XCTAssertTrue(runtime.calls.isEmpty, "Unavailable storage sent: \(runtime.calls)")
        XCTAssertTrue(model.state.tasks.isEmpty)
        model.shutdown()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("workbench.sealed").path))
    }
}

private actor RecoveryAsyncCredentials: AsyncTravelServiceCredentialStoring {
    private var values: [String: String]
    private var deniedID: String?
    private var pausedID: String?
    private var started = false
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private(set) var reads: [String] = []
    private(set) var writes: [String] = []

    init(values: [String: String] = [:]) { self.values = values }
    func deny(_ id: String?) { deniedID = id }
    func pause(_ id: String) { pausedID = id; started = false }
    func waitUntilReadStarts() async {
        if started { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }
    func resumeRead() { releaseWaiter?.resume(); releaseWaiter = nil }
    func contents() -> [String: String] { values }
    func read(id: String) async throws -> String? {
        reads.append(id)
        // A read already in flight may return the captured secret after its instance changes.
        let value = values[id]
        if pausedID == id {
            pausedID = nil; started = true
            startedWaiter?.resume(); startedWaiter = nil
            await withCheckedContinuation { releaseWaiter = $0 }
        }
        if deniedID == id { throw TravelServiceCredentialError.keychain(-25293) }
        return value
    }
    func save(_ secret: String?, id: String) async throws { writes.append(id); values[id] = secret }
}

extension AgentWorkbenchRecoveryTests {
    @MainActor private func asyncModel(_ root: URL, _ credentials: RecoveryAsyncCredentials, runtime: RecoveryRuntime = RecoveryRuntime()) -> AgentWorkbenchModel {
        AgentWorkbenchModel(root: root, credentialStores: .init(content: credentials, audit: credentials, models: credentials), client: runtime)
    }
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func savedSnapshot(at root: URL) throws -> (WorkbenchSnapshot, [String: String], Data) {
        let key = Data(repeating: 17, count: 32)
        let auditKey = Data(repeating: 29, count: 32)
        var state = WorkbenchSnapshot()
        var task = WorkbenchTask(instanceID: UUID(), title: "preserved conversation")
        task.messages = [.init(role: "user", text: "preserved message")]
        task.status = .completed
        state.tasks = [task]
        let store = WorkbenchStore(root: root, keyData: key)
        try store.save(state)
        _ = try AgentAuditStore(root: root.appendingPathComponent("audit-v1"), keyData: auditKey)
        return (state, ["workbench-content-v1": key.base64EncodedString(), "audit-journal-v1": auditKey.base64EncodedString()], try Data(contentsOf: store.url))
    }
    @MainActor func testBootstrapReturnsImmediatelyAndMainActorRemainsResponsiveWhileAwaitingAuthorization() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let credentials = RecoveryAsyncCredentials()
        await credentials.pause("workbench-content-v1")
        let model = asyncModel(root, credentials)
        XCTAssertTrue(model.loadFailed)
        let initialReads = await credentials.reads
        XCTAssertTrue(initialReads.isEmpty)
        let opening = Task { await model.loadStorage() }
        await credentials.waitUntilReadStarts()
        // This executes on MainActor before the suspended credential read is released.
        XCTAssertFalse(model.isStorageReady)
        XCTAssertEqual(model.storageStatus, .loading)
        let duplicate = Task { await model.loadStorage() }
        await duplicate.value
        let pendingReads = await credentials.reads
        XCTAssertEqual(pendingReads, ["workbench-content-v1"])
        await credentials.resumeRead()
        await opening.value
        XCTAssertTrue(model.isStorageReady)
        model.shutdown()
    }
    @MainActor func testDenialThenRetryRestoresOriginalConversationAndKeySlots() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let (original, keys, bytes) = try savedSnapshot(at: root)
        let credentials = RecoveryAsyncCredentials(values: keys)
        await credentials.deny("workbench-content-v1")
        let runtime = RecoveryRuntime(), model = asyncModel(root, credentials, runtime: runtime)
        await model.loadStorage()
        XCTAssertFalse(model.isStorageReady)
        XCTAssertTrue(model.storageStatus.message?.contains("重试") == true)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("workbench.sealed")), bytes)
        await model.start(instanceID: UUID(), text: "blocked")
        await model.discover(host: "")
        XCTAssertTrue(runtime.calls.isEmpty)
        await credentials.deny(nil)
        await model.loadStorage()
        XCTAssertTrue(model.isStorageReady)
        XCTAssertEqual(model.state.tasks.first?.id, original.tasks.first?.id)
        XCTAssertEqual(model.state.tasks.first?.messages, original.tasks.first?.messages)
        let restoredKeys = await credentials.contents(), writes = await credentials.writes
        XCTAssertEqual(restoredKeys, keys)
        XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("workbench.sealed")), bytes)
        model.shutdown()
    }
    @MainActor func testAuditDenialKeepsLoadedContentAndBlocksEveryMutationUntilRetry() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let (original, keys, bytes) = try savedSnapshot(at: root)
        let credentials = RecoveryAsyncCredentials(values: keys)
        await credentials.deny("audit-journal-v1")
        let runtime = RecoveryRuntime(), model = asyncModel(root, credentials, runtime: runtime)
        await model.loadStorage()
        XCTAssertFalse(model.isStorageReady)
        XCTAssertTrue(model.loadFailed)
        XCTAssertEqual(model.state.tasks.first?.id, original.tasks.first?.id)
        let instance = WorkbenchInstance(name: "blocked", image: "blocked", command: ["test"])
        do { try await model.saveInstance(instance: instance, newKey: "must-not-save"); XCTFail("Save must fail closed") } catch {}
        XCTAssertThrowsError(try model.save(instance: instance, newKey: "must-not-save"))
        model.remove(instanceID: instance.id)
        model.setPythonPath("/bin/sh")
        model.markRead(original.tasks.first?.id)
        await model.cancel(original.tasks[0].id)
        await model.stop(original.tasks[0].id)
        XCTAssertFalse(model.canReply(original.tasks[0].id))
        XCTAssertTrue(runtime.calls.isEmpty)
        model.persist()
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("workbench.sealed")), bytes)
        let writes = await credentials.writes
        XCTAssertTrue(writes.isEmpty)
        await credentials.deny(nil)
        await model.loadStorage()
        XCTAssertTrue(model.isStorageReady)
        XCTAssertEqual(model.state.tasks.first?.messages, original.tasks.first?.messages)
        model.shutdown()
    }
    @MainActor func testShutdownDuringAuthorizationDoesNotGenerateReplacementKeyOrPublishLateState() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let credentials = RecoveryAsyncCredentials()
        await credentials.pause("workbench-content-v1")
        let model = asyncModel(root, credentials)
        let opening = Task { await model.loadStorage() }
        await credentials.waitUntilReadStarts()
        model.shutdown()
        await credentials.resumeRead()
        await opening.value
        let values = await credentials.contents(), writes = await credentials.writes
        XCTAssertTrue(values.isEmpty)
        XCTAssertTrue(writes.isEmpty)
        XCTAssertFalse(model.isStorageReady)
        XCTAssertTrue(model.state.tasks.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
}

extension AgentWorkbenchRecoveryTests {
    @MainActor func testAsyncExistingMissingOrInvalidKeysNeverRegenerateOrOverwriteCiphertext() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let (_, keys, bytes) = try savedSnapshot(at: root)
        for values in [[:], ["workbench-content-v1": "invalid"], ["workbench-content-v1": keys["workbench-content-v1"]!, "audit-journal-v1": "invalid"]] {
            let credentials = RecoveryAsyncCredentials(values: values)
            let model = asyncModel(root, credentials)
            await model.loadStorage()
            XCTAssertFalse(model.isStorageReady)
            model.persist(); model.shutdown()
            let after = await credentials.contents(), writes = await credentials.writes
            XCTAssertEqual(after, values)
            XCTAssertTrue(writes.isEmpty)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("workbench.sealed")), bytes)
        }
    }
    @MainActor func testShutdownWhileAwaitingAuditDoesNotCreateNewAuditKeyOrDirectory() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let key = Data(repeating: 17, count: 32)
        let store = WorkbenchStore(root: root, keyData: key)
        try store.save(WorkbenchSnapshot())
        let bytes = try Data(contentsOf: store.url)
        let values = ["workbench-content-v1": key.base64EncodedString()]
        let credentials = RecoveryAsyncCredentials(values: values)
        await credentials.pause("audit-journal-v1")
        let model = asyncModel(root, credentials)
        let opening = Task { await model.loadStorage() }
        await credentials.waitUntilReadStarts()
        model.shutdown()
        await credentials.resumeRead()
        await opening.value
        let after = await credentials.contents(), writes = await credentials.writes
        XCTAssertEqual(after, values)
        XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(try Data(contentsOf: store.url), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("audit-v1").path))
    }
    @MainActor func testProductionModelUsesAsyncCredentialSaveReadDeleteAndRejectsSyncCallers() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let credentials = RecoveryAsyncCredentials(), runtime = RecoveryRuntime()
        let model = asyncModel(root, credentials, runtime: runtime)
        await model.loadStorage()
        var instance = WorkbenchInstance(name: "async model", image: "fixture@sha256:" + String(repeating: "a", count: 64), command: ["fixture"])
        instance.provider.model = "fixture-only"
        try await model.saveInstance(instance: instance, newKey: "fixture-secret")
        XCTAssertThrowsError(try model.save(instance: instance, newKey: "must-not-save"))
        model.remove(instanceID: instance.id)
        XCTAssertTrue(model.state.instances.contains(where: { $0.id == instance.id }))
        await model.start(instanceID: instance.id, text: "offline task")
        XCTAssertEqual(runtime.calls, ["start", "prompt"])
        let reads = await credentials.reads
        XCTAssertTrue(reads.contains(instance.provider.credentialID))
        let taskID = try XCTUnwrap(model.state.tasks.first?.id)
        await model.stop(taskID)
        await model.removeInstance(instanceID: instance.id)
        let after = await credentials.contents(), writes = await credentials.writes
        XCTAssertNil(after[instance.provider.credentialID])
        XCTAssertEqual(writes.filter { $0 == instance.provider.credentialID }.count, 2)
        XCTAssertTrue(model.state.instances.isEmpty)
        model.shutdown()
    }
}

extension AgentWorkbenchRecoveryTests {
    @MainActor func testDeletingInstanceDuringCredentialReadDoesNotStartOrAcknowledgeTask() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let credentials = RecoveryAsyncCredentials(), runtime = RecoveryRuntime()
        let model = asyncModel(root, credentials, runtime: runtime)
        await model.loadStorage()
        var instance = WorkbenchInstance(name: "pending instance", image: "fixture@sha256:" + String(repeating: "a", count: 64), command: ["fixture"])
        instance.provider.model = "fixture-only"
        try await model.saveInstance(instance: instance, newKey: "fixture-secret")
        await credentials.pause(instance.provider.credentialID)
        var acknowledged = false
        let starting = Task { await model.start(instanceID: instance.id, text: "keep this draft", onStarted: { acknowledged = true }) }
        await credentials.waitUntilReadStarts()
        await model.removeInstance(instanceID: instance.id)
        XCTAssertTrue(model.state.instances.isEmpty)
        await credentials.resumeRead()
        await starting.value
        XCTAssertEqual(runtime.launches, 0)
        XCTAssertTrue(runtime.calls.isEmpty)
        XCTAssertTrue(model.state.tasks.isEmpty)
        XCTAssertFalse(acknowledged)
        XCTAssertFalse(model.isStarting)
        XCTAssertNotNil(model.error)
        model.shutdown()
    }

    @MainActor func testEditingInstanceDuringCredentialReadDoesNotStartOrAcknowledgeStaleConfiguration() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let credentials = RecoveryAsyncCredentials(), runtime = RecoveryRuntime()
        let model = asyncModel(root, credentials, runtime: runtime)
        await model.loadStorage()
        var instance = WorkbenchInstance(name: "pending instance", image: "fixture@sha256:" + String(repeating: "a", count: 64), command: ["fixture"])
        instance.provider.model = "fixture-only"
        try await model.saveInstance(instance: instance, newKey: "fixture-secret")
        await credentials.pause(instance.provider.credentialID)
        var acknowledged = false
        let starting = Task { await model.start(instanceID: instance.id, text: "keep this draft", onStarted: { acknowledged = true }) }
        await credentials.waitUntilReadStarts()
        var edited = instance
        edited.provider.model = "edited-model"
        try await model.saveInstance(instance: edited, newKey: "")
        XCTAssertEqual(model.state.instances.first, edited)
        await credentials.resumeRead()
        await starting.value
        XCTAssertEqual(runtime.launches, 0)
        XCTAssertTrue(runtime.calls.isEmpty)
        XCTAssertTrue(model.state.tasks.isEmpty)
        XCTAssertFalse(acknowledged)
        XCTAssertFalse(model.isStarting)
        XCTAssertNotNil(model.error)
        model.shutdown()
    }
}

extension AgentWorkbenchRecoveryTests {
    @MainActor func testCancelContentLoadingKeepsSingleFlightUntilSystemRequestSettlesThenCanRetry() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let (original, keys, bytes) = try savedSnapshot(at: root)
        let credentials = RecoveryAsyncCredentials(values: keys)
        await credentials.pause("workbench-content-v1")
        let model = asyncModel(root, credentials); defer { model.shutdown() }
        let opening = Task { await model.loadStorage() }
        await credentials.waitUntilReadStarts()
        XCTAssertEqual(model.storageLoadPhase, .conversations)
        let began = try XCTUnwrap(model.storageLoadStartedAt)
        XCTAssertEqual(model.storageLoadingElapsed(at: began.addingTimeInterval(21)), 21, accuracy: 0.01)
        XCTAssertEqual(model.storageLoadingElapsed(at: began.addingTimeInterval(-1)), 0)
        model.cancelStorageLoading()
        XCTAssertTrue(model.storageCancellationRequested)
        XCTAssertFalse(model.canRetryStorage)
        await model.loadStorage()
        let pendingReads = await credentials.reads
        XCTAssertEqual(pendingReads, ["workbench-content-v1"])
        await credentials.resumeRead(); await opening.value
        XCTAssertFalse(model.isStorageReady)
        XCTAssertTrue(model.storageStatus.message?.contains("取消") == true)
        XCTAssertTrue(model.canRetryStorage)
        XCTAssertNil(model.storageLoadStartedAt)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("workbench.sealed")), bytes)
        let writes = await credentials.writes
        XCTAssertTrue(writes.isEmpty)
        await model.loadStorage()
        XCTAssertTrue(model.isStorageReady)
        XCTAssertEqual(model.state.tasks.first?.id, original.tasks.first?.id)
    }

    @MainActor func testCancelAuditLoadingDoesNotCreateKeyOrPublishReadyState() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let key = Data(repeating: 17, count: 32)
        let store = WorkbenchStore(root: root, keyData: key)
        try store.save(WorkbenchSnapshot())
        let bytes = try Data(contentsOf: store.url)
        let values = ["workbench-content-v1": key.base64EncodedString()]
        let credentials = RecoveryAsyncCredentials(values: values)
        await credentials.pause("audit-journal-v1")
        let model = asyncModel(root, credentials); defer { model.shutdown() }
        let opening = Task { await model.loadStorage() }
        await credentials.waitUntilReadStarts()
        XCTAssertEqual(model.storageLoadPhase, .audit)
        model.cancelStorageLoading()
        await credentials.resumeRead(); await opening.value
        XCTAssertFalse(model.isStorageReady)
        XCTAssertTrue(model.canRetryStorage)
        XCTAssertTrue(model.storageStatus.message?.contains("取消") == true)
        let writes = await credentials.writes, after = await credentials.contents()
        XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(after, values)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("audit-v1").path))
        XCTAssertEqual(try Data(contentsOf: store.url), bytes)
        await model.loadStorage()
        XCTAssertTrue(model.isStorageReady)
        model.cancelStorageLoading()
        XCTAssertFalse(model.storageCancellationRequested)
        XCTAssertFalse(model.canRetryStorage)
        model.shutdown()
        XCTAssertFalse(model.canRetryStorage)
    }
}
