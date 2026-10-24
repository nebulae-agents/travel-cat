import Foundation
import CoreFoundation
import Darwin

private struct ArtifactReadBinding: Equatable {
    let revision: UUID
    let instanceID: UUID
    let sessionID: String?
    let threadID: String?
    let connectionGeneration: UUID?
}

@MainActor
extension AgentWorkbenchModel {
    func invalidateArtifactReads(_ id: UUID) {
        artifactReadRevisions[id] = UUID()
        artifactInventories.removeValue(forKey: id)
    }
    func invalidateAllArtifactReads() {
        for id in Set(artifactReadRevisions.keys).union(liveTasks) { invalidateArtifactReads(id) }
    }
    private func readableArtifactTask(_ id: UUID) throws -> WorkbenchTask {
        guard isStorageReady, let task = state.tasks.first(where: { $0.id == id }), liveTasks.contains(id),
              task.nativeState == nil || task.nativeState?.connection == .connected,
              !nativeDetaching.contains(id), !nativeRecovering.contains(id) else {
            throw WorkbenchFailure("此任务尚未连接，请先恢复会话，再读取制品。")
        }
        return task
    }
    private func artifactBinding(_ id: UUID) throws -> ArtifactReadBinding {
        let task = try readableArtifactTask(id)
        let revision = artifactReadRevisions[id] ?? UUID(); artifactReadRevisions[id] = revision
        return .init(revision: revision, instanceID: task.instanceID, sessionID: task.sessionID,
                     threadID: task.nativeState?.threadID, connectionGeneration: nativeConnectionGenerations[task.instanceID])
    }
    private func requireArtifactBinding(_ binding: ArtifactReadBinding, _ id: UUID) throws {
        guard try artifactBinding(id) == binding else { throw WorkbenchFailure("读取期间任务会话或本轮执行已变化，请刷新后重试。") }
    }
    private func artifactRecord(_ id: UUID, _ kind: String, fields: [String: Any] = [:]) throws {
        try nativeRecord(id, kind: "artifact." + kind, fields: fields)
    }
    func listArtifacts(taskID: UUID) async throws -> [WorkbenchArtifact] {
        let task = try readableArtifactTask(taskID), binding = try artifactBinding(taskID)
        guard artifactReadRequests.insert(taskID).inserted else { throw WorkbenchFailure("已有文件读取正在进行，请稍后重试。") }
        defer { artifactReadRequests.remove(taskID) }
        try artifactRecord(taskID, "list.requested")
        let result = try await client.request(task.nativeState == nil ? "artifact_changes" : "native_artifact_changes", ["taskId": taskID.uuidString], timeout: 15)
        try requireArtifactBinding(binding,taskID)
        guard let files = result["files"] as? [[String:Any]], files.count <= 200,
              let backendBinding = result["bindingId"] as? String, !backendBinding.isEmpty, backendBinding.utf8.count <= 128,
              let checked = result["checkedAt"] as? NSNumber, CFGetTypeID(checked) != CFBooleanGetTypeID(), checked.doubleValue.isFinite,
              let inventoryComplete = result["inventoryComplete"] as? Bool, let hashComplete = result["hashComplete"] as? Bool,
              let baselineInventory = result["baselineInventoryComplete"] as? Bool, let baselineHash = result["baselineHashComplete"] as? Bool else { throw WorkbenchFailure("文件列表或扫描口径无效。") }
        let execution = result["executionId"] as? String
        guard execution?.utf8.count ?? 0 <= 128 else { throw WorkbenchFailure("文件执行作用域无效。") }
        var seen = Set<String>()
        let parsed = try files.map { entry -> WorkbenchArtifact in
            guard let path = entry["path"] as? String, let value = entry["size"] as? NSNumber,
                  CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
                  value.doubleValue.rounded() == value.doubleValue, value.doubleValue >= 0,
                  value.doubleValue <= Double(1 << 50), seen.insert(path).inserted,
                  let change = entry["change"] as? String, ["new","modified","unchanged","unknown"].contains(change) else { throw WorkbenchFailure("文件列表含有无效条目。") }
            try WorkbenchArtifactLimits.validate(path: path)
            let sha = entry["sha256"] as? String, reason = entry["reason"] as? String
            guard (entry["sha256"] == nil || sha.map(WorkbenchArtifactLimits.validSHA) == true),
                  reason?.utf8.count ?? 0 <= 256, change == "unknown" || sha != nil else { throw WorkbenchFailure("文件 SHA 或变化口径无效。") }
            return .init(path:path,size:value.intValue,sha256:sha,change:change,reason:reason,bindingID:backendBinding,executionID:execution)
        }.sorted { $0.path < $1.path }
        let baseline = (result["baselineCapturedAt"] as? NSNumber).flatMap { $0.doubleValue.isFinite ? Date(timeIntervalSince1970:$0.doubleValue) : nil }
        artifactInventories[taskID] = .init(bindingID:backendBinding,executionID:execution,turnID:result["turnId"] as? String,
            baselineCapturedAt:baseline,checkedAt:Date(timeIntervalSince1970:checked.doubleValue),inventoryComplete:inventoryComplete,hashComplete:hashComplete,
            baselineInventoryComplete:baselineInventory,baselineHashComplete:baselineHash,reason:result["reason"] as? String,files:parsed)
        return parsed
    }
    func readArtifactBytes(taskID: UUID, path: String, expectedSize: Int?, expectedArtifact: WorkbenchArtifact? = nil) async throws -> Data {
        try WorkbenchArtifactLimits.validate(path: path)
        guard expectedSize == nil || (0...WorkbenchArtifactLimits.bytes).contains(expectedSize!) else { throw WorkbenchFailure("文件超过 4 MiB 限额。") }
        let task = try readableArtifactTask(taskID), binding = try artifactBinding(taskID)
        guard artifactReadRequests.insert(taskID).inserted else { throw WorkbenchFailure("已有文件读取正在进行，请稍后重试。") }
        defer { artifactReadRequests.remove(taskID) }
        try artifactRecord(taskID, "read.requested", fields:["path":path])
        var params: [String:Any] = ["taskId":taskID.uuidString,"path":path]
        if let backend = expectedArtifact?.bindingID { params["bindingId"] = backend; params["executionId"] = expectedArtifact?.executionID ?? NSNull() as Any }
        let result = try await client.request(task.nativeState == nil ? "export" : "native_export", params, timeout: 15)
        try requireArtifactBinding(binding,taskID)
        if let backend = expectedArtifact?.bindingID {
            guard result["bindingId"] as? String == backend, result["executionId"] as? String == expectedArtifact?.executionID else { throw WorkbenchFailure("文件列表属于先前会话或执行，请刷新。") }
        }
        guard let name = result["name"] as? String, name == path.split(separator:"/").last.map(String.init),
              let encoded = result["base64"] as? String, encoded.utf8.count <= ((WorkbenchArtifactLimits.bytes + 2) / 3) * 4,
              let data = Data(base64Encoded:encoded), data.base64EncodedString() == encoded,
              data.count <= WorkbenchArtifactLimits.bytes, expectedSize == nil || data.count == expectedSize else { throw WorkbenchFailure("文件内容无效、大小变化或超过 4 MiB，请刷新列表后重新预览。") }
        let sha = WorkbenchArtifactPreview.digest(data)
        if let expectedSHA = expectedArtifact?.sha256, sha != expectedSHA { throw WorkbenchFailure("文件内容已变化，请刷新列表后重新预览。") }
        try artifactRecord(taskID, "read.completed", fields:["path":path,"bytes":data.count,"sha256":sha])
        return data
    }
    func loadArtifact(taskID: UUID, artifact: WorkbenchArtifact) async throws -> WorkbenchArtifactPreview {
        guard artifact.readable else { throw WorkbenchFailure("此文件只提供元数据，超过限额或不是可安全读取的普通文件。") }
        let bytes = try await readArtifactBytes(taskID:taskID,path:artifact.path,expectedSize:artifact.size,expectedArtifact:artifact)
        return WorkbenchArtifactPreview(artifact:artifact,bytes:bytes)
    }
    func confirmArtifact(taskID: UUID, preview: WorkbenchArtifactPreview) async throws {
        try WorkbenchArtifactLimits.validate(preview)
        let binding = try artifactBinding(taskID)
        try artifactRecord(taskID, "confirm.requested", fields:["path":preview.artifact.path,"sha256":preview.sha256])
        let current = try await readArtifactBytes(taskID:taskID,path:preview.artifact.path,expectedSize:nil)
        try requireArtifactBinding(binding,taskID)
        guard WorkbenchArtifactPreview.digest(current) == preview.sha256 else { throw WorkbenchFailure("文件已变化，请读取新版本，再确认。") }
        var next = state
        guard let index = next.tasks.firstIndex(where: { $0.id == taskID }) else { throw WorkbenchFailure("任务已不存在。") }
        var reviews = next.tasks[index].artifactReviews ?? []
        if !reviews.contains(where: { $0.path == preview.artifact.path && $0.sha256 == preview.sha256 }) {
            reviews.append(.init(path:preview.artifact.path,sha256:preview.sha256,reviewedAt:Date()))
        }
        next.tasks[index].artifactReviews = reviews
        try artifactRecord(taskID, "confirm.verified", fields:["path":preview.artifact.path,"sha256":preview.sha256])
        try store.save(next); state = next
    }
    func isArtifactConfirmed(taskID: UUID, preview: WorkbenchArtifactPreview) -> Bool {
        state.tasks.first(where: { $0.id == taskID })?.artifactReviews?.contains(where: { $0.path == preview.artifact.path && $0.sha256 == preview.sha256 }) == true
    }
    func artifactHistory(taskID: UUID, path: String) -> [WorkbenchArtifactVersion] {
        (state.tasks.first(where: { $0.id == taskID })?.artifactVersions ?? []).filter { $0.path == path }.reversed()
    }
    func viewSavedArtifactVersion(taskID: UUID, version: WorkbenchArtifactVersion, present: (WorkbenchArtifactPreview) -> Void) throws {
        guard isStorageReady,
              let stored = artifactHistory(taskID:taskID,path:version.path).first(where: { $0.sha256 == version.sha256 }),
              let text = stored.text else { throw WorkbenchFailure("此历史正文已不在最近两次查看记录中，或只保存了元数据。") }
        let bytes = Data(text.utf8)
        let saved = WorkbenchArtifactPreview(artifact:.init(path:stored.path,size:bytes.count),bytes:bytes)
        try WorkbenchArtifactLimits.validate(saved)
        guard saved.sha256 == stored.sha256, bytes.count == stored.size else { throw WorkbenchFailure("历史正文校验失败，未替换当前预览。") }
        present(saved)
        // A successful re-open is a new actual view. Preserve the displayed bytes
        // if persistence fails, while propagating the failure to the UI notice.
        try rememberArtifactPreview(taskID:taskID,preview:saved)
    }
    func rememberArtifactPreview(taskID: UUID, preview: WorkbenchArtifactPreview) throws {
        // Called only after the UI actually presents the immutable bytes.
        try WorkbenchArtifactLimits.validate(preview)
        guard isStorageReady, store.keyData != nil, let index = state.tasks.firstIndex(where: { $0.id == taskID }) else { throw WorkbenchFailure("加密存储不可用，未保存已查看文件历史。") }
        var next = state, versions = state.tasks[index].artifactVersions ?? []
        let path = preview.artifact.path
        let paths = Set(versions.map(\.path))
        guard paths.contains(path) || paths.count < 16 else { artifactHistoryNotice[taskID] = "每个任务最多保存 16 个文件路径的历史；新预览未保存，不会清除已有数据。"; return }
        versions.removeAll { $0.path == path && $0.sha256 == preview.sha256 }
        // Roll only this path's two viewed versions. Confirmation SHA records remain independent.
        let samePath = versions.filter { $0.path == path }
        if samePath.count >= 2, let oldest = samePath.first { versions.removeAll { $0.id == oldest.id } }
        let otherTasks = next.tasks.enumerated().filter { $0.offset != index }.flatMap { $0.element.artifactVersions ?? [] }
        guard otherTasks.count + versions.count < 128 else { artifactHistoryNotice[taskID] = "文件历史达到 128 条元数据限额；新预览未保存，不会清除已有数据。"; return }
        var text = WorkbenchArtifactText.savedText(preview)
        var reason: String?
        if text == nil { reason = preview.bytes.count > WorkbenchArtifactText.limit ? "正文超过 256 KiB，只保存 SHA 和大小。" : "二进制、图片、PDF 或非 UTF-8 文本，只保存 SHA 和大小。" }
        let total = (otherTasks + versions).compactMap(\.text).reduce(0) { $0 + $1.utf8.count }
        if let value = text, total + value.utf8.count > 2 * 1024 * 1024 { text = nil; reason = "已保存正文达到 2 MiB 限额，本版本只保存 SHA 和大小；未清除其它历史。" }
        versions.append(.init(path:path,sha256:preview.sha256,size:preview.bytes.count,viewedAt:Date(),text:text,reason:reason))
        next.tasks[index].artifactVersions = versions
        try store.save(next); state = next
        artifactHistoryNotice[taskID] = reason
    }
    func downloadArtifactPreview(taskID: UUID, preview: WorkbenchArtifactPreview, to destination: URL) throws {
        guard state.tasks.contains(where: { $0.id == taskID }), isStorageReady else { throw WorkbenchFailure("任务已不存在或存储不可用。") }
        try WorkbenchArtifactLimits.validate(preview)
        guard destination.isFileURL else { throw WorkbenchFailure("请选择本机保存位置。") }
        let output = try ArtifactDownloadDestination(destination:destination, protectedRoot:store.root)
        try artifactRecord(taskID, "download.requested", fields:["path":preview.artifact.path,"sha256":preview.sha256,"bytes":preview.bytes.count])
        do { try output.write(preview.bytes) }
        catch { try? artifactRecord(taskID,"download.failed",fields:["path":preview.artifact.path]); throw error }
        do { try artifactRecord(taskID,"download.completed",fields:["path":preview.artifact.path,"sha256":preview.sha256,"bytes":preview.bytes.count]) }
        catch { throw WorkbenchFailure("文件已保存，但完成审计未能记录，请核对保存位置。") }
    }
}

