import Foundation
import CoreFoundation
import Darwin

@MainActor
extension AgentWorkbenchModel {
    private func readableArtifactTask(_ id: UUID) throws -> WorkbenchTask {
        guard !loadFailed, let task = state.tasks.first(where: { $0.id == id }), liveTasks.contains(id),
              task.nativeState == nil || task.nativeState?.connection == .connected,
              !nativeDetaching.contains(id), !nativeRecovering.contains(id) else {
            throw WorkbenchFailure("此任务尚未连接，请先恢复会话，再读取制品。")
        }
        return task
    }
    private func artifactRecord(_ id: UUID, _ kind: String, fields: [String: Any] = [:]) throws {
        try nativeRecord(id, kind: "artifact." + kind, fields: fields)
    }
    func listArtifacts(taskID: UUID) async throws -> [WorkbenchArtifact] {
        let task = try readableArtifactTask(taskID)
        try artifactRecord(taskID, "list.requested")
        let result = try await client.request(task.nativeState == nil ? "artifacts" : "native_artifacts", ["taskId": taskID.uuidString])
        _ = try readableArtifactTask(taskID)
        guard let files = result["files"] as? [[String:Any]], files.count <= 200 else { throw WorkbenchFailure("文件列表无效或超出数量限制。") }
        var seen = Set<String>()
        return try files.map { entry in
            guard let path = entry["path"] as? String, let value = entry["size"] as? NSNumber,
                  CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
                  value.doubleValue.rounded() == value.doubleValue, value.doubleValue >= 0,
                  value.doubleValue <= Double(WorkbenchArtifactLimits.bytes), seen.insert(path).inserted else {
                throw WorkbenchFailure("文件列表含有无效条目。")
            }
            try WorkbenchArtifactLimits.validate(path: path)
            return WorkbenchArtifact(path:path,size:value.intValue)
        }.sorted { $0.path < $1.path }
    }
    func readArtifactBytes(taskID: UUID, path: String, expectedSize: Int?) async throws -> Data {
        try WorkbenchArtifactLimits.validate(path: path)
        guard expectedSize == nil || (0...WorkbenchArtifactLimits.bytes).contains(expectedSize!) else { throw WorkbenchFailure("文件超过 4 MiB 限额。") }
        let task = try readableArtifactTask(taskID)
        try artifactRecord(taskID, "read.requested", fields:["path":path])
        let result = try await client.request(task.nativeState == nil ? "export" : "native_export", ["taskId":taskID.uuidString,"path":path])
        _ = try readableArtifactTask(taskID)
        guard let name = result["name"] as? String, name == path.split(separator:"/").last.map(String.init),
              let encoded = result["base64"] as? String, encoded.utf8.count <= ((WorkbenchArtifactLimits.bytes + 2) / 3) * 4,
              let data = Data(base64Encoded:encoded), data.base64EncodedString() == encoded,
              data.count <= WorkbenchArtifactLimits.bytes, expectedSize == nil || data.count == expectedSize else {
            throw WorkbenchFailure("文件内容无效、大小变化或超过 4 MiB，请刷新列表后重新预览。")
        }
        try artifactRecord(taskID, "read.completed", fields:["path":path,"bytes":data.count,"sha256":WorkbenchArtifactPreview.digest(data)])
        return data
    }
    func loadArtifact(taskID: UUID, artifact: WorkbenchArtifact) async throws -> WorkbenchArtifactPreview {
        let bytes = try await readArtifactBytes(taskID:taskID,path:artifact.path,expectedSize:artifact.size)
        return WorkbenchArtifactPreview(artifact:artifact,bytes:bytes)
    }
    func confirmArtifact(taskID: UUID, preview: WorkbenchArtifactPreview) async throws {
        try WorkbenchArtifactLimits.validate(preview)
        _ = try readableArtifactTask(taskID)
        try artifactRecord(taskID, "confirm.requested", fields:["path":preview.artifact.path,"sha256":preview.sha256])
        let current = try await readArtifactBytes(taskID:taskID,path:preview.artifact.path,expectedSize:nil)
        guard WorkbenchArtifactPreview.digest(current) == preview.sha256 else { throw WorkbenchFailure("文件已变化，请刷新并重新预览，再确认新版本。") }
        var next = state
        guard let index = next.tasks.firstIndex(where: { $0.id == taskID }) else { throw WorkbenchFailure("任务已不存在。") }
        var reviews = next.tasks[index].artifactReviews ?? []
        reviews.removeAll { $0.path == preview.artifact.path }
        reviews.append(.init(path:preview.artifact.path,sha256:preview.sha256,reviewedAt:Date()))
        next.tasks[index].artifactReviews = reviews
        try artifactRecord(taskID, "confirm.verified", fields:["path":preview.artifact.path,"sha256":preview.sha256])
        try store.save(next)
        state = next
    }
    func isArtifactConfirmed(taskID: UUID, preview: WorkbenchArtifactPreview) -> Bool {
        state.tasks.first(where: { $0.id == taskID })?.artifactReviews?.contains(where: { $0.path == preview.artifact.path && $0.sha256 == preview.sha256 }) == true
    }
    func downloadArtifactPreview(taskID: UUID, preview: WorkbenchArtifactPreview, to destination: URL) throws {
        guard state.tasks.contains(where: { $0.id == taskID }), !loadFailed else { throw WorkbenchFailure("任务已不存在或存储不可用。") }
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
