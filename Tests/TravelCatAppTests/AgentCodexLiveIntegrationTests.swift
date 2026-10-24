import Foundation
import XCTest
@testable import TravelCatApp

@MainActor private final class LiveIntegrationCredentials: TravelServiceCredentialStoring {
    private var values: [String: String] = [:]
    func read(id: String) throws -> String? { values[id] }
    func save(_ secret: String?, id: String) throws { values[id] = secret }
}
/// Transparent production transport: captures only the current task's returned identity.
@MainActor private final class LiveIdentityClient: AgentRuntimeClient {
    var onEvent: (([String: Any]) -> Void)?
    var onExit: (() -> Void)?
    let actual = AgentSidecarClient()
    var containers: [UUID: String] = [:]
    var deniedCalls = Set<UUID>()
    init() { actual.onEvent = { [weak self] in self?.onEvent?($0) }; actual.onExit = { [weak self] in self?.onExit?() } }
    func launch(python: String) throws { try actual.launch(python: python) }
    func shutdown() { actual.shutdown() }
    func request(_ method: String, _ params: [String: Any], timeout: UInt64) async throws -> [String: Any] {
        let result = try await actual.request(method, params, timeout: timeout)
        if method == "start", let task = (params["taskId"] as? String).flatMap(UUID.init(uuidString:)), let name = result["containerName"] as? String { containers[task] = name }
        if method == "model_permission", params["allow"] as? Bool == false, let call = (params["callId"] as? String).flatMap(UUID.init(uuidString:)) { deniedCalls.insert(call) }
        return result
    }
}

