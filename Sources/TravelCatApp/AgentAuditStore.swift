import Foundation
import CryptoKit
import Darwin

struct AgentAuditInventory { let records: Int; let bytes: Int; let retiredRecords: Int }
struct AgentAuditRetentionPreview { let removableCount: Int; let head: String }
protocol AgentAuditStoring {
    func append(record: [String: Any]) throws
    func records(taskID: UUID) throws -> [[String: Any]]
    func inventory() throws -> AgentAuditInventory
    func retentionPreview(before: Date) throws -> AgentAuditRetentionPreview
    func prune(before: Date, expectedHead: String) throws -> Int
    func exportData(taskID: UUID?, includeContents: Bool) throws -> Data
}
extension AgentAuditStoring {
    func inventory() throws -> AgentAuditInventory { throw WorkbenchFailure("此存储不支持生命周期管理。") }
    func retentionPreview(before: Date) throws -> AgentAuditRetentionPreview { throw WorkbenchFailure("此存储不支持保留管理。") }
    func prune(before: Date, expectedHead: String) throws -> Int { throw WorkbenchFailure("此存储不支持保留管理。") }
    func exportData(taskID: UUID?, includeContents: Bool) throws -> Data { throw WorkbenchFailure("此存储不支持导出。") }
}

/// Content is encrypted before touching disk. A chain detects changes on verification,
/// but is not a defense against a host administrator controlling both journal and key.
final class AgentAuditStore: AgentAuditStoring {
    private let root: URL
    private let key: SymmetricKey
    private let lock = NSLock()
    private let maximumBytes: Int
    private let maximumRecords: Int
    private struct Entry: Codable {
        let version: Int
        let sequence: Int
        let previous: String
        let payload: Data
    }
    private struct Checkpoint: Codable {
        let version: Int
        let throughSequence: Int
        let throughHash: String
        let removedCount: Int
        let cutoff: Date
        let date: Date
        let previousCheckpointHash: String
    }
    private struct Verified {
        var records: [[String: Any]] = []
        var lastHash = "genesis"
        var bytes = 0
        var baseSequence = 0
        var hashes: [String] = []
        var checkpoint: Checkpoint?
    }

