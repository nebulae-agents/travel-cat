import CryptoKit
import Darwin
import Foundation

extension WorkbenchStore {
    @MainActor
    static func encrypted(root: URL, credentials: any AsyncTravelServiceCredentialStoring) async throws -> WorkbenchStore {
        let identifier = "workbench-content-v1"
        let exists = try EncryptedWorkbenchStorage.hasSealedFile(root: root)
        let value = try await credentials.read(id: identifier)
        try Task.checkCancellation()
        if let value {
            guard let key = Data(base64Encoded: value), key.count == 32 else { throw WorkbenchFailure("对话加密密钥无效，原数据未修改。") }
            return WorkbenchStore(root: root, keyData: key)
        }
        guard !exists else { throw WorkbenchFailure("对话加密密钥缺失，已保留密文；请恢复原钥匙串。") }
        try Task.checkCancellation()
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        try await credentials.save(key.base64EncodedString(), id: identifier)
        try Task.checkCancellation()
        guard try await credentials.read(id: identifier) == key.base64EncodedString() else {
            throw WorkbenchFailure("无法确认对话密钥已保存，未迁移原数据。")
        }
        try Task.checkCancellation()
        return WorkbenchStore(root: root, keyData: key)
    }

    @MainActor
    static func encrypted(root: URL, credentials: any TravelServiceCredentialStoring) throws -> WorkbenchStore {
        let identifier = "workbench-content-v1"
        // Inspect storage even if a credential exists; errors must not become 'missing'.
        let exists = try EncryptedWorkbenchStorage.hasSealedFile(root: root)
        if let value = try credentials.read(id: identifier) {
            guard let key = Data(base64Encoded: value), key.count == 32 else {
                throw WorkbenchFailure("对话加密密钥无效，原数据未修改。")
            }
            return WorkbenchStore(root: root, keyData: key)
        }
        guard !exists else { throw WorkbenchFailure("对话加密密钥缺失，已保留密文；请恢复原钥匙串。") }
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        try credentials.save(key.base64EncodedString(), id: identifier)
        guard try credentials.read(id: identifier) == key.base64EncodedString() else {
            throw WorkbenchFailure("无法确认对话密钥已保存，未迁移原数据。")
        }
        return WorkbenchStore(root: root, keyData: key)
    }
}

/// All file operations are relative to an opened, non-symlink directory.
struct EncryptedWorkbenchStorage {
    let root: URL
    let keyData: Data
    private static let limit = 64 * 1024 * 1024
    private static let header = Data("TCWB1\0".utf8)
    private static let sealedName = "workbench.sealed"
    private static let legacyName = "workbench.json"
    private static func failure() -> WorkbenchFailure { WorkbenchFailure("无法安全读取或保存加密对话，原数据已保留。") }

    static func hasSealedFile(root: URL) throws -> Bool {
        guard let directory = try directory(root, create: false) else { return false }
        defer { close(directory) }
        return try exists(sealedName, directory: directory)
    }

    func load() throws -> Data? {
        try validateKey()
        guard let directory = try Self.directory(root, create: false) else { return nil }
        defer { close(directory) }
        return try load(directory: directory)
    }

    func save(_ bytes: Data) throws {
        try validateKey()
        _ = try Self.decode(bytes)
        guard let directory = try Self.directory(root, create: true) else { throw Self.failure() }
        defer { close(directory) }
        // Resolve a previously interrupted migration before replacing any snapshot.
        _ = try load(directory: directory)
        try write(bytes, directory: directory)
    }

    private func validateKey() throws {
        guard keyData.count == 32 else { throw WorkbenchFailure("对话加密密钥无效，未修改原数据。") }
    }

    private static func decode(_ bytes: Data) throws -> WorkbenchSnapshot {
        guard bytes.count <= limit else { throw failure() }
        let snapshot = try JSONDecoder().decode(WorkbenchSnapshot.self, from: bytes)
        guard snapshot.schemaVersion == 1 else { throw WorkbenchFailure("不支持的对话版本，未覆盖原数据。") }
        return snapshot
    }

