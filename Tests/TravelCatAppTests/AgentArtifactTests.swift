import Foundation
import XCTest
@testable import TravelCatApp

@MainActor private final class ArtifactCredentials: TravelServiceCredentialStoring {
    var values: [String:String] = [:]
    func read(id: String) throws -> String? { values[id] }
    func save(_ secret: String?, id: String) throws { values[id] = secret }
}
private final class ArtifactAudit: AgentAuditStoring {
    var records: [[String:Any]] = []; var reject = false
    var beforeAppend: (([String:Any]) throws -> Void)?
    func append(record: [String:Any]) throws { try beforeAppend?(record); if reject { throw WorkbenchFailure("audit denied") }; records.append(record) }
    func records(taskID: UUID) throws -> [[String:Any]] { records.filter { $0["taskId"] as? String == taskID.uuidString } }
}
@MainActor private final class ArtifactRuntime: AgentRuntimeClient {
    var onEvent: (([String:Any]) -> Void)?; var onExit: (() -> Void)?
    var requests: [String] = []; var bytes = Data("first".utf8); var invalid: [String:Any]?
    var beforeRead: (() -> Void)?
    func launch(python: String) throws {}
    func shutdown() {}
    func request(_ method: String, _ params: [String:Any], timeout: UInt64) async throws -> [String:Any] {
        requests.append(method); beforeRead?()
        if let invalid { return invalid }
        if method.hasSuffix("artifacts") { return ["files":[["path":"result.md","size":bytes.count]]] }
        return ["name":"result.md","base64":bytes.base64EncodedString()]
    }
}
final class AgentArtifactTests: XCTestCase {
    @MainActor private func fixture(native: Bool = false) throws -> (AgentWorkbenchModel, ArtifactRuntime, ArtifactAudit, ArtifactCredentials, URL, UUID) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let runtime = ArtifactRuntime(), audit = ArtifactAudit(), credentials = ArtifactCredentials()
        let model = AgentWorkbenchModel(root:root,credentials:credentials,client:runtime,auditStore:audit)
        var task = WorkbenchTask(instanceID:UUID(),title:"fixture"); task.status = .completed
        if native { task.nativeState = NativeTaskState(); task.nativeState?.connection = .connected }
        model.state.tasks = [task]; model.liveTasks.insert(task.id)
        return (model,runtime,audit,credentials,root,task.id)
    }
    @MainActor func testNativeAndACPRoutingReadActualBytesAfterAudit() async throws {
        for native in [false,true] {
            let (model,runtime,audit,_,root,id) = try fixture(native:native)
            defer { try? FileManager.default.removeItem(at:root) }
            runtime.beforeRead = { XCTAssertFalse(audit.records.isEmpty) }
            let artifacts = try await model.listArtifacts(taskID:id)
            let preview = try await model.loadArtifact(taskID:id,artifact:XCTUnwrap(artifacts.first))
            XCTAssertEqual(preview.bytes,runtime.bytes)
            XCTAssertEqual(runtime.requests,native ? ["native_artifacts","native_export"] : ["artifacts","export"])
            XCTAssertFalse(String(describing:audit.records).contains("first"))
        }
    }
    @MainActor func testConfirmationRejectsChangedFileAndPersistsExactVersion() async throws {
        let (model,runtime,_,credentials,root,id) = try fixture()
        defer { try? FileManager.default.removeItem(at:root) }
        let preview = try await model.loadArtifact(taskID:id,artifact:.init(path:"result.md",size:5))
        runtime.bytes = Data("newer".utf8)
        do { try await model.confirmArtifact(taskID:id,preview:preview); XCTFail("changed content confirmed") } catch {}
        XCTAssertFalse(model.isArtifactConfirmed(taskID:id,preview:preview))
        let current = try await model.loadArtifact(taskID:id,artifact:.init(path:"result.md",size:5))
        try await model.confirmArtifact(taskID:id,preview:current)
        XCTAssertTrue(model.isArtifactConfirmed(taskID:id,preview:current))
        XCTAssertFalse(model.isArtifactConfirmed(taskID:id,preview:preview))
        let restored = AgentWorkbenchModel(root:root,credentials:credentials,client:ArtifactRuntime(),auditStore:ArtifactAudit())
        XCTAssertTrue(restored.isArtifactConfirmed(taskID:id,preview:current))
        XCTAssertFalse(restored.state.tasks[0].unread)
        XCTAssertEqual(restored.state.tasks[0].status,.completed)
    }
    @MainActor func testAuditFailureBlocksReadConfirmAndDownload() async throws {
        let (model,runtime,audit,_,root,id) = try fixture()
        defer { try? FileManager.default.removeItem(at:root) }
        let preview = try await model.loadArtifact(taskID:id,artifact:.init(path:"result.md",size:5))
        let count = runtime.requests.count; audit.reject = true
        do { _ = try await model.listArtifacts(taskID:id); XCTFail("read bypassed audit") } catch {}
        do { try await model.confirmArtifact(taskID:id,preview:preview); XCTFail("confirm bypassed audit") } catch {}
        let destination = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".md")
        defer { try? FileManager.default.removeItem(at:destination) }
        XCTAssertThrowsError(try model.downloadArtifactPreview(taskID:id,preview:preview,to:destination))
        XCTAssertEqual(runtime.requests.count,count); XCTAssertFalse(FileManager.default.fileExists(atPath:destination.path))
    }
    @MainActor func testMalformedResponsesUnsafePathsAndDisconnectedTasksFailClosed() async throws {
        let (model,runtime,_,_,root,id) = try fixture()
        defer { try? FileManager.default.removeItem(at:root) }
        for path in ["../a","/tmp/a",".env","sub/token.txt","a//b","a\\b"] {
            do { _ = try await model.loadArtifact(taskID:id,artifact:.init(path:path,size:1)); XCTFail(path) } catch {}
        }
        XCTAssertTrue(runtime.requests.isEmpty)
        for invalid in [["files":[["path":"ok.txt","size":-1]]],["files":[["path":".env","size":1]]],["files":"invalid"]] as [[String:Any]] {
            runtime.invalid = invalid
            do { _ = try await model.listArtifacts(taskID:id); XCTFail("malformed list accepted") } catch {}
        }
        for invalid in [["name":"foreign.md","base64":"YQ=="],["name":"result.md","base64":"???"],["name":"result.md","base64":"YQ=="]] {
            runtime.invalid = invalid
            do { _ = try await model.loadArtifact(taskID:id,artifact:.init(path:"result.md",size:5)); XCTFail("bad export accepted") } catch {}
        }
        model.liveTasks.remove(id); runtime.requests = []
        do { _ = try await model.listArtifacts(taskID:id); XCTFail("disconnected read") } catch {}
        XCTAssertTrue(runtime.requests.isEmpty)
    }
    @MainActor func testSaveFailureDoesNotPublishConfirmationAndDownloadUsesPreviewVersion() async throws {
        let (model,runtime,_,_,root,id) = try fixture()
        defer { try? FileManager.default.removeItem(at:root) }
        let preview = try await model.loadArtifact(taskID:id,artifact:.init(path:"result.md",size:5))
        let destination = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".md")
        defer { try? FileManager.default.removeItem(at:destination) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        runtime.bytes = Data("newer".utf8)
        try model.downloadArtifactPreview(taskID:id,preview:preview,to:destination)
        XCTAssertEqual(try Data(contentsOf:destination),preview.bytes)
        runtime.bytes = preview.bytes
        try model.store.save(model.state)
        try FileManager.default.removeItem(at:model.store.url)
        try FileManager.default.createDirectory(at:model.store.url,withIntermediateDirectories:true)
        do { try await model.confirmArtifact(taskID:id,preview:preview); XCTFail("save failure accepted") } catch {}
        XCTAssertFalse(model.isArtifactConfirmed(taskID:id,preview:preview))
    }
    @MainActor func testDownloadParentReplacementCannotOverwriteEncryptedSnapshot() async throws {
        let (model,_,audit,_,root,id) = try fixture()
        let external = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:external); try? FileManager.default.removeItem(at:root) }
        try model.store.save(model.state)
        let originalSnapshot = try Data(contentsOf:model.store.url)
        let selected = external.appendingPathComponent("selected")
        let pinned = external.appendingPathComponent("original")
        try FileManager.default.createDirectory(at:selected,withIntermediateDirectories:true)
        let preview = try await model.loadArtifact(taskID:id,artifact:.init(path:"result.md",size:5))
        audit.beforeAppend = { record in
            guard record["kind"] as? String == "artifact.download.requested" else { return }
            try FileManager.default.moveItem(at:selected,to:pinned)
            try FileManager.default.createSymbolicLink(at:selected,withDestinationURL:root)
        }
        let destination = selected.appendingPathComponent(model.store.url.lastPathComponent)
        // Either pinning the original directory or rejecting the changed path is safe.
        do { try model.downloadArtifactPreview(taskID:id,preview:preview,to:destination) } catch {}
        XCTAssertEqual(try Data(contentsOf:model.store.url),originalSnapshot,"save-panel parent replacement must not retarget writes into encrypted storage")
        if FileManager.default.fileExists(atPath:pinned.appendingPathComponent(model.store.url.lastPathComponent).path) {
            XCTAssertEqual(try Data(contentsOf:pinned.appendingPathComponent(model.store.url.lastPathComponent)),preview.bytes)
        }
    }
    @MainActor func testDownloadRejectsProtectedDirectoryAndSymlinkParents() async throws {
        let (model,_,_,_,root,id) = try fixture()
        let external = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:external); try? FileManager.default.removeItem(at:root) }
        try model.store.save(model.state)
        try FileManager.default.createDirectory(at:external,withIntermediateDirectories:true)
        let alias = external.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:root)
        let preview = try await model.loadArtifact(taskID:id,artifact:.init(path:"result.md",size:5))
        for directory in [root,alias] {
            XCTAssertThrowsError(try model.downloadArtifactPreview(taskID:id,preview:preview,to:directory.appendingPathComponent("copy.md")))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("copy.md").path))
    }
    func testOldTaskWithoutReviewsDecodes() throws {
        let old = WorkbenchTask(instanceID:UUID(),title:"old")
        XCTAssertNil(try JSONDecoder().decode(WorkbenchTask.self,from:JSONEncoder().encode(old)).artifactReviews)
    }
}
