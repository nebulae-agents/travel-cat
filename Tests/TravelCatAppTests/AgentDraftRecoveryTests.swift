import Foundation
import XCTest
@testable import TravelCatApp

@MainActor private final class DraftCredentials: TravelServiceCredentialStoring {
    var values: [String: String] = ["workbench-content-v1": Data(repeating: 17, count: 32).base64EncodedString(), "audit-journal-v1": Data(repeating: 29, count: 32).base64EncodedString()]
    func read(id: String) throws -> String? { values[id] ?? "test-model" }
    func save(_ secret: String?, id: String) throws { values[id] = secret }
}
private actor DraftAsyncCredentials: AsyncTravelServiceCredentialStoring {
    var values: [String: String]
    init(_ values: [String: String]) { self.values = values }
    func read(id: String) async throws -> String? { values[id] }
    func save(_ secret: String?, id: String) async throws { values[id] = secret }
}
@MainActor private final class DraftRuntime: AgentRuntimeClient {
    var onEvent: (([String: Any]) -> Void)?
    var onExit: (() -> Void)?
    var calls: [String] = []
    var beforeStart: (() async -> Void)?
    var beforePrompt: (() async -> Void)?
    var failure: Error?
    var session: String? = "draft-fixture-session"
    func launch(python: String) throws {}
    func request(_ method: String, _ params: [String: Any], timeout: UInt64) async throws -> [String: Any] {
        calls.append(method)
        if method == "start" { await beforeStart?(); return session.map { ["sessionId": $0] } ?? [:] }
        if method == "prompt" { await beforePrompt?(); if let failure { throw failure } }
        return [:]
    }
    func shutdown() { onExit?() }
}
final class AgentDraftRecoveryTests: XCTestCase {
    @MainActor private func fixture() throws -> (AgentWorkbenchModel, DraftRuntime, DraftCredentials, URL, WorkbenchInstance) {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let runtime = DraftRuntime(), credentials = DraftCredentials()
        let model = AgentWorkbenchModel(root: root, credentials: credentials, client: runtime)
        var instance = WorkbenchInstance(name: "Draft fixture", image: "agent@sha256:" + String(repeating: "a", count: 64), command: ["test-acp"])
        instance.provider.model = "fixture"
        try model.save(instance: instance, newKey: "")
        return (model, runtime, credentials, root, instance)
    }
    @MainActor func testImmediateShutdownFlushesAllTargetsWithoutReplayingOrRestoringConsent() throws {
        let (model, _, credentials, root, instance) = try fixture()
        let task = WorkbenchTask(instanceID: instance.id, title: "existing")
        model.state.tasks = [task]
        let targets: [WorkbenchDraftTarget] = [.new(instance.id), .new(UUID()), .new(nil), .task(task.id)]
        for (index, target) in targets.enumerated() {
            model.updateDraft(target) { $0.text = "private recovery \(index)"; $0.files = [["name": "input.bin", "base64": "AP8="]]; $0.parentTaskID = task.id }
        }
        let expected = targets.map { model.draft(for: $0) }
        model.shutdown()
        let runtime = DraftRuntime(), reopened = AgentWorkbenchModel(root: root, credentials: credentials, client: runtime)
        defer { reopened.shutdown() }
        XCTAssertEqual(targets.map { reopened.draft(for: $0) }, expected)
        XCTAssertTrue(runtime.calls.isEmpty)
        XCTAssertTrue(reopened.permissions.isEmpty)
        XCTAssertTrue(reopened.modelApprovals.isEmpty)
        XCTAssertTrue(AgentWorkbenchPresentation().modelConsent.isEmpty)
        XCTAssertEqual(reopened.state.tasks.first?.id, task.id)
        XCTAssertNil(try Data(contentsOf: reopened.store.url).range(of: Data("private recovery".utf8)))
    }
    @MainActor func testDraftDebounceIsNotStarvedByContinuousRuntimeMutation() async throws {
        let (model, _, _, _, instance) = try fixture()
        defer { model.shutdown() }
        let task = WorkbenchTask(instanceID: instance.id, title: "continuous events")
        model.state.tasks = [task]
        model.updateDraft(.task(task.id)) { $0.text = "save while streaming" }
        for _ in 0..<20 {
            model.mutate(task.id) { $0.messages.append(.init(role: "assistant", text: "stream")) }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(try model.store.load().drafts?.draft(for: .task(task.id)).text, "save while streaming")
    }
    @MainActor func testWindowPresentationRecreationKeepsModelDraftAndNilTargetAccessible() throws {
        let (model, _, _, _, instance) = try fixture(); defer { model.shutdown() }
        model.updateDraft(.new(nil)) { $0.text = "before choosing Agent" }
        model.updateDraft(.new(instance.id)) { $0.text = "Agent specific" }
        _ = AgentWorkbenchPresentation()
        model.openInstance(instance.id); model.preferredInstanceID = nil
        XCTAssertEqual(model.draft(for: .new(nil)).text, "before choosing Agent")
        XCTAssertEqual(model.draft(for: .new(instance.id)).text, "Agent specific")
    }
    @MainActor func testSaveFailureKeepsMemoryOldCiphertextNoticeAndAllowsRetry() throws {
        let (model, _, _, _, instance) = try fixture(); defer { model.shutdown() }
        let originalStore = model.store, bytes = try Data(contentsOf: model.store.url)
        model.store = WorkbenchStore(root: model.store.root, keyData: Data(repeating: 99, count: 32))
        model.updateDraft(.new(instance.id)) { $0.text = "unsaved revision" }
        model.retryDraftSave()
        XCTAssertEqual(try Data(contentsOf: originalStore.url), bytes)
        XCTAssertEqual(model.draft(for: .new(instance.id)).text, "unsaved revision")
        XCTAssertNotNil(model.draftSaveNotice)
        model.store = originalStore; model.retryDraftSave()
        XCTAssertNil(model.draftSaveNotice)
        XCTAssertEqual(try model.store.load().drafts?.draft(for: .new(instance.id)).text, "unsaved revision")
    }
    @MainActor func testPrebootstrapEditsCannotReplaceEncryptedDraft() async throws {
        let (initial, _, credentials, root, instance) = try fixture()
        let target = WorkbenchDraftTarget.new(instance.id)
        initial.updateDraft(target) { $0.text = "existing encrypted draft" }; initial.shutdown()
        let before = try Data(contentsOf: initial.store.url), asyncCredentials = DraftAsyncCredentials(credentials.values)
        let model = AgentWorkbenchModel(root: root, credentialStores: .init(content: asyncCredentials, audit: asyncCredentials, models: asyncCredentials), client: DraftRuntime())
        model.updateDraft(target) { $0.text = "must never overwrite" }
        model.retryDraftSave()
        XCTAssertEqual(try Data(contentsOf: initial.store.url), before)
        await model.loadStorage()
        XCTAssertEqual(model.draft(for: target).text, "existing encrypted draft")
        model.shutdown()
    }
    @MainActor func testNewAgentRemovalCannotOrphanNonemptyDraft() async throws {
        let (model, _, _, _, instance) = try fixture(); defer { model.shutdown() }
        model.updateDraft(.new(instance.id)) { $0.text = "protect this draft" }
        await model.removeInstance(instanceID: instance.id)
        XCTAssertTrue(model.state.instances.contains { $0.id == instance.id })
        XCTAssertTrue(model.error?.contains("草稿") == true)
        model.remove(instanceID: instance.id)
        XCTAssertTrue(model.state.instances.contains { $0.id == instance.id })
    }
    @MainActor func testPendingSameRevisionCannotStartTwiceAndConfirmationKeepsNewerEdits() async throws {
        let (model, runtime, _, _, instance) = try fixture(); defer { model.shutdown() }
        let target = WorkbenchDraftTarget.new(instance.id)
        model.updateDraft(target) { $0.text = "submitted" }
        runtime.beforePrompt = {
            XCTAssertEqual(model.draft(for: target).text, "submitted")
            XCTAssertTrue(model.isDraftSubmitting(target))
            await model.startDraft(target: target, instanceID: instance.id)
            XCTAssertEqual(runtime.calls, ["start", "prompt"])
            model.updateDraft(target) { $0.text = "new revision" }
            XCTAssertFalse(model.isDraftSubmitting(target))
        }
        await model.startDraft(target: target, instanceID: instance.id)
        XCTAssertEqual(model.draft(for: target).text, "new revision")
        model.shutdown()
        XCTAssertEqual(try model.store.load().drafts?.draft(for: target).text, "new revision")
    }
    @MainActor func testSuccessfulPromptClearsOnlyItsSubmittedTarget() async throws {
        let (model, _, _, _, instance) = try fixture(); defer { model.shutdown() }
        let target = WorkbenchDraftTarget.new(instance.id), other = WorkbenchDraftTarget.new(nil)
        model.updateDraft(target) { $0.text = "submit" }
        model.updateDraft(other) { $0.text = "retain other" }
        await model.startDraft(target: target, instanceID: instance.id)
        XCTAssertTrue(model.draft(for: target).isEmpty)
        XCTAssertEqual(model.draft(for: other).text, "retain other")
        XCTAssertTrue(try model.store.load().drafts?.draft(for: target).isEmpty == true)
    }
    @MainActor func testFailedAndUnknownSubmissionRemainRecoverable() async throws {
        let (model, runtime, _, _, instance) = try fixture(); defer { model.shutdown() }
        let target = WorkbenchDraftTarget.new(instance.id)
        model.updateDraft(target) { $0.text = "retain after unknown" }
        let revision = model.draft(for: target).revision
        runtime.session = nil
        await model.startDraft(target: target, instanceID: instance.id)
        XCTAssertEqual(model.draft(for: target).revision, revision)
        runtime.session = "session"; runtime.failure = WorkbenchFailure("prompt transport unknown")
        await model.startDraft(target: target, instanceID: instance.id)
        XCTAssertEqual(model.draft(for: target).revision, revision)
        model.shutdown()
        XCTAssertEqual(try model.store.load().drafts?.draft(for: target).revision, revision)
        XCTAssertEqual(runtime.calls, ["start", "start", "prompt"])
    }
    @MainActor func testFollowUpFailureKeepsDraftAndSuccessOnlyClearsUneditedRevision() async throws {
        let (model, runtime, _, _, instance) = try fixture(); defer { model.shutdown() }
        await model.start(instanceID: instance.id, text: "initial")
        let task = try XCTUnwrap(model.state.tasks.first), target = WorkbenchDraftTarget.task(task.id)
        model.updateDraft(target) { $0.text = "follow up" }
        runtime.failure = WorkbenchFailure("unknown")
        await model.followUpDraft(taskID: task.id)
        XCTAssertEqual(model.draft(for: target).text, "follow up")
        model.state.tasks[0].status = .completed; runtime.failure = nil
        runtime.beforePrompt = { model.updateDraft(target) { $0.text = "edited while waiting" } }
        await model.followUpDraft(taskID: task.id)
        XCTAssertEqual(model.draft(for: target).text, "edited while waiting")
        runtime.beforePrompt = nil
        await model.followUpDraft(taskID: task.id)
        XCTAssertTrue(model.draft(for: target).isEmpty)
    }
}

extension AgentDraftRecoveryTests {
    @MainActor func testInvalidInMemoryDraftKeepsPriorCiphertextAndCanBeCorrected() throws {
        let (model, _, _, _, instance) = try fixture(); defer { model.shutdown() }
        model.updateDraft(.new(instance.id)) { $0.text = "saved version" }; model.retryDraftSave()
        let bytes = try Data(contentsOf: model.store.url)
        model.updateDraft(.new(instance.id)) { $0.text = String(repeating: "x", count: 100_001) }
        model.retryDraftSave()
        XCTAssertEqual(model.draft(for: .new(instance.id)).text.count, 100_001)
        XCTAssertNotNil(model.draftSaveNotice)
        XCTAssertEqual(try Data(contentsOf: model.store.url), bytes)
        model.updateDraft(.new(instance.id)) { $0.text = "corrected" }; model.retryDraftSave()
        XCTAssertNil(model.draftSaveNotice)
        XCTAssertEqual(try model.store.load().drafts?.draft(for: .new(instance.id)).text, "corrected")
    }
    @MainActor func testFollowUpCannotSilentlyDiscardAttachmentsItDoesNotSubmit() async throws {
        let (model, runtime, _, _, instance) = try fixture(); defer { model.shutdown() }
        await model.start(instanceID: instance.id, text: "initial")
        let task = try XCTUnwrap(model.state.tasks.first), target = WorkbenchDraftTarget.task(task.id)
        model.updateDraft(target) { $0.text = "reply with retained attachment"; $0.files = [["name": "input", "base64": "AA=="]] }
        await model.followUpDraft(taskID: task.id)
        XCTAssertEqual(model.draft(for: target).files.count, 1)
        XCTAssertEqual(runtime.calls, ["start", "prompt"])
        XCTAssertTrue(model.error?.contains("文件") == true)
    }
}

extension AgentDraftRecoveryTests {
    @MainActor func testReadOnlyDirectoryKeepsCiphertextAndDraftUntilRetrySucceeds() throws {
        let (model, _, _, root, instance) = try fixture(); defer { model.shutdown() }
        let original = try Data(contentsOf: model.store.url), target = WorkbenchDraftTarget.new(instance.id)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
        model.updateDraft(target) { $0.text = "retain after failed disk write" }
        model.retryDraftSave()
        XCTAssertEqual(try Data(contentsOf: model.store.url), original)
        XCTAssertEqual(model.draft(for: target).text, "retain after failed disk write")
        XCTAssertNotNil(model.draftSaveNotice)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        model.retryDraftSave()
        XCTAssertNil(model.draftSaveNotice)
        XCTAssertEqual(try model.store.load().drafts?.draft(for: target).text, "retain after failed disk write")
    }
}

extension AgentDraftRecoveryTests {
    func testHandoffSourceHasVisibleExplicitRemovalControl() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/TravelCatApp/AgentMessageEditor.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("if let parentID = draft.parentTaskID"))
        XCTAssertTrue(source.contains("承接来源"))
        XCTAssertTrue(source.contains("Button(\"移除承接来源\", action: removeParent)"))
    }
}

