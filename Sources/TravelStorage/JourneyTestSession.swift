import Foundation
import Darwin

public struct JourneyTestSession: Sendable {
    public enum SessionError: Error, Equatable, Sendable {
        case invalidURL
        case invalidParent
        case productionOverlap
        case symlinkNotAllowed
        case invalidSession
        case manifestMissing
        case manifestInvalid
        case sessionAlreadyExists
    }

    public let id: UUID
    public let root: URL

    private let parent: URL
    private let productionRoot: URL
    private let parentIdentity: DirectoryIdentity
    private let productionRootIdentity: DirectoryIdentity
    private let rootIdentity: DirectoryIdentity

    private static let manifestName = ".journey-test-session.json"
    private static let manifestVersion = 1

    private struct DirectoryIdentity: Codable, Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
    }

    private struct Manifest: Codable {
        let version: Int
        let id: String
        let root: String
        let parent: String
        let productionRoot: String
        let parentIdentity: DirectoryIdentity
        let productionRootIdentity: DirectoryIdentity
        let rootIdentity: DirectoryIdentity
    }

    public static func create(parent: URL, productionRoot: URL, id: UUID = UUID()) throws -> Self {
        let context = try makeContext(parent: parent, productionRoot: productionRoot)
        let sessionRoot = context.parent.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        guard sessionRoot.isFileURL, sessionRoot.path.hasPrefix("/") else { throw SessionError.invalidURL }
        if FileManager.default.fileExists(atPath: sessionRoot.path) { throw SessionError.sessionAlreadyExists }

        let result = mkdir(sessionRoot.path, mode_t(0o700))
        guard result == 0 else {
            if errno == EEXIST { throw SessionError.sessionAlreadyExists }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        guard let rootIdentity = directoryIdentity(at: sessionRoot) else { throw SessionError.invalidSession }
        let session = Self(
            id: id,
            root: sessionRoot,
            parent: context.parent,
            productionRoot: context.productionRoot,
            parentIdentity: context.parentIdentity,
            productionRootIdentity: context.productionRootIdentity,
            rootIdentity: rootIdentity
        )
        try session.writeManifest()
        try session.validate()
        return session
    }

    public static func open(root: URL, parent: URL, productionRoot: URL) throws -> Self {
        let context = try makeContext(parent: parent, productionRoot: productionRoot)
        guard isAbsoluteFileURL(root) else { throw SessionError.invalidURL }
        guard root.lastPathComponent == root.lastPathComponent.lowercased(),
              let id = UUID(uuidString: root.lastPathComponent),
              id.uuidString.lowercased() == root.lastPathComponent else { throw SessionError.invalidSession }
        guard canonical(root).path == root.standardizedFileURL.path else { throw SessionError.symlinkNotAllowed }
        guard root.deletingLastPathComponent().standardizedFileURL.path == context.parent.standardizedFileURL.path else {
            throw SessionError.invalidSession
        }
        let canonicalRoot = canonical(root)
        let manifest = try readManifest(at: canonicalRoot)
        let session = Self(
            id: id,
            root: canonicalRoot,
            parent: context.parent,
            productionRoot: context.productionRoot,
            parentIdentity: manifest.parentIdentity,
            productionRootIdentity: manifest.productionRootIdentity,
            rootIdentity: manifest.rootIdentity
        )
        try session.validate()
        return session
    }

    public func validate() throws {
        guard Self.isAbsoluteFileURL(root) else { throw SessionError.invalidURL }
        guard Self.fileType(at: parent) == .typeDirectory,
              Self.fileType(at: productionRoot) == .typeDirectory,
              Self.canonical(parent).path == parent.standardizedFileURL.path,
              Self.canonical(productionRoot).path == productionRoot.standardizedFileURL.path else {
            throw SessionError.symlinkNotAllowed
        }
        guard Self.directoryIdentity(at: parent) == parentIdentity,
              Self.directoryIdentity(at: productionRoot) == productionRootIdentity else {
            throw SessionError.invalidSession
        }
        guard root.lastPathComponent == id.uuidString.lowercased() else { throw SessionError.invalidSession }
        guard root.deletingLastPathComponent().standardizedFileURL.path == parent.standardizedFileURL.path else {
            throw SessionError.invalidSession
        }
        guard Self.canonical(root).path == root.standardizedFileURL.path else { throw SessionError.symlinkNotAllowed }
        guard Self.isDisjoint(root, productionRoot) else { throw SessionError.productionOverlap }
        guard Self.fileType(at: root) == .typeDirectory else { throw SessionError.invalidSession }
        guard Self.directoryIdentity(at: root) == rootIdentity else { throw SessionError.invalidSession }

        let manifestURL = root.appendingPathComponent(Self.manifestName)
        guard Self.isAbsoluteFileURL(manifestURL), Self.fileType(at: manifestURL) == .typeRegular else {
            if Self.fileType(at: manifestURL) == .typeSymbolicLink { throw SessionError.symlinkNotAllowed }
            throw SessionError.manifestMissing
        }
        guard Self.canonical(manifestURL).path == manifestURL.standardizedFileURL.path else {
            throw SessionError.symlinkNotAllowed
        }
        guard let size = try? FileManager.default.attributesOfItem(atPath: manifestURL.path)[.size] as? NSNumber,
              size.intValue <= 64 * 1024,
              let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.version == Self.manifestVersion,
              manifest.id == id.uuidString.lowercased(),
              manifest.root == root.standardizedFileURL.path,
              manifest.parent == parent.standardizedFileURL.path,
              manifest.productionRoot == productionRoot.standardizedFileURL.path,
              manifest.parentIdentity == parentIdentity,
              manifest.productionRootIdentity == productionRootIdentity,
              manifest.rootIdentity == rootIdentity,
              Self.isDisjoint(root, productionRoot) else { throw SessionError.manifestInvalid }
    }

    private init(id: UUID, root: URL, parent: URL, productionRoot: URL, parentIdentity: DirectoryIdentity, productionRootIdentity: DirectoryIdentity, rootIdentity: DirectoryIdentity) {
        self.id = id
        self.root = root
        self.parent = parent
        self.productionRoot = productionRoot
        self.parentIdentity = parentIdentity
        self.productionRootIdentity = productionRootIdentity
        self.rootIdentity = rootIdentity
    }

    private func writeManifest() throws {
        let manifest = Manifest(
            version: Self.manifestVersion,
            id: id.uuidString.lowercased(),
            root: root.standardizedFileURL.path,
            parent: parent.standardizedFileURL.path,
            productionRoot: productionRoot.standardizedFileURL.path,
            parentIdentity: parentIdentity,
            productionRootIdentity: productionRootIdentity,
            rootIdentity: rootIdentity
        )
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: root.appendingPathComponent(Self.manifestName), options: .atomic)
    }

    private static func makeContext(parent: URL, productionRoot: URL) throws -> (parent: URL, productionRoot: URL, parentIdentity: DirectoryIdentity, productionRootIdentity: DirectoryIdentity) {
        guard isAbsoluteFileURL(parent), isAbsoluteFileURL(productionRoot), parent.lastPathComponent == "JourneyTests" else {
            throw SessionError.invalidParent
        }
        if fileType(at: parent) == .typeSymbolicLink || fileType(at: productionRoot) == .typeSymbolicLink {
            throw SessionError.symlinkNotAllowed
        }
        guard fileType(at: parent) == .typeDirectory, fileType(at: productionRoot) == .typeDirectory else {
            throw SessionError.invalidParent
        }
        let canonicalParent = canonical(parent)
        let canonicalProduction = canonical(productionRoot)
        guard isDisjoint(parent, productionRoot) else { throw SessionError.productionOverlap }
        guard canonicalParent.path == parent.standardizedFileURL.path,
              canonicalProduction.path == productionRoot.standardizedFileURL.path else { throw SessionError.symlinkNotAllowed }
        guard let parentIdentity = directoryIdentity(at: canonicalParent),
              let productionRootIdentity = directoryIdentity(at: canonicalProduction) else { throw SessionError.invalidParent }
        return (canonicalParent, canonicalProduction, parentIdentity, productionRootIdentity)
    }

    private static func isAbsoluteFileURL(_ url: URL) -> Bool {
        url.isFileURL && url.path.hasPrefix("/") && url.baseURL == nil && url.host == nil && url.query == nil && url.fragment == nil
    }

    private static func canonical(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func isDisjoint(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let leftIdentity = directoryIdentity(at: lhs),
              let rightIdentity = directoryIdentity(at: rhs),
              let leftAncestors = ancestorIdentities(of: lhs),
              let rightAncestors = ancestorIdentities(of: rhs) else { return false }
        if leftIdentity == rightIdentity { return false }
        if rightAncestors.dropFirst().contains(where: { $0 == leftIdentity }) { return false }
        if leftAncestors.dropFirst().contains(where: { $0 == rightIdentity }) { return false }
        let left = canonical(lhs).path.hasSuffix("/") ? canonical(lhs).path : canonical(lhs).path + "/"
        let right = canonical(rhs).path.hasSuffix("/") ? canonical(rhs).path : canonical(rhs).path + "/"
        return left != right && !left.hasPrefix(right) && !right.hasPrefix(left)
    }

    private static func fileType(at url: URL) -> FileAttributeType? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
    }

    private static func directoryIdentity(at url: URL) -> DirectoryIdentity? {
        directoryIdentity(atPath: url.path)
    }

    private static func directoryIdentity(atPath path: String) -> DirectoryIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
        return DirectoryIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }

    private static func ancestorIdentities(of url: URL) -> [DirectoryIdentity]? {
        guard var current = resolvedDirectoryPath(url) else { return nil }
        var identities: [DirectoryIdentity] = []
        while true {
            guard let identity = directoryIdentity(atPath: current) else { return nil }
            identities.append(identity)
            guard current != "/" else { return identities }
            let next = (current as NSString).deletingLastPathComponent
            guard !next.isEmpty, next != current else { return nil }
            current = next
        }
    }

    private static func resolvedDirectoryPath(_ url: URL) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard url.path.withCString({ realpath($0, &buffer) }) != nil else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func readManifest(at root: URL) throws -> Manifest {
        let manifestURL = root.appendingPathComponent(manifestName)
        guard isAbsoluteFileURL(manifestURL), fileType(at: manifestURL) == .typeRegular else {
            if fileType(at: manifestURL) == .typeSymbolicLink { throw SessionError.symlinkNotAllowed }
            throw SessionError.manifestMissing
        }
        guard canonical(manifestURL).path == manifestURL.standardizedFileURL.path else {
            throw SessionError.symlinkNotAllowed
        }
        guard let size = try? FileManager.default.attributesOfItem(atPath: manifestURL.path)[.size] as? NSNumber,
              size.intValue <= 64 * 1024,
              let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
            throw SessionError.manifestInvalid
        }
        return manifest
    }
}