    init(root: URL, keyData: Data, recordLimit: Int = 4096, byteLimit: Int = 64 * 1024 * 1024) throws {
        guard recordLimit > 32, byteLimit > 512 * 1024 else { throw WorkbenchFailure("审计容量配置无效。") }
        maximumRecords = recordLimit; maximumBytes = byteLimit
        guard keyData.count == 32 else { throw WorkbenchFailure("审计密钥无效，已停止受控调用。") }
        self.root = root; self.key = SymmetricKey(data: keyData)
        if FileManager.default.fileExists(atPath: root.path) {
            guard try root.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]).isSymbolicLink != true else {
                throw WorkbenchFailure("审计目录不能是符号链接。")
            }
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        _ = try verify()
        try cleanupRetired()
    }

    @MainActor
    static func open(root: URL, credentials: any AsyncTravelServiceCredentialStoring) async throws -> AgentAuditStore {
        let id = "audit-journal-v1"
        let encoded = try await credentials.read(id: id)
        try Task.checkCancellation()
        let data: Data
        if let encoded {
            guard let decoded = Data(base64Encoded: encoded), decoded.count == 32 else { throw WorkbenchFailure("审计密钥无效，原密钥未替换。") }
            data = decoded
        } else {
            let existing: [URL]
            do { existing = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { existing = [] }
            catch { throw WorkbenchFailure("审计目录无法检查，密钥未变更；调用已阻止。") }
            guard existing.isEmpty else { throw WorkbenchFailure("审计密钥缺失，原记录未覆盖，调用已阻止。") }
            try Task.checkCancellation()
            data = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            try await credentials.save(data.base64EncodedString(), id: id)
            try Task.checkCancellation()
            guard try await credentials.read(id: id) == data.base64EncodedString() else { throw WorkbenchFailure("审计密钥保存未确认，禁止创建日志。") }
            try Task.checkCancellation()
        }
        return try AgentAuditStore(root: root, keyData: data)
    }

    @MainActor
    static func open(root: URL, credentials: any TravelServiceCredentialStoring) throws -> AgentAuditStore {
        let id = "audit-journal-v1"
        let data: Data
        if let encoded = try credentials.read(id: id) {
            guard let decoded = Data(base64Encoded: encoded), decoded.count == 32 else { throw WorkbenchFailure("审计密钥无效，原密钥未替换。") }
            data = decoded
        } else {
            let existing: [URL]
            do { existing = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { existing = [] }
            catch { throw WorkbenchFailure("审计目录无法检查，密钥未变更；调用已阻止。") }
            guard existing.isEmpty else { throw WorkbenchFailure("审计密钥缺失，原记录未覆盖，调用已阻止。") }
            data = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            try credentials.save(data.base64EncodedString(), id: id)
            guard try credentials.read(id: id) == data.base64EncodedString() else { throw WorkbenchFailure("审计密钥保存未确认，禁止创建日志。") }
        }
        return try AgentAuditStore(root: root, keyData: data)
    }

    func append(record: [String: Any]) throws {
        lock.lock(); defer { lock.unlock() }
        guard let eventID = record["eventId"] as? String, UUID(uuidString: eventID) != nil,
              let taskID = record["taskId"] as? String, UUID(uuidString: taskID) != nil,
              record["kind"] is String else { throw WorkbenchFailure("审计事件格式无效，调用已阻止。") }
        let payload = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes])
        guard payload.count <= 2 * 1024 * 1024 else { throw WorkbenchFailure("审计单条记录超过 2 MiB，调用已阻止。") }
        let journal = try verify()
        let management = ["audit.export", "policy.retention"].contains(record["kind"] as? String ?? "")
        guard journal.records.count < maximumRecords - (management ? 0 : 32),
              !journal.records.contains(where: { ($0["eventId"] as? String) == eventID }) else {
            throw WorkbenchFailure("审计事件重复或达到容量上限，调用已阻止。")
        }
        let entry = Entry(version: 1, sequence: journal.baseSequence + journal.records.count + 1, previous: journal.lastHash, payload: payload)
        let sealed = try AES.GCM.seal(JSONEncoder().encode(entry), using: key)
        guard let bytes = sealed.combined, journal.bytes + bytes.count <= maximumBytes - (management ? 0 : 512 * 1024) else {
            throw WorkbenchFailure("审计存储达到 64 MiB 上限，调用已阻止。")
        }
        let temporary = root.appendingPathComponent(".pending-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw WorkbenchFailure("审计存储不可写，调用已阻止。")
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        do { try handle.write(contentsOf: bytes); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        let destination = root.appendingPathComponent(String(format: "%020d.event", entry.sequence))
        try FileManager.default.moveItem(at: temporary, to: destination)
        let directory = Darwin.open(root.path, O_RDONLY)
        guard directory >= 0 else { throw WorkbenchFailure("无法确认审计持久化，调用已阻止。") }
        defer { Darwin.close(directory) }
        guard fsync(directory) == 0 else { throw WorkbenchFailure("无法确认审计持久化，调用已阻止。") }
    }

    func records(taskID: UUID) throws -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return try verify().records.filter { ($0["taskId"] as? String).flatMap(UUID.init(uuidString:)) == taskID }
    }

    private func verify() throws -> Verified {
        var result = Verified()
        if let checkpoint = try readCheckpoint() {
            result.checkpoint = checkpoint
            result.baseSequence = checkpoint.throughSequence
            result.lastHash = checkpoint.throughHash
        }
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            .filter { !$0.lastPathComponent.hasPrefix(".pending-") && $0.lastPathComponent != "retention.sealed" && !(sequence($0).map { $0 <= result.baseSequence } ?? false) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard files.count <= maximumRecords else { throw WorkbenchFailure("审计记录超过上限。") }
        do {
            var ids: Set<String> = []
            for (index, file) in files.enumerated() {
                let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard file.lastPathComponent == String(format: "%020d.event", result.baseSequence + index + 1), attributes.isRegularFile == true,
                      attributes.isSymbolicLink != true, let size = attributes.fileSize, size <= 3 * 1024 * 1024,
                      result.bytes + size <= maximumBytes else { throw WorkbenchFailure("invalid audit") }
                let bytes = try Data(contentsOf: file)
                let entry = try JSONDecoder().decode(Entry.self, from: AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: key))
                guard entry.version == 1, entry.sequence == result.baseSequence + index + 1, entry.previous == result.lastHash,
                      let record = try JSONSerialization.jsonObject(with: entry.payload) as? [String: Any],
                      let eventID = record["eventId"] as? String, ids.insert(eventID).inserted else { throw WorkbenchFailure("invalid audit") }
                result.records.append(record); result.bytes += bytes.count
                result.lastHash = Self.digest(bytes)
                result.hashes.append(result.lastHash)
            }
            return result
        } catch { throw WorkbenchFailure("审计记录无法验证，原文件未覆盖；受控调用已阻止。") }
    }
    private static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private func sequence(_ url: URL) -> Int? {
        let name = url.lastPathComponent
        guard name.count == 26, name.hasSuffix(".event"), let value = Int(name.prefix(20)), value > 0,
              name == String(format: "%020d.event", value) else { return nil }
        return value
    }
    private func readCheckpoint() throws -> Checkpoint? {
        let url = root.appendingPathComponent("retention.sealed")
        let attributes: URLResourceValues
        do { attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true, (attributes.fileSize ?? Int.max) < 65536 else { throw WorkbenchFailure("保留检查点无效，已阻止继续。") }
        let bytes = try Data(contentsOf: url)
        let checkpoint = try JSONDecoder().decode(Checkpoint.self, from: AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: key))
        guard checkpoint.version == 1, checkpoint.throughSequence > 0, checkpoint.removedCount == checkpoint.throughSequence,
              checkpoint.throughHash.count == 64, checkpoint.throughHash.allSatisfy({ $0.isHexDigit }) else { throw WorkbenchFailure("保留检查点无法验证。") }
        return checkpoint
    }
    private func cleanupRetired() throws {
        guard let checkpoint = try readCheckpoint() else { return }
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            if let index = sequence(file), index <= checkpoint.throughSequence {
                let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else { throw WorkbenchFailure("退休日志类型异常，未自动删除。") }
                try FileManager.default.removeItem(at: file)
            }
        }
        try Self.syncDirectory(root)
    }
    private func removable(_ journal: Verified, before: Date) -> Int {
        let formatter = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return journal.records.prefix { record in
            guard let value = record["timestamp"] as? String, let date = fractional.date(from: value) ?? formatter.date(from: value) else { return false }
            return date < before
        }.count
    }
    func inventory() throws -> AgentAuditInventory {
        lock.lock(); defer { lock.unlock() }
        let journal = try verify()
        return .init(records: journal.records.count, bytes: journal.bytes, retiredRecords: journal.baseSequence)
    }
    func retentionPreview(before: Date) throws -> AgentAuditRetentionPreview {
        lock.lock(); defer { lock.unlock() }
        let journal = try verify()
        return .init(removableCount: removable(journal, before: before), head: journal.lastHash)
    }
    func prune(before: Date, expectedHead: String) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let journal = try verify()
        guard journal.lastHash == expectedHead else { throw WorkbenchFailure("日志已变化，请重新预览清理范围。") }
        let count = removable(journal, before: before)
        guard count > 0 else { try cleanupRetired(); return 0 }
        let oldCheckpoint = root.appendingPathComponent("retention.sealed")
        let previous = journal.checkpoint == nil ? "genesis" : Self.digest(try Data(contentsOf: oldCheckpoint))
        let checkpoint = Checkpoint(version: 1, throughSequence: journal.baseSequence + count,
            throughHash: journal.hashes[count - 1], removedCount: journal.baseSequence + count,
            cutoff: before, date: Date(), previousCheckpointHash: previous)
        guard let sealed = try AES.GCM.seal(JSONEncoder().encode(checkpoint), using: key).combined else { throw WorkbenchFailure("无法生成保留检查点。") }
        try Self.writePrivate(sealed, to: oldCheckpoint)
        // The authenticated checkpoint is the commit point. A crash before cleanup
        // leaves only explicitly retired ciphertext, removed on the next open.
        _ = try verify()
        try cleanupRetired()
        return count
    }
    func exportData(taskID: UUID?, includeContents: Bool) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        let journal = try verify()
        let records = journal.records.filter { taskID == nil || ($0["taskId"] as? String).flatMap(UUID.init(uuidString:)) == taskID }
        let fields = Set(["eventId", "taskId", "callId", "kind", "timestamp", "destination", "model", "api", "requestHash", "bytes", "bodyRedacted", "status", "complete", "phase", "policy", "allow", "exportId", "includesContents", "scope", "sha256", "days"])
        let exported: [[String: Any]] = includeContents ? records : records.map { record in
            var summary = record.filter { fields.contains($0.key) }
            if let usage = record["usage"] as? [String: Any] {
                summary["usage"] = usage.filter { ["totalInput", "output", "cacheRead", "cacheWrite", "source"].contains($0.key) }
            }
            return summary
        }
        var envelope: [String: Any] = ["schemaVersion": 1, "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "includesContents": includeContents, "format": "plaintext-json", "records": exported,
            "retiredRecords": journal.baseSequence, "retainedHead": journal.lastHash,
            "integrityScope": "local authenticated journal; no external anti-rollback anchor"]
        if let taskID { envelope["taskId"] = taskID.uuidString }
        if let checkpoint = journal.checkpoint {
            envelope["retentionCheckpoint"] = ["version": checkpoint.version, "throughSequence": checkpoint.throughSequence, "throughHash": checkpoint.throughHash, "removedCount": checkpoint.removedCount, "cutoff": ISO8601DateFormatter().string(from: checkpoint.cutoff), "date": ISO8601DateFormatter().string(from: checkpoint.date), "previousCheckpointHash": checkpoint.previousCheckpointHash]
        }
        return try JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
    static func writePrivate(_ bytes: Data, to destination: URL) throws {
        guard destination.isFileURL else { throw WorkbenchFailure("仅允许保存到本机文件。") }
        let parent = destination.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(".pending-" + UUID().uuidString)
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw WorkbenchFailure("无法创建私有导出文件。") }
        defer { Darwin.close(descriptor); try? FileManager.default.removeItem(at: temporary) }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw WorkbenchFailure("文件写入失败。") }
                offset += written
            }
        }
        guard fsync(descriptor) == 0 else { throw WorkbenchFailure("无法确认文件持久化。") }
        guard Darwin.rename(temporary.path, destination.path) == 0 else { throw WorkbenchFailure("无法保存目标文件。") }
        try syncDirectory(parent)
    }
    private static func syncDirectory(_ root: URL) throws {
        let descriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw WorkbenchFailure("无法打开保存目录。") }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw WorkbenchFailure("无法确认目录持久化。") }
    }

}