// All writes and cleanup use pinned directory descriptors. No caller-controlled
// pathname is followed again for the temporary file or the atomic replacement.
private final class ArtifactDownloadDestination {
    private let parent: Int32
    private let protected: Int32?
    private let parentURL: URL
    private let name: String

    init(destination: URL, protectedRoot: URL) throws {
        let target = destination.standardizedFileURL
        let filename = target.lastPathComponent
        guard target.isFileURL, !filename.isEmpty, ![".", "..", "/"].contains(filename),
              !target.path.contains("\0"), !filename.contains("/"),
              !filename.unicodeScalars.contains(where:{ $0.value < 32 }) else { throw Self.failure() }
        let directoryURL = target.deletingLastPathComponent()
        guard let directory = try Self.openDirectory(directoryURL) else { throw Self.failure() }
        do {
            let storage = try Self.openDirectory(protectedRoot,allowMissing:true)
            do {
                try Self.requireOutsideStorage(directory,protected:storage)
                try Self.validateTarget(directory:directory,name:filename)
            } catch { if let storage { close(storage) }; throw error }
            parent = directory; protected = storage; parentURL = directoryURL; name = filename
        } catch { close(directory); throw error }
    }
    deinit { close(parent); if let protected { close(protected) } }

    func write(_ bytes: Data) throws {
        try validatePinnedParent()
        let temporary = ".travelcat-download-\(UUID().uuidString).tmp"
        let file = openat(parent,temporary,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,0o600)
        guard file >= 0 else { throw Self.failure() }
        defer { close(file); unlinkat(parent,temporary,0) }
        var info = stat()
        guard fstat(file,&info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw Self.failure() }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(file,buffer.baseAddress!.advanced(by:offset),buffer.count-offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Self.failure() }
                offset += count
            }
        }
        guard fchmod(file,0o600) == 0, fsync(file) == 0 else { throw Self.failure() }
        try validatePinnedParent()
        try Self.validateTarget(directory:parent,name:name)
        guard renameat(parent,temporary,parent,name) == 0 else { throw Self.failure() }
        // The rename is the commit point; do not report "not saved" afterwards.
        guard fsync(parent) == 0 else { throw WorkbenchFailure("文件已保存，但目录同步未确认，请核对保存位置。") }
    }
    private func validatePinnedParent() throws {
        guard let current = try Self.openDirectory(parentURL) else { throw Self.failure() }
        defer { close(current) }
        guard try Self.sameDirectory(parent,current) else { throw Self.failure() }
        try Self.requireOutsideStorage(parent,protected:protected)
    }
    private static func validateTarget(directory: Int32, name: String) throws {
        var info = stat()
        guard fstatat(directory,name,&info,AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw failure()
        }
        guard info.st_mode & S_IFMT == S_IFREG else { throw failure() }
    }
    private static func sameDirectory(_ first: Int32, _ second: Int32) throws -> Bool {
        var lhs = stat(), rhs = stat()
        guard fstat(first,&lhs) == 0, fstat(second,&rhs) == 0 else { throw failure() }
        return lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }
    private static func requireOutsideStorage(_ directory: Int32, protected: Int32?) throws {
        guard let protected else { return }
        var ancestor = dup(directory)
        guard ancestor >= 0 else { throw failure() }
        defer { close(ancestor) }
        // Compare actual filesystem identities, including aliases and case-insensitive paths.
        for _ in 0..<512 {
            guard try !sameDirectory(ancestor,protected) else { throw WorkbenchFailure("不能覆盖 Agent 的数据与审计存储。") }
            let next = openat(ancestor,"..",O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw failure() }
            do {
                if try sameDirectory(ancestor,next) { close(next); return }
            } catch { close(next); throw error }
            close(ancestor); ancestor = next
        }
        throw failure()
    }
    private static func openDirectory(_ url: URL, allowMissing: Bool = false) throws -> Int32? {
        guard url.isFileURL, !url.path.contains("\0") else { throw failure() }
        var path = url.standardizedFileURL.path
        // These two macOS system aliases are fixed; user-controlled symlinks remain denied.
        for alias in ["/var", "/tmp"] where path == alias || path.hasPrefix(alias + "/") { path = "/private" + path }
        var directory = Darwin.open("/",O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw failure() }
        do {
            for part in path.split(separator:"/").map(String.init) {
                let next = openat(directory,part,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else {
                    if allowMissing && errno == ENOENT { close(directory); return nil }
                    throw failure()
                }
                close(directory); directory = next
            }
            return directory
        } catch { close(directory); throw error }
    }
    private static func failure() -> WorkbenchFailure { WorkbenchFailure("保存位置已变化或无法安全写入，请重新选择文件位置。") }
}
