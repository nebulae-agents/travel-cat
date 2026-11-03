import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Trusted host broker. Root and its ancestor directories must be controlled by the host.
/// Untrusted code must execute out of process under an OS sandbox, never in this broker.
public final class AppFileAccess {
    private let rootFD: Int32
    private let grants: [AppFileGrant]
    public init(root: URL, appID: String, grants: [AppFileGrant]) throws {
        guard root.isFileURL, validID(appID) else { throw AppSDKError.invalidPath }
        for grant in grants { try grant.validate(for: appID) }
        self.grants = grants
        // Walk absolute root too: no symlink-containing root is silently accepted.
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw AppSDKError.system(errno) }
        do {
            for part in try components(String(root.path.dropFirst())) {
                let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw AppSDKError.system(errno) }
                close(fd); fd = next
            }
        } catch { close(fd); throw error }
        rootFD = fd
    }
    deinit { close(rootFD) }
    private func parent(_ path: String, writing: Bool) throws -> (Int32, String) {
        let parts = try components(path)
        guard grants.contains(where: { grant in
            (!writing || grant.access == .readWrite) && (path == grant.relativePath || path.hasPrefix(grant.relativePath + "/"))
        }) else { throw AppSDKError.denied }
        var fd = dup(rootFD)
        guard fd >= 0 else { throw AppSDKError.system(errno) }
        do {
            for part in parts.dropLast() {
                let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw AppSDKError.system(errno) }
                close(fd); fd = next
            }
            return (fd, parts.last!)
        } catch { close(fd); throw error }
    }
    private func regular(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw AppSDKError.system(errno) }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw AppSDKError.unsafeFile }
    }
    public func read(relativePath: String, maximumBytes: Int = 16 * 1024 * 1024) throws -> Data {
        guard maximumBytes > 0 else { throw AppSDKError.unsafeFile }
        let (directory, name) = try parent(relativePath, writing: false)
        defer { close(directory) }
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw AppSDKError.system(errno) }
        defer { close(fd) }
        try regular(fd)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size >= 0, info.st_size <= maximumBytes else { throw AppSDKError.unsafeFile }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = buffer.withUnsafeMutableBytes { systemRead(fd, $0.baseAddress!, $0.count) }
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; throw AppSDKError.system(errno) }
            guard count <= maximumBytes - data.count else { throw AppSDKError.unsafeFile }
            data.append(contentsOf: buffer.prefix(count))
        }
        try regular(fd)
        return data
    }
    public func write(_ data: Data, relativePath: String) throws {
        let (directory, name) = try parent(relativePath, writing: true)
        defer { close(directory) }
        let existing = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if existing >= 0 { defer { close(existing) }; try regular(existing) }
        else if errno != ENOENT { throw AppSDKError.system(errno) }
        // Never truncate the existing inode; a racing hard link cannot modify another app's file.
        let temporary = ".agentx-" + UUID().uuidString
        let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AppSDKError.system(errno) }
        defer { close(fd); unlinkat(directory, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = systemWrite(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw AppSDKError.system(errno) }
                guard count > 0 else { throw AppSDKError.unsafeFile }
                offset += count
            }
        }
        guard fsync(fd) == 0, renameat(directory, temporary, directory, name) == 0 else { throw AppSDKError.system(errno) }
    }
}
private func systemRead(_ fd: Int32, _ ptr: UnsafeMutableRawPointer, _ size: Int) -> Int {
#if canImport(Darwin)
    Darwin.read(fd, ptr, size)
#else
    Glibc.read(fd, ptr, size)
#endif
}
private func systemWrite(_ fd: Int32, _ ptr: UnsafeRawPointer, _ size: Int) -> Int {
#if canImport(Darwin)
    Darwin.write(fd, ptr, size)
#else
    Glibc.write(fd, ptr, size)
#endif
}
