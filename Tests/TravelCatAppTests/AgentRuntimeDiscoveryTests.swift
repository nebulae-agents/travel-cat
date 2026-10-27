import Foundation
import XCTest
@testable import TravelCatApp

final class AgentRuntimeDiscoveryTests: XCTestCase {
    private let digest = String(repeating: "a", count: 64)

    func testTypedInventorySeparatesCLIsLocalContextsAndImageCandidates() throws {
        let json: [String: Any] = [
            "tools": [["kind": "codex", "path": "/opt/homebrew/bin/codex", "running": 1]],
            "contexts": [["name": "colima-agent", "local": true, "available": true],
                         ["name": "remote", "local": false, "available": false]],
            "images": [["context": "colima-agent", "ref": "localhost:5000/codex-acp@sha256:\(digest)"],
                       ["context": "colima-agent", "ref": "node@sha256:\(digest)"]],
            "containers": [["context": "colima-agent", "id": "abcdef123456", "name": "codex-worker",
                            "image": "localhost:5000/codex-acp@sha256:\(digest)", "state": "running"]]]
        let inventory = try LocalRuntimeInventory.decode(json)
        XCTAssertEqual(inventory.tools.first?.kind, "codex")
        XCTAssertEqual(inventory.tools.first?.running, 1)
        XCTAssertEqual(inventory.contexts.filter(\.local).count, 1)
        XCTAssertEqual(inventory.suggestedImages.count, 1)
        XCTAssertEqual(inventory.suggestedImages[0].suggestedPreset, .codex)
        XCTAssertEqual(inventory.containers.first?.state, "running")
        XCTAssertNotEqual(inventory.images[0].id, inventory.images[1].id)
    }

    func testQuickDraftRequiresMatchingConfirmedProbeAndProviderDetails() throws {
        let image = LocalRuntimeInventory.Image(context: "colima-agent", ref: "codex-acp@sha256:\(digest)")
        let proof = RuntimeProbeVerification(probeID: UUID(), image: image, command: ACPAdapterPreset.codex.command)
        var draft = QuickCreateDraft(verification: proof)
        draft.name = "本机开发助手"
        draft.provider.model = "gpt-test"
        draft.newKey = "secret"
        let instance = try draft.validatedInstance()
        XCTAssertEqual(instance.dockerContext, "colima-agent")
        XCTAssertEqual(instance.image, image.ref)
        XCTAssertEqual(instance.command, ACPAdapterPreset.codex.command)
        XCTAssertEqual(instance.host, "")
        XCTAssertNotEqual(instance.provider.credentialID, WorkbenchProvider().credentialID)
        draft.image = .init(context: "another", ref: image.ref)
        XCTAssertThrowsError(try draft.validatedInstance())
        draft.image = image
        draft.command = ["claude-agent-acp"]
        XCTAssertThrowsError(try draft.validatedInstance())
        draft.command = ACPAdapterPreset.codex.command
        draft.newKey = ""
        XCTAssertThrowsError(try draft.validatedInstance())
    }
}

@MainActor
private final class DiscoveryTestCredentials: TravelServiceCredentialStoring {
    var values: [String: String] = [:]
    func read(id: String) throws -> String? { values[id] }
    func save(_ secret: String?, id: String) throws { values[id] = secret }
}

@MainActor
private final class DiscoveryTestRuntime: AgentRuntimeClient {
    var onEvent: (([String: Any]) -> Void)?
    var onExit: (() -> Void)?
    var calls: [String] = []
    var image = ""
    var probeFailure: WorkbenchFailure?
    func launch(python: String) throws {}
    func request(_ method: String, _ params: [String: Any], timeout: UInt64) async throws -> [String: Any] {
        calls.append(method)
        if method == "scan_local" {
            return ["tools": [], "contexts": [["name": "colima-agent", "local": true, "available": true]],
                    "images": [["context": "colima-agent", "ref": image]], "containers": []]
        }
        if method == "probe" {
            if let probeFailure { throw probeFailure }
            return ["probeId": params["probeId"] ?? "", "compatible": true, "cleanupConfirmed": true,
                    "message": "ACP handshake and cleanup confirmed"]
        }
        return [:]
    }
    func shutdown() {}
}

private final class DiscoveryTestAudit: AgentAuditStoring {
    var fail = false
    var recordsList: [[String: Any]] = []
    func append(record: [String: Any]) throws {
        if fail { throw WorkbenchFailure("Audit offline") }
        recordsList.append(record)
    }
    func records(taskID: UUID) throws -> [[String: Any]] { recordsList }
}

extension AgentRuntimeDiscoveryTests {
    @MainActor
    func testScanAndProbeNeverSaveAndAuditFailureBlocksProbe() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = DiscoveryTestRuntime()
        runtime.image = "codex-acp@sha256:\(digest)"
        let audit = DiscoveryTestAudit()
        let model = AgentWorkbenchModel(root: root, credentials: DiscoveryTestCredentials(), client: runtime, auditStore: audit)
        await model.scanLocal()
        let image = try XCTUnwrap(model.localInventory?.suggestedImages.first)
        XCTAssertTrue(model.state.instances.isEmpty)
        audit.fail = true
        await model.probe(image: image, preset: .codex)
        XCTAssertFalse(runtime.calls.contains("probe"))
        XCTAssertNil(model.probeVerification)
        audit.fail = false
        await model.probe(image: image, preset: .codex)
        XCTAssertNotNil(model.probeVerification)
        XCTAssertTrue(model.state.instances.isEmpty)
        XCTAssertEqual(audit.recordsList.map { $0["kind"] as? String }, ["runtime.probe.request", "runtime.probe.result"])
    }

    @MainActor
    func testPreflightRejectionDoesNotBlockFutureProbesAsUncertainCleanup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = DiscoveryTestRuntime()
        runtime.image = "codex-acp@sha256:\(digest)"
        runtime.probeFailure = WorkbenchFailure("selected pinned image unavailable", taskRetained: false)
        let audit = DiscoveryTestAudit()
        let model = AgentWorkbenchModel(root: root, credentials: DiscoveryTestCredentials(), client: runtime, auditStore: audit)
        await model.scanLocal()
        let image = try XCTUnwrap(model.localInventory?.suggestedImages.first)
        await model.probe(image: image, preset: .codex)
        XCTAssertNil(model.retainedProbe)
        XCTAssertNil(model.probeVerification)
        XCTAssertEqual(audit.recordsList.last?["phase"] as? String, "rejected")
    }
}