    private func load(directory: Int32) throws -> Data? {
        if let sealed = try Self.read(Self.sealedName, directory: directory, limit: Self.limit + 128) {
            let original = try unseal(sealed)
            let snapshot = try Self.decode(original)
            if let legacy = try Self.read(Self.legacyName, directory: directory, limit: Self.limit) {
                let legacySnapshot = try Self.decode(legacy)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                guard try encoder.encode(snapshot) == encoder.encode(legacySnapshot) else {
                    throw WorkbenchFailure("旧对话与加密副本内容冲突，两份数据均已保留。")
                }
                try Self.removeLegacy(directory: directory)
            }
            return original
        }
        guard let legacy = try Self.read(Self.legacyName, directory: directory, limit: Self.limit) else { return nil }
        _ = try Self.decode(legacy)
        try write(legacy, directory: directory)
        // Compare original bytes before changing transient running states or removing plaintext.
        guard let persisted = try Self.read(Self.sealedName, directory: directory, limit: Self.limit + 128),
              try unseal(persisted) == legacy else { throw Self.failure() }
        try Self.removeLegacy(directory: directory)
        return legacy
    }

    private func unseal(_ bytes: Data) throws -> Data {
        guard bytes.starts(with: Self.header) else { throw Self.failure() }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: bytes.dropFirst(Self.header.count)),
                                using: SymmetricKey(data: keyData), authenticating: Self.header)
    }

    private func write(_ bytes: Data, directory: Int32) throws {
        guard bytes.count <= Self.limit else { throw Self.failure() }
        let box = try AES.GCM.seal(bytes, using: SymmetricKey(data: keyData), authenticating: Self.header)
        guard let combined = box.combined else { throw Self.failure() }
        let encrypted = Self.header + combined
        let temporary = ".workbench-\(UUID().uuidString).tmp"
        let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.failure() }
        defer { close(fd); unlinkat(directory, temporary, 0) }
        try encrypted.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Self.failure() }
                offset += count
            }
        }
        guard fchmod(fd, 0o600) == 0, fsync(fd) == 0 else { throw Self.failure() }
        _ = try Self.exists(Self.sealedName, directory: directory)
        guard renameat(directory, temporary, directory, Self.sealedName) == 0, fsync(directory) == 0 else {
            throw Self.failure()
        }
    }

    private static func removeLegacy(directory: Int32) throws {
        guard unlinkat(directory, legacyName, 0) == 0, fsync(directory) == 0 else { throw failure() }
    }

    private static func exists(_ name: String, directory: Int32) throws -> Bool {
        var info = stat()
        guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return false }
            throw failure()
        }
        guard info.st_mode & S_IFMT == S_IFREG else { throw failure() }
        return true
    }

    private static func read(_ name: String, directory: Int32, limit: Int) throws -> Data? {
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            // A dangling symlink is not an absent file.
            if errno == ENOENT, try !exists(name, directory: directory) { return nil }
            throw failure()
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= limit else { throw failure() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw failure() }
            if count == 0 { return data }
            guard data.count + count <= limit else { throw failure() }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    private static func directory(_ root: URL, create: Bool) throws -> Int32? {
        guard root.isFileURL else { throw failure() }
        // macOS system aliases are canonicalized, while user-controlled symlinks are rejected.
        var path = root.standardizedFileURL.path
        for alias in ["/var", "/tmp"] where path == alias || path.hasPrefix(alias + "/") {
            path = "/private" + path
        }
        guard !path.hasPrefix("/dev/") else { throw failure() }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { throw failure() }
        do {
            for part in path.split(separator: "/").map(String.init) {
                var next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0 && errno == ENOENT {
                    if !create { close(current); return nil }
                    guard mkdirat(current, part, 0o700) == 0 || errno == EEXIST else { throw failure() }
                    next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw failure() }
                close(current); current = next
            }
            return current
        } catch { close(current); throw error }
    }
}
