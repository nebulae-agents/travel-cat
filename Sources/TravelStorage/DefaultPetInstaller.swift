import CryptoKit
import Darwin
import Foundation

public enum DefaultPetInstallOutcome: String, Codable, Equatable, Sendable {
    case installed
    case alreadyInstalled
}

public enum DefaultPetInstallerError: Error, Equatable, Sendable {
    case invalidPath
    case unsafePath
    case invalidResource(String)
    case targetConflict
    case publicationFailed
}

public final class DefaultPetInstaller {
    private static let manifestHash = "0e7a05567d37670bf934370615b9f072c84b325c4e4905e829838ae406443481"
    private static let spriteHash = "cf1bc43ebaff9555c2f715a58c147c32d2de78a4d36b11c83643cd5067a62eaf"

    private let resourcesRoot: URL
    private let petsRoot: URL
    var beforePublish: (() throws -> Void)?

    public init(resourcesRoot: URL, petsRoot: URL) {
        self.resourcesRoot = resourcesRoot.standardizedFileURL
        self.petsRoot = petsRoot.standardizedFileURL
    }

    public func install() throws -> DefaultPetInstallOutcome {
        guard absolute(resourcesRoot), absolute(petsRoot) else { throw DefaultPetInstallerError.invalidPath }
        try rejectUnsafeAncestors(resourcesRoot)
        let manifest = try readResource(name: "pet.json", expectedHash: Self.manifestHash)
        let sprite = try readResource(name: "cute-black-cat-spritesheet.webp", expectedHash: Self.spriteHash)

        let codexHome = petsRoot.deletingLastPathComponent()
        try rejectUnsafeAncestors(codexHome)
        try requireDirectory(codexHome)
        if mkdir(petsRoot.path, 0o700) != 0, errno != EEXIST { throw DefaultPetInstallerError.unsafePath }
        try rejectUnsafeAncestors(petsRoot)
        try requireDirectory(petsRoot)

        if targetExists() { return try validateExisting(manifest: manifest, sprite: sprite) }

        let stagingName = ".cute-black-cat-install-\(UUID().uuidString.lowercased())"
        let staging = petsRoot.appendingPathComponent(stagingName, isDirectory: true)
        guard mkdir(staging.path, 0o700) == 0 else { throw DefaultPetInstallerError.publicationFailed }
        let stagingDescriptor = open(staging.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard stagingDescriptor >= 0 else { throw DefaultPetInstallerError.publicationFailed }
        defer { _ = close(stagingDescriptor) }
        var stagingIdentity = stat()
        guard fstat(stagingDescriptor, &stagingIdentity) == 0 else {
            throw DefaultPetInstallerError.publicationFailed
        }
        var ownsStaging = true
        defer {
            if ownsStaging, path(staging, matches: stagingIdentity) {
                try? FileManager.default.removeItem(at: staging)
            }
        }
        try writeNew(manifest, to: staging.appendingPathComponent("pet.json"))
        try writeNew(sprite, to: staging.appendingPathComponent("spritesheet.webp"))
        _ = try validateDirectory(staging, manifest: manifest, sprite: sprite)
        guard fsync(stagingDescriptor) == 0 else { throw DefaultPetInstallerError.publicationFailed }
        try beforePublish?()
        guard path(staging, matches: stagingIdentity) else {
            throw DefaultPetInstallerError.publicationFailed
        }

        let parent = open(petsRoot.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw DefaultPetInstallerError.unsafePath }
        defer { _ = close(parent) }
        if renameatx_np(
            parent, stagingName, parent, "cute-black-cat",
            UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)
        ) == 0 {
            ownsStaging = false
            guard fsync(parent) == 0 else { throw DefaultPetInstallerError.publicationFailed }
            return .installed
        }
        guard errno == EEXIST else { throw DefaultPetInstallerError.publicationFailed }
        return try validateExisting(manifest: manifest, sprite: sprite)
    }

    private func validateExisting(manifest: Data, sprite: Data) throws -> DefaultPetInstallOutcome {
        let target = petsRoot.appendingPathComponent("cute-black-cat", isDirectory: true)
        _ = try validateDirectory(target, manifest: manifest, sprite: sprite)
        return .alreadyInstalled
    }

    private func validateDirectory(_ directory: URL, manifest: Data, sprite: Data) throws -> Bool {
        try rejectUnsafeAncestors(directory)
        try requireDirectory(directory)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        guard names == ["pet.json", "spritesheet.webp"] else { throw DefaultPetInstallerError.targetConflict }
        guard try readRegular(directory.appendingPathComponent("pet.json"), limit: 256 * 1_024) == manifest,
              try readRegular(directory.appendingPathComponent("spritesheet.webp"), limit: 32 * 1_024 * 1_024) == sprite else {
            throw DefaultPetInstallerError.targetConflict
        }
        return true
    }

    private func targetExists() -> Bool {
        var info = stat()
        return lstat(petsRoot.appendingPathComponent("cute-black-cat").path, &info) == 0
    }

    private func readResource(name: String, expectedHash: String) throws -> Data {
        let data: Data
        do { data = try readRegular(resourcesRoot.appendingPathComponent(name), limit: 32 * 1_024 * 1_024) }
        catch { throw DefaultPetInstallerError.invalidResource(name) }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard hash == expectedHash else { throw DefaultPetInstallerError.invalidResource(name) }
        return data
    }

    private func readRegular(_ url: URL, limit: Int) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw DefaultPetInstallerError.unsafePath }
        defer { _ = close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, info.st_size <= limit else { throw DefaultPetInstallerError.unsafePath }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var data = Data()
        while data.count <= limit {
            let chunk = try handle.read(upToCount: min(64 * 1_024, limit + 1 - data.count)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        var finalInfo = stat()
        guard data.count <= limit, fstat(descriptor, &finalInfo) == 0,
              finalInfo.st_size == data.count else { throw DefaultPetInstallerError.unsafePath }
        return data
    }

    private func writeNew(_ data: Data, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw DefaultPetInstallerError.publicationFailed }
        defer { _ = close(descriptor) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard let base = bytes.baseAddress else { throw DefaultPetInstallerError.publicationFailed }
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { throw DefaultPetInstallerError.publicationFailed }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw DefaultPetInstallerError.publicationFailed }
    }

    private func requireDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw DefaultPetInstallerError.unsafePath
        }
    }

    private func path(_ url: URL, matches identity: stat) -> Bool {
        var current = stat()
        return lstat(url.path, &current) == 0
            && (current.st_mode & S_IFMT) == S_IFDIR
            && current.st_dev == identity.st_dev
            && current.st_ino == identity.st_ino
    }

    private func rejectUnsafeAncestors(_ url: URL) throws {
        guard absolute(url) else { throw DefaultPetInstallerError.invalidPath }
        var current = ""
        for component in url.path.split(separator: "/") {
            current += "/\(component)"
            var info = stat()
            guard lstat(current, &info) == 0 else {
                if current == url.path { return }
                throw DefaultPetInstallerError.unsafePath
            }
            if (info.st_mode & S_IFMT) == S_IFLNK, current != "/tmp", current != "/var" {
                throw DefaultPetInstallerError.unsafePath
            }
        }
    }

    private func absolute(_ url: URL) -> Bool {
        url.isFileURL && url.path.hasPrefix("/") && url.baseURL == nil && url.host == nil
    }
}