extension AgentDraftRecoveryTests {
    @MainActor func testClearedHandoffCanRemoveSourceDeleteAgentAndReopenWithoutGhostDraft() async throws {
        let (model, _, credentials, root, instance) = try fixture()
        let target = WorkbenchDraftTarget.new(instance.id)
        var sourceTask = WorkbenchTask(instanceID: UUID(), title: "Handoff source")
        sourceTask.messages = [.init(role: "assistant", text: "Original source result")]
        model.state.tasks = [sourceTask]
        model.updateDraft(target) { $0.text = "Handoff context"; $0.files = [["name": "input", "base64": "AA=="]]; $0.parentTaskID = sourceTask.id }
        model.updateDraft(target) { $0.text = ""; $0.files = [] }
        await model.removeInstance(instanceID: instance.id)
        XCTAssertTrue(model.state.instances.contains { $0.id == instance.id })
        XCTAssertEqual(model.draft(for: target).parentTaskID, sourceTask.id)
        model.removeDraftParent(target)
        XCTAssertTrue(model.draft(for: target).isEmpty)
        model.shutdown()
        let reopened = AgentWorkbenchModel(root: root, credentials: credentials, client: DraftRuntime())
        XCTAssertTrue(reopened.draft(for: target).isEmpty)
        await reopened.removeInstance(instanceID: instance.id)
        XCTAssertFalse(reopened.state.instances.contains { $0.id == instance.id })
        XCTAssertEqual(reopened.state.tasks.first?.messages, sourceTask.messages)
        reopened.shutdown()
        let final = AgentWorkbenchModel(root: root, credentials: credentials, client: DraftRuntime())
        defer { final.shutdown() }
        XCTAssertFalse(final.state.instances.contains { $0.id == instance.id })
        XCTAssertTrue(final.draft(for: target).isEmpty)
        XCTAssertNil(final.draft(for: target).parentTaskID)
    }
    @MainActor func testRemovingHandoffSourcePreservesBodyFilesAndProtectsNewRevision() async throws {
        let (model, _, _, _, instance) = try fixture(); defer { model.shutdown() }
        let target = WorkbenchDraftTarget.new(instance.id)
        model.updateDraft(target) { $0.text = "Keep body"; $0.files = [["name": "input", "base64": "AP8="]]; $0.parentTaskID = UUID() }
        let submitted = model.draft(for: target)
        model.removeDraftParent(target)
        let changed = model.draft(for: target)
        XCTAssertNil(changed.parentTaskID)
        XCTAssertEqual(changed.text, submitted.text)
        XCTAssertEqual(changed.files, submitted.files)
        XCTAssertNotEqual(changed.revision, submitted.revision)
        model.clearDraft(target, submittedRevision: submitted.revision)
        XCTAssertEqual(model.draft(for: target), changed)
        await model.removeInstance(instanceID: instance.id)
        model.remove(instanceID: instance.id)
        XCTAssertTrue(model.state.instances.contains { $0.id == instance.id })
        model.updateDraft(target) { $0.text = "" }
        await model.removeInstance(instanceID: instance.id)
        XCTAssertTrue(model.state.instances.contains { $0.id == instance.id }, "Files alone must still protect the draft")
    }
}
