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
        if method.hasSuffix("artifact_changes") { return ["bindingId":"fixture","checkedAt":Date().timeIntervalSince1970,"inventoryComplete":true,"hashComplete":true,"baselineInventoryComplete":false,"baselineHashComplete":false,"files":[["path":"result.md","size":bytes.count,"sha256":WorkbenchArtifactPreview.digest(bytes),"change":"unknown"]]] }
        return ["name":"result.md","base64":bytes.base64EncodedString(),"bindingId":"fixture"]
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
            XCTAssertEqual(runtime.requests,native ? ["native_artifact_changes","native_export"] : ["artifact_changes","export"])
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
    @MainActor func testReadRejectsChangedBindingEvenWhenTaskRemainsLive() async throws {
        for native in [false,true] {
            let (model,runtime,_,_,root,id) = try fixture(native:native)
            defer { try? FileManager.default.removeItem(at:root) }
            model.state.tasks[0].sessionID = "old-session"
            runtime.beforeRead = { model.state.tasks[0].sessionID = "new-session" }
            do { _ = try await model.loadArtifact(taskID:id,artifact:.init(path:"result.md",size:5)); XCTFail("stale task binding accepted") } catch {}
        }
    }
    @MainActor func testEveryConfirmationSHAIsRetainedAcrossVersionChanges() async throws {
        let (model,runtime,_,_,root,id) = try fixture()
        defer { try? FileManager.default.removeItem(at:root) }
        let old = try await model.loadArtifact(taskID:id,artifact:.init(path:"result.md",size:5))
        try await model.confirmArtifact(taskID:id,preview:old)
        runtime.bytes = Data("newer".utf8)
        let new = try await model.loadArtifact(taskID:id,artifact:.init(path:"result.md",size:5))
        try await model.confirmArtifact(taskID:id,preview:new)
        XCTAssertTrue(model.isArtifactConfirmed(taskID:id,preview:old))
        XCTAssertTrue(model.isArtifactConfirmed(taskID:id,preview:new))
    }
    @MainActor func testViewedHistoryIsEncryptedDistinctAndRestoresForComparison() async throws {
        let (model,runtime,_,credentials,root,id) = try fixture()
        defer { try? FileManager.default.removeItem(at:root) }
        runtime.bytes = Data("旧内容\t一\r\n二".utf8)
        let old = try await model.loadArtifact(taskID:id,artifact:.init(path:"result.md",size:runtime.bytes.count))
        XCTAssertNil(model.state.tasks[0].artifactVersions)
        try model.rememberArtifactPreview(taskID:id,preview:old)
        try model.rememberArtifactPreview(taskID:id,preview:old)
        runtime.bytes = Data("新内容\t一\n二".utf8)
        let new = try await model.loadArtifact(taskID:id,artifact:.init(path:"result.md",size:runtime.bytes.count))
        try model.rememberArtifactPreview(taskID:id,preview:new)
        let restored = AgentWorkbenchModel(root:root,credentials:credentials,client:ArtifactRuntime(),auditStore:ArtifactAudit())
        XCTAssertEqual(restored.state.tasks[0].artifactVersions?.count,2)
        XCTAssertEqual(restored.artifactHistory(taskID:id,path:"result.md").last?.text,"旧内容\t一\r\n二")
        let encoded = try Data(contentsOf:model.store.url)
        XCTAssertNil(encoded.range(of:old.bytes))
        XCTAssertTrue(WorkbenchArtifactComparison.compare(old:restored.artifactHistory(taskID:id,path:"result.md").last,current:new).text.contains("-旧内容"))
    }
    @MainActor func testHistoryCapsStopNewBodiesWithoutRemovingConfirmedMetadata() async throws {
        let (model,_,_,_,root,id) = try fixture()
        defer { try? FileManager.default.removeItem(at:root) }
        let confirmed=WorkbenchArtifactPreview(artifact:.init(path:"result.md",size:5),bytes:Data("first".utf8))
        try await model.confirmArtifact(taskID:id,preview:confirmed)
        for n in 0..<9 {
            let body=Data((String(n)+String(repeating:"a",count:250*1024)).utf8)
            let value=WorkbenchArtifactPreview(artifact:.init(path:"file\(n).txt",size:body.count),bytes:body)
            try model.rememberArtifactPreview(taskID:id,preview:value)
        }
        XCTAssertLessThanOrEqual(model.state.tasks[0].artifactVersions?.compactMap(\.text).reduce(0) { $0+$1.utf8.count } ?? 0,2*1024*1024)
        XCTAssertNotNil(model.artifactHistoryNotice[id])
        XCTAssertTrue(model.isArtifactConfirmed(taskID:id,preview:confirmed))
        XCTAssertEqual(model.state.tasks[0].artifactVersions?.count,9)
        XCTAssertNil(model.artifactHistory(taskID:id,path:"file8.txt").first?.text)
    }
    func testComparisonRequiresActualTextAndReportsLineEndings() {
        let current=WorkbenchArtifactPreview(artifact:.init(path:"r.html",size:3),bytes:Data("a\nb".utf8))
        let old=WorkbenchArtifactVersion(path:"r.html",sha256:String(repeating:"a",count:64),size:4,viewedAt:Date(),text:"a\r\nb",reason:nil)
        XCTAssertEqual(WorkbenchArtifactComparison.compare(old:old,current:current).kind,.lineEndings)
        XCTAssertEqual(WorkbenchArtifactComparison.compare(old:nil,current:current).kind,.metadata)
        let binary=WorkbenchArtifactPreview(artifact:.init(path:"b.bin",size:2),bytes:Data([0,1]))
        XCTAssertEqual(WorkbenchArtifactComparison.compare(old:old,current:binary).kind,.metadata)
        XCTAssertNil(WorkbenchArtifactText.decode(Data([0xc0,0x80])))
        XCTAssertNotNil(WorkbenchArtifactText.decode(Data("中文\t\r\n<html>".utf8)))
    }
    func testComparisonBoundsWorkAndOutput() {
        let old=WorkbenchArtifactVersion(path:"r.txt",sha256:String(repeating:"a",count:64),size:6000,viewedAt:Date(),text:String(repeating:"a\n",count:2001),reason:nil)
        let bytes=Data(String(repeating:"b\n",count:2001).utf8)
        let current=WorkbenchArtifactPreview(artifact:.init(path:"r.txt",size:bytes.count),bytes:bytes)
        XCTAssertEqual(WorkbenchArtifactComparison.compare(old:old,current:current).kind,.limited)
    }

    func testUnicodeNormalizationChangeIsNotMisreportedAsOnlyLineEndings() {
        let composed=Data("é".utf8), decomposed=Data("e\u{301}".utf8)
        let old=WorkbenchArtifactVersion(path:"r.txt",sha256:WorkbenchArtifactPreview.digest(composed),size:composed.count,viewedAt:Date(),text:String(decoding:composed,as:UTF8.self),reason:nil)
        let current=WorkbenchArtifactPreview(artifact:.init(path:"r.txt",size:decomposed.count),bytes:decomposed)
        let comparison=WorkbenchArtifactComparison.compare(old:old,current:current)
        XCTAssertEqual(comparison.kind,.text)
        XCTAssertTrue(comparison.text.contains("-é"))
        XCTAssertTrue(comparison.text.contains("+e\u{301}"))
    }
    @MainActor func testRollingViewedBodiesRetainsAllConfirmedSHAsAndOldDownload() async throws {
        let (model,runtime,_,_,root,id)=try fixture()
        defer { try? FileManager.default.removeItem(at:root) }
        let destination=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:destination) }
        var first: WorkbenchArtifactPreview?
        for value in ["first","newer","third"] {
            runtime.bytes=Data(value.utf8)
            let preview=try await model.loadArtifact(taskID:id,artifact:.init(path:"result.md",size:5))
            if first == nil { first=preview }
            try model.rememberArtifactPreview(taskID:id,preview:preview)
            try await model.confirmArtifact(taskID:id,preview:preview)
        }
        XCTAssertEqual(model.artifactHistory(taskID:id,path:"result.md").count,2)
        XCTAssertEqual(model.state.tasks[0].artifactReviews?.count,3)
        XCTAssertTrue(model.isArtifactConfirmed(taskID:id,preview:try XCTUnwrap(first)))
        try model.downloadArtifactPreview(taskID:id,preview:try XCTUnwrap(first),to:destination)
        XCTAssertEqual(try Data(contentsOf:destination),Data("first".utf8))
    }

    func testPreviewRemainsOldWhenFreshInventoryChangesOrCannotVerifySHA() {
        let old=WorkbenchArtifactPreview(artifact:.init(path:"r.txt",size:3),bytes:Data("old".utf8))
        let new=WorkbenchArtifact(path:"r.txt",size:3,sha256:WorkbenchArtifactPreview.digest(Data("new".utf8)))
        XCTAssertEqual(old.versionStatus(current:new),.old)
        XCTAssertEqual(old.versionStatus(current:.init(path:"r.txt",size:3)),.unverified)
        XCTAssertEqual(old.versionStatus(current:nil),.unverified)
        XCTAssertEqual(old.bytes,Data("old".utf8))
    }

    @MainActor func testMetadataAndPathCapsPreserveExistingDataAndPlaintextStoreRefusesHistory() throws {
        let (model,_,_,_,root,id)=try fixture()
        defer { try? FileManager.default.removeItem(at:root) }
        let preview=WorkbenchArtifactPreview(artifact:.init(path:"extra.txt",size:3),bytes:Data("new".utf8))
        for _ in 0..<4 {
            var task=WorkbenchTask(instanceID:UUID(),title:"history")
            task.artifactVersions=(0..<32).map { n in .init(path:"file\(n/2).txt",sha256:String(repeating:n%2 == 0 ? "a" : "b",count:64),size:0,viewedAt:Date(),text:nil,reason:"metadata") }
            model.state.tasks.append(task)
        }
        try model.rememberArtifactPreview(taskID:id,preview:preview)
        XCTAssertNil(model.state.tasks[0].artifactVersions)
        XCTAssertTrue(model.artifactHistoryNotice[id]?.contains("128") == true)
        XCTAssertEqual(model.state.tasks.dropFirst().flatMap { $0.artifactVersions ?? [] }.count,128)
        model.state.tasks.removeSubrange(1...)
        model.state.tasks[0].artifactVersions=(0..<16).map { n in .init(path:"file\(n).txt",sha256:String(repeating:"a",count:64),size:0,viewedAt:Date(),text:nil,reason:"metadata") }
        try model.rememberArtifactPreview(taskID:id,preview:preview)
        XCTAssertEqual(model.state.tasks[0].artifactVersions?.count,16)
        XCTAssertTrue(model.artifactHistoryNotice[id]?.contains("16") == true)
        let plain=WorkbenchStore(root:root.appendingPathComponent("plain"))
        XCTAssertThrowsError(try plain.save(model.state))
        XCTAssertFalse(FileManager.default.fileExists(atPath:plain.url.path))
    }
    @MainActor func testBinaryAndPDFHistorySaveMetadataOnly() throws {
        let (model,_,_,_,root,id)=try fixture()
        defer { try? FileManager.default.removeItem(at:root) }
        for (path,bytes) in [("file.bin",Data([0,1,255])),("file.pdf",Data("%PDF-plain".utf8))] {
            try model.rememberArtifactPreview(taskID:id,preview:.init(artifact:.init(path:path,size:bytes.count),bytes:bytes))
            let version=try XCTUnwrap(model.artifactHistory(taskID:id,path:path).first)
            XCTAssertNil(version.text);XCTAssertNotNil(version.reason)
        }
    }
    func testComparisonRefusesDifferentPaths() {
        let old=WorkbenchArtifactVersion(path:"other.txt",sha256:String(repeating:"a",count:64),size:3,viewedAt:Date(),text:"old",reason:nil)
        let current=WorkbenchArtifactPreview(artifact:.init(path:"current.txt",size:3),bytes:Data("new".utf8))
        XCTAssertEqual(WorkbenchArtifactComparison.compare(old:old,current:current).kind,.metadata)
    }

    func testComparisonOutputCapIncludesLineEndingExplanation() {
        let lhs="\r"+String(repeating:"a",count:131_000), rhs="\r"+String(repeating:"b",count:131_000)
        let before=Data(lhs.utf8), bytes=Data(rhs.utf8)
        let old=WorkbenchArtifactVersion(path:"r.txt",sha256:WorkbenchArtifactPreview.digest(before),size:before.count,viewedAt:Date(),text:lhs,reason:nil)
        let current=WorkbenchArtifactPreview(artifact:.init(path:"r.txt",size:bytes.count),bytes:bytes)
        XCTAssertLessThanOrEqual(WorkbenchArtifactComparison.compare(old:old,current:current).text.utf8.count,256*1024)
    }

    @MainActor func testReopeningSavedTextMakesItRecentBeforeNextDistinctVersion() async throws {
        let (model,runtime,_,_,root,id)=try fixture()
        defer { try? FileManager.default.removeItem(at:root) }
        var first:WorkbenchArtifactVersion?
        for value in ["first","newer"] {
            runtime.bytes=Data(value.utf8)
            let preview=try await model.loadArtifact(taskID:id,artifact:.init(path:"result.md",size:5))
            try model.rememberArtifactPreview(taskID:id,preview:preview)
            try await model.confirmArtifact(taskID:id,preview:preview)
            if first == nil { first=model.artifactHistory(taskID:id,path:"result.md").first }
        }
        let old=try XCTUnwrap(first)
        var displayed:WorkbenchArtifactPreview?
        try model.viewSavedArtifactVersion(taskID:id,version:old) { displayed=$0 }
        XCTAssertEqual(displayed?.bytes,Data("first".utf8))
        XCTAssertEqual(model.artifactHistory(taskID:id,path:"result.md").first?.sha256,old.sha256)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(model.artifactHistory(taskID:id,path:"result.md").first?.viewedAt),old.viewedAt)
        runtime.bytes=Data("third".utf8)
        let latest=try await model.loadArtifact(taskID:id,artifact:.init(path:"result.md",size:5))
        try model.rememberArtifactPreview(taskID:id,preview:latest)
        try await model.confirmArtifact(taskID:id,preview:latest)
        XCTAssertEqual(model.artifactHistory(taskID:id,path:"result.md").compactMap(\.text),["third","first"])
        XCTAssertEqual(model.state.tasks[0].artifactReviews?.count,3)
    }
    @MainActor func testReopenedTextRemainsPresentedWhenHistorySaveFails() throws {
        let (model,_,_,_,root,id)=try fixture()
        defer { try? FileManager.default.removeItem(at:root) }
        let preview=WorkbenchArtifactPreview(artifact:.init(path:"result.md",size:5),bytes:Data("first".utf8))
        try model.rememberArtifactPreview(taskID:id,preview:preview)
        let version=try XCTUnwrap(model.artifactHistory(taskID:id,path:"result.md").first)
        let blocked=root.appendingPathComponent("blocked");try Data("occupied".utf8).write(to:blocked)
        model.store=WorkbenchStore(root:blocked,keyData:model.store.keyData)
        var displayed:WorkbenchArtifactPreview?
        XCTAssertThrowsError(try model.viewSavedArtifactVersion(taskID:id,version:version) { displayed=$0 })
        XCTAssertEqual(displayed?.bytes,preview.bytes)
        XCTAssertEqual(model.artifactHistory(taskID:id,path:"result.md"),[version])
    }

}