/// Real Docker/ACP; denies the first model call. External fixture writes never prove Agent authorship.
final class AgentCodexLiveIntegrationTests: XCTestCase {
    private struct DockerResult { let status: Int32; let output: Data; let error: Data }
    private func docker(_ context: String, _ args: [String], input: Data? = nil) throws -> DockerResult {
        let process = Process(), output = Pipe(), error = Pipe(), stdin = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["docker", "--context", context] + args
        process.standardOutput = output; process.standardError = error; process.standardInput = stdin
        try process.run(); try stdin.fileHandleForWriting.write(contentsOf: input ?? Data()); try stdin.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(15)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { process.terminate(); throw WorkbenchFailure("Bounded Docker command timed out; retained evidence requires cleanup.") }
        return .init(status: process.terminationStatus, output: output.fileHandleForReading.readDataToEndOfFile(), error: error.fileHandleForReading.readDataToEndOfFile())
    }
    private func requireGone(_ context: String, _ id: String) throws {
        let result = try docker(context, ["container", "inspect", id])
        guard result.status != 0, String(decoding: result.error, as: UTF8.self).contains("No such container"),
              try docker(context, ["version", "--format", "{{.Server.Version}}"]).status == 0 else {
            throw WorkbenchFailure("Exact owned container removal was not confirmed; test evidence retained.")
        }
    }
    private func pdf() -> Data {
        var result = "%PDF-1.4\n", offsets = [0]
        let objects = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 4 0 R >>", "<< /Length 0 >>\nstream\n\nendstream",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 6 0 R >>", "<< /Length 0 >>\nstream\n\nendstream"]
        for (index, object) in objects.enumerated() { offsets.append(result.utf8.count); result += "\(index + 1) 0 obj\n\(object)\nendobj\n" }
        let xref = result.utf8.count
        result += "xref\n0 7\n0000000000 65535 f \n" + offsets.dropFirst().map { String(format: "%010d 00000 n \n", $0) }.joined()
        result += "trailer\n<< /Size 7 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"; return Data(result.utf8)
    }
    @MainActor func testRealSidecarCodexApprovalAuditAndCleanup() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["TRAVEL_CAT_CODEX_LIVE_TEST"] == "1" else { throw XCTSkip("Requires isolated local Docker/ACP image; opt in with TRAVEL_CAT_CODEX_LIVE_TEST=1.") }
        let image = try XCTUnwrap(env["TRAVEL_CAT_CODEX_LIVE_IMAGE"]), context = try XCTUnwrap(env["TRAVEL_CAT_CODEX_LIVE_CONTEXT"])
        XCTAssertEqual(context, "colima-travelcat-agent", "This acceptance is restricted to its explicit isolated context")
        guard context == "colima-travelcat-agent" else { throw WorkbenchFailure("Unexpected live acceptance context") }
        let imageCheck = try docker(context, ["image", "inspect", image, "--format", "{{.Id}}"])
        guard imageCheck.status == 0, image.hasSuffix(String(decoding: imageCheck.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else { throw WorkbenchFailure("Pinned local image unavailable; no pull attempted") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("travelcat-codex-live-\(UUID().uuidString)")
        let downloads = root.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let client = LiveIdentityClient(), model = AgentWorkbenchModel(root: root.appendingPathComponent("store"), credentials: LiveIntegrationCredentials(), client: client)
        var instance = WorkbenchInstance(name: "Codex integration fixture", image: image, command: ["/opt/travelcat-acp/node_modules/.bin/codex-acp"])
        instance.dockerContext = context; instance.provider.baseURL = "https://127.0.0.1/v1"; instance.provider.model = "integration-test-model"
        try model.save(instance: instance, newKey: "test-only-invalid-key")
        let textA = Data("Version A\n".utf8), textB = Data("Version B\n".utf8)
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNQaHAAAAGkAOGt06eBAAAAAElFTkSuQmCC"))
        let imported = ["report.txt": textA, "preview.png": png, "two-pages.pdf": pdf()]
        let prompt = Task { await model.start(instanceID: instance.id, text: "Reply with HELLO only.", files: imported.map { ["name": $0.key, "base64": $0.value.base64EncodedString()] }) }
        var exactID: String?, activeApproval: WorkbenchModelApproval?
        var result: [String: Any] = ["authorship": "External test-owned write; no Agent authorship claim", "context": context, "image": image]
        do {
            for _ in 0..<240 {
                if let first = model.modelApprovals.first { activeApproval = first; break }
                if model.state.tasks.first?.status == .failed { break }
                try await Task.sleep(for: .milliseconds(250))
            }
            let approval = try XCTUnwrap(activeApproval, "The real ACP adapter must reach its first audited model approval")
            let taskID = approval.taskID, began = Date()
            let name = try XCTUnwrap(client.containers[taskID])
            let inspected = try docker(context, ["container", "inspect", name])
            guard inspected.status == 0 else { throw WorkbenchFailure("Exact runtime-owned container inspection failed") }
            let info = try XCTUnwrap((JSONSerialization.jsonObject(with: inspected.output) as? [[String: Any]])?.first)
            let config = try XCTUnwrap(info["Config"] as? [String: Any]), host = try XCTUnwrap(info["HostConfig"] as? [String: Any])
            guard info["Name"] as? String == "/" + name, config["Image"] as? String == image,
                  config["User"] as? String == "65532:65532", host["ReadonlyRootfs"] as? Bool == true,
                  host["NetworkMode"] as? String == "none", (info["Mounts"] as? [[String: Any]] ?? []).allSatisfy({ $0["Type"] as? String == "tmpfs" }),
                  let id = info["Id"] as? String, id.count == 64 else { throw WorkbenchFailure("Owned container sandbox or identity mismatch; no external write attempted") }
            exactID = id; result["taskId"] = taskID.uuidString; result["containerId"] = id
            XCTAssertEqual(approval.destination, "https://127.0.0.1/v1/responses")
            XCTAssertTrue(model.auditRecords(taskID: taskID).contains { $0["kind"] as? String == "model.request" })
            let initial = try await model.listArtifacts(taskID: taskID)
            let baseline = try XCTUnwrap(model.artifactInventories[taskID])
            XCTAssertTrue(baseline.inventoryComplete && baseline.hashComplete && baseline.baselineInventoryComplete && baseline.baselineHashComplete)
            XCTAssertNotNil(baseline.baselineCapturedAt); XCTAssertFalse(baseline.bindingID.isEmpty); XCTAssertNotNil(baseline.executionID)
            var previews: [String: WorkbenchArtifactPreview] = [:], hashes: [String: String] = [:]
            for (path, bytes) in imported {
                let artifact = try XCTUnwrap(initial.first { $0.path == path })
                XCTAssertEqual(artifact.change, "unchanged", "Initial imports belong to the true pre-prompt baseline")
                XCTAssertEqual(artifact.sha256, WorkbenchArtifactPreview.digest(bytes)); XCTAssertEqual(artifact.bindingID, baseline.bindingID)
                let preview = try await model.loadArtifact(taskID: taskID, artifact: artifact)
                XCTAssertEqual(preview.bytes, bytes); previews[path] = preview
                // Model-history contract only; native presentation is accepted separately through CUA.
                try model.rememberArtifactPreview(taskID: taskID, preview: preview)
                try await model.confirmArtifact(taskID: taskID, preview: preview)
                XCTAssertTrue(model.isArtifactConfirmed(taskID: taskID, preview: preview))
                let target = downloads.appendingPathComponent(path)
                try model.downloadArtifactPreview(taskID: taskID, preview: preview, to: target)
                XCTAssertEqual(try Data(contentsOf: target), bytes); hashes[path] = WorkbenchArtifactPreview.digest(try Data(contentsOf: target))
            }
            // Only the inspected exact ID receives this external, test-owned same-size write.
            guard Date().timeIntervalSince(began) < 90 else { throw WorkbenchFailure("Acceptance budget exhausted before external write") }
            let write = try docker(context, ["exec", "-i", id, "python3", "-I", "-S", "-B", "-c", "import sys; from pathlib import Path; p=Path('/tmp/workspace/report.txt'); b=sys.stdin.buffer.read(64); assert len(b)==p.stat().st_size; p.write_bytes(b)"], input: textB)
            guard write.status == 0 else { throw WorkbenchFailure("Bounded test-owned write failed") }
            let changedFiles = try await model.listArtifacts(taskID: taskID)
            let changed = try XCTUnwrap(changedFiles.first { $0.path == "report.txt" })
            let old = try XCTUnwrap(previews["report.txt"])
            XCTAssertEqual(changed.size, old.artifact.size); XCTAssertEqual(changed.change, "modified"); XCTAssertNotEqual(changed.sha256, old.sha256)
            XCTAssertEqual(old.bytes, textA); XCTAssertEqual(old.versionStatus(current: changed), .old)
            do { try await model.confirmArtifact(taskID: taskID, preview: old); XCTFail("Stale A confirmation must be rejected") }
            catch { XCTAssertTrue(error.localizedDescription.contains("文件已变化")) }
            let fresh = try await model.loadArtifact(taskID: taskID, artifact: changed)
            XCTAssertEqual(fresh.bytes, textB); try model.rememberArtifactPreview(taskID: taskID, preview: fresh)
            try await model.confirmArtifact(taskID: taskID, preview: fresh)
            XCTAssertTrue(model.isArtifactConfirmed(taskID: taskID, preview: old)); XCTAssertTrue(model.isArtifactConfirmed(taskID: taskID, preview: fresh))
            for (name, preview) in [("report-old-A.txt", old), ("report-new-B.txt", fresh)] {
                let target = downloads.appendingPathComponent(name); try model.downloadArtifactPreview(taskID: taskID, preview: preview, to: target)
                XCTAssertEqual(try Data(contentsOf: target), preview.bytes); hashes[name] = WorkbenchArtifactPreview.digest(try Data(contentsOf: target))
            }
            XCTAssertEqual(model.artifactHistory(taskID: taskID, path: "preview.png").count, 1)
            XCTAssertNil(model.artifactHistory(taskID: taskID, path: "preview.png").first?.text)
            XCTAssertEqual(model.artifactHistory(taskID: taskID, path: "two-pages.pdf").count, 1)
            XCTAssertNil(model.artifactHistory(taskID: taskID, path: "two-pages.pdf").first?.text)
            XCTAssertLessThan(Date().timeIntervalSince(began), 110, "Complete reads/writes before the model approval's 120 second expiry")
            result["pendingArtifactSeconds"] = Date().timeIntervalSince(began)
            await model.respondModel(approval, allow: false)
            XCTAssertTrue(client.deniedCalls.contains(approval.callID), "Explicit deny RPC must be acknowledged before the approval deadline")
            activeApproval = nil; await prompt.value
            let records = model.auditRecords(taskID: taskID)
            let kinds = records.compactMap { $0["kind"] as? String }
            let decisions = records.filter { $0["kind"] as? String == "model.decision" }
            XCTAssertEqual(kinds.filter { $0 == "model.request" }.count, 1)
            XCTAssertEqual(decisions.count, 1)
            XCTAssertTrue(decisions.allSatisfy { $0["allow"] as? Bool == false })
            XCTAssertFalse(kinds.contains("model.response"))
            result["explicitDenyAcknowledged"] = client.deniedCalls.contains(approval.callID)
            result["modelRequestCount"] = 1; result["allowedUpstreamDecisions"] = 0
            result["promptStatusBeforeStop"] = model.state.tasks.first { $0.id == taskID }?.status.rawValue ?? "missing"
            for kind in ["model.decision", "model.failed", "operation.artifactBaseline", "artifact.confirm.verified", "artifact.download.completed"] { XCTAssertTrue(kinds.contains(kind), kind) }
            XCTAssertFalse(kinds.contains("model.completed")); XCTAssertNil(model.auditError)
            await model.stop(taskID); guard !model.isLive(taskID) else { throw WorkbenchFailure("Container cleanup unconfirmed") }
            try requireGone(context, id)
            XCTAssertTrue(model.auditRecords(taskID: taskID).contains { $0["kind"] as? String == "operation.stop" })
            let sealed = try Data(contentsOf: root.appendingPathComponent("store/workbench.sealed"))
            XCTAssertFalse(String(decoding: sealed, as: UTF8.self).contains("Reply with HELLO"))
            result["downloadSHA256"] = hashes; result["auditKinds"] = kinds; result["totalAfterApprovalSeconds"] = Date().timeIntervalSince(began)
            result["cleanupConfirmed"] = true; result["upstreamModelCompleted"] = false
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: "/private/tmp/travelcat-r8-live-result.json"))
            model.shutdown(); try FileManager.default.removeItem(at: root)
        } catch {
            if let approval = activeApproval { await model.respondModel(approval, allow: false) }
            if let taskID = model.state.tasks.first?.id { await model.stop(taskID) }
            prompt.cancel(); model.shutdown()
            result["cleanupConfirmed"] = false
            if let exactID { do { try requireGone(context, exactID); result["cleanupConfirmed"] = true } catch {} }
            result["failed"] = true; result["retainedEvidence"] = root.path
            try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("failure-metadata.json"))
            throw error // Failure evidence remains even when cleanup succeeds; never hide residue with defer deletion.
        }
    }
}
