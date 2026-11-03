import Foundation
import CryptoKit

/// Host-only relocation. Call while all app writers and child processes are quiescent.
/// The locator is outside root. Callers must reopen their services after success.
struct AgentXRootCoordinator {
    let locator: URL
    private let fm = FileManager.default
    private struct Location: Codable { let version: Int; let path: String }
    private struct Relocation: Codable {
        let version: Int
        let sourceRoot: String
        let destinationRoot: String
        let sourceRoots: [String]?
    }
    enum Failure: Error { case busy, unsafePath(String), destinationExists, changedDuringCopy, corruptLocator }

    func resolve(fallback: URL) throws -> URL {
        try checkAncestors(locator)
        guard fm.fileExists(atPath: locator.path) else { return fallback }
        let value = try JSONDecoder().decode(Location.self, from: Data(contentsOf: locator))
        guard value.version == 1, value.path.hasPrefix("/"), value.path != "/", !value.path.contains("\0") else { throw Failure.corruptLocator }
        let root = URL(fileURLWithPath: value.path, isDirectory: true)
        try checkAncestors(root)
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue,
              fm.isReadableFile(atPath: root.path) else { throw Failure.unsafePath(root.path) }
        return root
    }

    func migrate(from source: URL, to destination: URL, isIdle: Bool, verifyCopy: ((URL) throws -> Void)? = nil, beforePublish: ((URL, URL) throws -> Void)? = nil) throws {
        guard isIdle else { throw Failure.busy }
        try checkAncestors(source); try checkAncestors(destination); try checkAncestors(locator)
        guard source.path != "/", destination.path != "/", source != destination,
              !destination.path.hasPrefix(source.path + "/"), !source.path.hasPrefix(destination.path + "/"),
              !locator.path.hasPrefix(source.path + "/"), !locator.path.hasPrefix(destination.path + "/") else { throw Failure.unsafePath(destination.path) }
        guard !fm.fileExists(atPath: destination.path) else { throw Failure.destinationExists }
        let before = try snapshot(source)
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".agentx-migration-\(UUID())")
        defer { try? fm.removeItem(at: stage) }
        try fm.copyItem(at: source, to: stage)
        try verifyCopy?(stage)
        guard try snapshot(stage) == before, try snapshot(source) == before else { throw Failure.changedDuringCopy }
        try fm.moveItem(at: stage, to: destination)
        do {
            // Platform-owned provenance authorizes rebinding generated native config only.
            // Transports must independently prove the old daemon is absent before using it.
            var sources = [source.path]
            let previousURL = source.appendingPathComponent("manager/root-relocation.json")
            if fm.fileExists(atPath: previousURL.path) {
                let previous = try JSONDecoder().decode(Relocation.self, from: Data(contentsOf: previousURL))
                guard previous.version == 1, previous.destinationRoot == source.path else { throw Failure.corruptLocator }
                for path in previous.sourceRoots ?? [previous.sourceRoot] {
                    let prior = URL(fileURLWithPath: path, isDirectory: true)
                    guard path.hasPrefix("/"), path != "/", !path.contains("\0"),
                          !prior.pathComponents.contains("."), !prior.pathComponents.contains("..") else { throw Failure.corruptLocator }
                    if !sources.contains(path) { sources.append(path) }
                }
            }
            guard sources.count <= 128 else { throw Failure.corruptLocator }
            let marker = destination.appendingPathComponent("manager/root-relocation.json")
            try fm.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(Relocation(version: 1, sourceRoot: source.path, destinationRoot: destination.path, sourceRoots: sources)).write(to: marker, options: .atomic)
            try beforePublish?(source, destination)
            try fm.createDirectory(at: locator.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(Location(version: 1, path: destination.path)).write(to: locator, options: .atomic)
        } catch {
            // Only remove the directory created by this transaction; never touch source.
            try? fm.removeItem(at: destination)
            throw error
        }
    }

    /// Copy an offline legacy application's data into its own managed subtree.
    /// Never removes source, never publishes a new root locator, and never follows links.
    func importVerifiedTree(from source: URL, to destination: URL, isIdle: Bool, excludedTopLevel: Set<String> = []) throws {
        guard isIdle else { throw Failure.busy }
        try checkAncestors(source); try checkAncestors(destination)
        guard source.path != "/", destination.path != "/", source.path != destination.path,
              !destination.path.hasPrefix(source.path + "/"), !source.path.hasPrefix(destination.path + "/") else { throw Failure.unsafePath(destination.path) }
        guard !fm.fileExists(atPath: destination.path) else { throw Failure.destinationExists }
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw Failure.unsafePath(source.path) }
        guard excludedTopLevel.allSatisfy({ !$0.isEmpty && !$0.contains("/") && $0 != "." && $0 != ".." }) else { throw Failure.unsafePath(source.path) }
        let before = try snapshot(source, excluding: excludedTopLevel)
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stage = parent.appendingPathComponent(".agentx-import-\(UUID())")
        defer { try? fm.removeItem(at: stage) }
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for child in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) where !excludedTopLevel.contains(child.lastPathComponent) {
            try fm.copyItem(at: child, to: stage.appendingPathComponent(child.lastPathComponent))
        }
        guard try snapshot(stage) == before, try snapshot(source, excluding: excludedTopLevel) == before else { throw Failure.changedDuringCopy }
        try fm.moveItem(at: stage, to: destination)
    }

    private func checkAncestors(_ url: URL) throws {
        guard url.isFileURL, !url.path.contains("\0"), !url.pathComponents.contains(".."), !url.pathComponents.contains(".") else { throw Failure.unsafePath(url.path) }
        var cursor = URL(fileURLWithPath: "/")
        for part in url.path.split(separator: "/") {
            cursor.appendPathComponent(String(part))
            if let attrs = try? fm.attributesOfItem(atPath: cursor.path), attrs[.type] as? FileAttributeType == .typeSymbolicLink { throw Failure.unsafePath(cursor.path) }
        }
    }
    private func snapshot(_ root: URL, excluding: Set<String> = []) throws -> [String: String] {
        var result: [String: String] = [:]
        var failure: Error?
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [], errorHandler: { _, error in failure = error; return false }) else { throw Failure.unsafePath(root.path) }
        for case let file as URL in enumerator {
            let attrs = try fm.attributesOfItem(atPath: file.path)
            let type = attrs[.type] as? FileAttributeType
            let relative = String(file.path.dropFirst(root.path.count + 1))
            if let first = relative.split(separator: "/").first, excluding.contains(String(first)) {
                if type == .typeDirectory { enumerator.skipDescendants() }
                continue
            }
            if type == .typeDirectory { result[relative] = "directory"; continue }
            guard type == .typeRegular, (attrs[.referenceCount] as? NSNumber)?.intValue == 1 else { throw Failure.unsafePath(file.path) }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hash = SHA256()
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
            result[relative] = hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        if let failure { throw failure }
        return result
    }
}
