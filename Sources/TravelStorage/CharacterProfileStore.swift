import CryptoKit
import Darwin
import Foundation
import ImageIO
import TravelCore

public enum CharacterProfileStoreError: Error, Equatable, Sendable {
    case unsafePath
    case invalidManifest
    case unsupportedSprite
    case invalidAsset
    case corruptSelection
    case revisionConflict
}

public struct CharacterProfileStore: Sendable {
    private static let maximumManifestBytes = 64 * 1_024
    private static let maximumAssetBytes = 16 * 1_024 * 1_024
    private static let maximumTotalAssetBytes = 48 * 1_024 * 1_024
    private let configuredDataRoot: URL
    private let dataRoot: URL
    private let writer = AtomicFileWriter()

    public init(dataRoot: URL) {
        configuredDataRoot = dataRoot
        self.dataRoot = Self.platformCanonicalURL(dataRoot)
    }

    public func selectedProfile() throws -> CharacterProfile {
        try validateComponents(of: configuredDataRoot)
        let pointerURL = dataRoot.appendingPathComponent("state/active-character.json")
        do {
            try validateComponents(of: pointerURL)
            var pointerInfo = stat()
            guard lstat(pointerURL.path, &pointerInfo) == 0 else {
                if errno == ENOENT { return .defaultBlackCat }
                throw CharacterProfileStoreError.corruptSelection
            }
            try requireRegular(pointerURL)
            let pointer = try JSONDecoder.travelCat.decode(Selection.self, from: boundedData(pointerURL, maximum: Self.maximumManifestBytes))
            guard pointer.version == 1 else { throw CharacterProfileStoreError.corruptSelection }
            if pointer.profile == nil { return .defaultBlackCat }
            guard let relative = pointer.profile, isSafeRelative(relative) else { throw CharacterProfileStoreError.corruptSelection }
            let profileURL = dataRoot.appendingPathComponent(relative)
            guard isDescendant(profileURL, of: dataRoot) else { throw CharacterProfileStoreError.corruptSelection }
            try validateComponents(of: profileURL)
            try requireRegular(profileURL)
            let profile = try JSONDecoder.travelCat.decode(CharacterProfile.self, from: boundedData(profileURL, maximum: Self.maximumManifestBytes))
            try validateStored(profile, profileURL: profileURL)
            return profile
        } catch let error as CharacterProfileStoreError {
            if error == .corruptSelection { throw error }
            throw CharacterProfileStoreError.corruptSelection
        } catch {
            throw CharacterProfileStoreError.corruptSelection
        }
    }

    @discardableResult
    public func importProfile(from directory: URL) throws -> CharacterProfile {
        try validateComponents(of: configuredDataRoot)
        try validateComponents(of: directory)
        try requireDirectory(directory)
        let sourceRoot = Self.platformCanonicalURL(directory)
        try requireDirectory(sourceRoot)
        let manifestURL = sourceRoot.appendingPathComponent("pet.json")
        try requireRegular(manifestURL)
        let manifestData = try boundedData(manifestURL, maximum: Self.maximumManifestBytes)
        let manifest: ImportManifest
        do { manifest = try JSONDecoder().decode(ImportManifest.self, from: manifestData) }
        catch { throw CharacterProfileStoreError.invalidManifest }
        let id = manifest.id ?? sourceRoot.lastPathComponent
        try validate(manifest, id: id)

        let assetPaths = [manifest.spritesheetPath] + manifest.referenceImagePaths
        var assets: [(String, URL, Data)] = []
        var total = 0
        for (index, path) in assetPaths.enumerated() {
            let url = try safeSource(path, within: sourceRoot)
            try requireRegular(url)
            let data = try boundedData(url, maximum: Self.maximumAssetBytes)
            total += data.count
            guard total <= Self.maximumTotalAssetBytes else { throw CharacterProfileStoreError.invalidAsset }
            try validateImage(data, sprite: index == 0)
            assets.append((path, url, data))
        }

        let digest = revisionDigest(manifest: manifest, id: id, assets: assets.map { ($0.0, $0.2) })
        let revisionRelative = "characters/\(id)/\(digest)"
        let revision = dataRoot.appendingPathComponent(revisionRelative, isDirectory: true)
        let profile = CharacterProfile(
            id: id,
            displayName: manifest.displayName,
            description: manifest.description,
            spriteVersionNumber: manifest.spriteVersionNumber,
            sprite: .dataRootRelative("\(revisionRelative)/assets/\(manifest.spritesheetPath)"),
            referenceImages: manifest.referenceImagePaths.map { .dataRootRelative("\(revisionRelative)/assets/\($0)") },
            source: .importedManifest("\(revisionRelative)/source-manifest.json")
        )
        if FileManager.default.fileExists(atPath: revision.path) {
            let profileURL = revision.appendingPathComponent("profile.json")
            try validateComponents(of: profileURL)
            try requireRegular(profileURL)
            let stored: CharacterProfile
            do { stored = try JSONDecoder.travelCat.decode(CharacterProfile.self, from: boundedData(profileURL, maximum: Self.maximumManifestBytes)) }
            catch { throw CharacterProfileStoreError.corruptSelection }
            guard stored == profile else { throw CharacterProfileStoreError.corruptSelection }
            try validateStored(stored, profileURL: profileURL)
        } else {
            try publish(profile: profile, manifestData: manifestData, assets: assets, revision: revision)
        }
        try select(profileRelativePath: "\(revisionRelative)/profile.json")
        return profile
    }

    public func selectDefault() throws { try select(profileRelativePath: nil) }

    /// Copies one already-imported immutable revision into this store and selects it only after
    /// the destination copy has passed the same validation as a normal import.
    @discardableResult
    public func importValidatedRevision(
        _ profile: CharacterProfile,
        from sourceStore: CharacterProfileStore
    ) throws -> CharacterProfile {
        let validated = try sourceStore.validatedProfile(profile)
        if validated == .defaultBlackCat {
            try selectDefault()
            return validated
        }
        guard case let .importedManifest(manifestPath) = validated.source,
              sourceStore.isSafeRelative(manifestPath)
        else { throw CharacterProfileStoreError.corruptSelection }
        let revisionRelative = manifestPath.split(separator: "/").dropLast()
        guard !revisionRelative.isEmpty else { throw CharacterProfileStoreError.corruptSelection }

        try validateComponents(of: configuredDataRoot)
        try sourceStore.validateComponents(of: sourceStore.configuredDataRoot)
        let sourceRootPath = sourceStore.dataRoot.path + "/"
        let destinationRootPath = dataRoot.path + "/"
        guard sourceRootPath != destinationRootPath,
              !sourceRootPath.hasPrefix(destinationRootPath),
              !destinationRootPath.hasPrefix(sourceRootPath)
        else { throw CharacterProfileStoreError.unsafePath }

        let relative = revisionRelative.joined(separator: "/")
        let sourceRevision = sourceStore.dataRoot.appendingPathComponent(relative, isDirectory: true)
        let manifestURL = sourceStore.dataRoot.appendingPathComponent(manifestPath)
        try sourceStore.requireRegular(manifestURL)
        let manifestData = try sourceStore.boundedData(manifestURL, maximum: Self.maximumManifestBytes)
        guard let manifest = try? JSONDecoder().decode(ImportManifest.self, from: manifestData) else {
            throw CharacterProfileStoreError.corruptSelection
        }
        try sourceStore.validate(manifest, id: validated.id)
        let paths = [manifest.spritesheetPath] + manifest.referenceImagePaths
        var assets: [(String, URL, Data)] = []
        var total = 0
        for (index, path) in paths.enumerated() {
            let url = try sourceStore.safeSource("assets/\(path)", within: sourceRevision)
            try sourceStore.requireRegular(url)
            let data = try sourceStore.boundedData(url, maximum: Self.maximumAssetBytes)
            total += data.count
            guard total <= Self.maximumTotalAssetBytes else { throw CharacterProfileStoreError.invalidAsset }
            try sourceStore.validateImage(data, sprite: index == 0)
            assets.append((path, url, data))
        }

        let destinationRevision = dataRoot.appendingPathComponent(relative, isDirectory: true)
        if FileManager.default.fileExists(atPath: destinationRevision.path) {
            let profileURL = destinationRevision.appendingPathComponent("profile.json")
            try validateComponents(of: profileURL)
            try requireRegular(profileURL)
            let stored: CharacterProfile
            do {
                stored = try JSONDecoder.travelCat.decode(
                    CharacterProfile.self,
                    from: boundedData(profileURL, maximum: Self.maximumManifestBytes))
            } catch {
                throw CharacterProfileStoreError.corruptSelection
            }
            guard stored == validated else { throw CharacterProfileStoreError.revisionConflict }
            try validateStored(stored, profileURL: profileURL)
        } else {
            try publish(
                profile: validated, manifestData: manifestData, assets: assets,
                revision: destinationRevision)
        }
        try select(profileRelativePath: "\(relative)/profile.json")
        return validated
    }

    /// Revalidates an immutable imported revision even when it is not selected.
    public func validatedProfile(_ profile: CharacterProfile) throws -> CharacterProfile {
        if profile == .defaultBlackCat { return profile }
        guard case let .importedManifest(sourcePath) = profile.source,
              isSafeRelative(sourcePath) else { throw CharacterProfileStoreError.corruptSelection }
        let profileURL = dataRoot.appendingPathComponent(sourcePath)
            .deletingLastPathComponent().appendingPathComponent("profile.json")
        do {
            try validateComponents(of: configuredDataRoot)
            try validateStored(profile, profileURL: profileURL)
            return profile
        } catch {
            throw CharacterProfileStoreError.corruptSelection
        }
    }

    private func select(profileRelativePath: String?) throws {
        try validateComponents(of: configuredDataRoot)
        let data = try JSONEncoder.travelCat.encode(Selection(version: 1, profile: profileRelativePath))
        let destination = dataRoot.appendingPathComponent("state/active-character.json")
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        try ensureNoSymlinkComponents(destination.deletingLastPathComponent(), stoppingAt: dataRoot)
        try writer.write(data, to: destination)
    }

    private func publish(profile: CharacterProfile, manifestData: Data, assets: [(String, URL, Data)], revision: URL) throws {
        let parent = revision.deletingLastPathComponent()
        try validateComponents(of: parent)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try ensureNoSymlinkComponents(parent, stoppingAt: dataRoot)
        let staging = parent.appendingPathComponent(".\(UUID().uuidString).staging", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try manifestData.write(to: staging.appendingPathComponent("source-manifest.json"), options: .withoutOverwriting)
        for (path, _, data) in assets {
            let destination = staging.appendingPathComponent("assets/\(path)")
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: .withoutOverwriting)
        }
        try JSONEncoder.travelCat.encode(profile).write(to: staging.appendingPathComponent("profile.json"), options: .withoutOverwriting)
        try validateStored(profile, profileURL: staging.appendingPathComponent("profile.json"), expectedRevision: revision.lastPathComponent)
        guard rename(staging.path, revision.path) == 0 else {
            if errno == EEXIST { throw CharacterProfileStoreError.revisionConflict }
            throw CharacterProfileStoreError.invalidAsset
        }
    }

    private func validateStored(_ profile: CharacterProfile, profileURL: URL, expectedRevision: String? = nil) throws {
        try validateComponents(of: profileURL)
        try requireRegular(profileURL)
        let revision = profileURL.deletingLastPathComponent()
        let digest = expectedRevision ?? revision.lastPathComponent
        guard profileURL.lastPathComponent == "profile.json" else { throw CharacterProfileStoreError.corruptSelection }
        if expectedRevision == nil {
            let expectedProfileURL = dataRoot
                .appendingPathComponent("characters/\(profile.id)/\(digest)/profile.json")
            guard profileURL.path == expectedProfileURL.path else { throw CharacterProfileStoreError.corruptSelection }
        }
        guard profile.id == revision.deletingLastPathComponent().lastPathComponent,
              case let .importedManifest(sourcePath) = profile.source,
              case let .dataRootRelative(spritePath) = profile.sprite,
              sourcePath.hasSuffix("/\(digest)/source-manifest.json"),
              spritePath.hasPrefix("characters/\(profile.id)/\(digest)/assets/") else { throw CharacterProfileStoreError.corruptSelection }
        let sourceURL = revision.appendingPathComponent("source-manifest.json")
        try requireRegular(sourceURL)
        let sourceData = try boundedData(sourceURL, maximum: Self.maximumManifestBytes)
        guard let manifest = try? JSONDecoder().decode(ImportManifest.self, from: sourceData) else { throw CharacterProfileStoreError.corruptSelection }
        try validate(manifest, id: profile.id)
        let paths = [manifest.spritesheetPath] + manifest.referenceImagePaths
        var assets: [(String, Data)] = []
        for (index, path) in paths.enumerated() {
            let url = revision.appendingPathComponent("assets/\(path)")
            guard isDescendant(url, of: revision) else { throw CharacterProfileStoreError.corruptSelection }
            try validateComponents(of: url)
            try requireRegular(url)
            let data = try boundedData(url, maximum: Self.maximumAssetBytes)
            try validateImage(data, sprite: index == 0)
            assets.append((path, data))
        }
        guard revisionDigest(manifest: manifest, id: profile.id, assets: assets) == digest else { throw CharacterProfileStoreError.corruptSelection }
        let expected = CharacterProfile(id: profile.id, displayName: manifest.displayName, description: manifest.description, spriteVersionNumber: 2, sprite: .dataRootRelative("characters/\(profile.id)/\(digest)/assets/\(manifest.spritesheetPath)"), referenceImages: manifest.referenceImagePaths.map { .dataRootRelative("characters/\(profile.id)/\(digest)/assets/\($0)") }, source: .importedManifest("characters/\(profile.id)/\(digest)/source-manifest.json"))
        guard profile == expected else { throw CharacterProfileStoreError.corruptSelection }
    }

    private func revisionDigest(manifest: ImportManifest, id: String, assets: [(String, Data)]) -> String {
        var hash = SHA256()
        hash.update(data: Data(id.utf8))
        hash.update(data: (try? JSONEncoder.travelCat.encode(manifest)) ?? Data())
        for (path, data) in assets { hash.update(data: Data(path.utf8)); hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func validate(_ manifest: ImportManifest, id: String) throws {
        guard id.count <= 64, id.range(of: "^[a-z0-9][a-z0-9-]*$", options: .regularExpression) != nil,
              !manifest.displayName.isEmpty, manifest.displayName.count <= 128,
              !manifest.description.isEmpty, manifest.description.count <= 4_096,
              manifest.spriteVersionNumber == 2, manifest.referenceImagePaths.count <= 3 else { throw CharacterProfileStoreError.invalidManifest }
        for path in [manifest.spritesheetPath] + manifest.referenceImagePaths where !isSafeRelative(path) { throw CharacterProfileStoreError.unsafePath }
    }

    private func safeSource(_ path: String, within root: URL) throws -> URL {
        guard isSafeRelative(path) else { throw CharacterProfileStoreError.unsafePath }
        let url = root.appendingPathComponent(path)
        guard isDescendant(url, of: root) else { throw CharacterProfileStoreError.unsafePath }
        try validateComponents(of: url)
        try ensureNoSymlinkComponents(url, stoppingAt: root)
        return url
    }

    private func validateImage(_ data: Data, sprite: Bool) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source) as String?, type == "org.webmproject.webp" || (!sprite && type == "public.png"),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 4_096, height <= 4_096,
              (!sprite || (width == 1_536 && height == 2_288)),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              !sprite || image.alphaInfo == .premultipliedLast || image.alphaInfo == .premultipliedFirst || image.alphaInfo == .last || image.alphaInfo == .first else { throw sprite ? CharacterProfileStoreError.unsupportedSprite : .invalidAsset }
    }

    private func boundedData(_ url: URL, maximum: Int) throws -> Data {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? maximum + 1
        guard size <= maximum else { throw CharacterProfileStoreError.invalidAsset }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    private func requireRegular(_ url: URL) throws { var info = stat(); guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw CharacterProfileStoreError.unsafePath } }
    private func requireDirectory(_ url: URL) throws { var info = stat(); guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { throw CharacterProfileStoreError.unsafePath } }
    private func isSafeRelative(_ path: String) -> Bool { !path.isEmpty && !path.hasPrefix("/") && path.count <= 1_024 && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." } }
    private func isDescendant(_ url: URL, of root: URL) -> Bool { url.path.hasPrefix(root.path + "/") }
    private func ensureNoSymlinkComponents(_ url: URL, stoppingAt root: URL) throws { var current = url; while current.path != root.path { var info = stat(); if lstat(current.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK { throw CharacterProfileStoreError.unsafePath }; let parent = current.deletingLastPathComponent(); guard parent.path != current.path else { throw CharacterProfileStoreError.unsafePath }; current = parent }; var rootInfo = stat(); if lstat(root.path, &rootInfo) == 0, (rootInfo.st_mode & S_IFMT) == S_IFLNK { throw CharacterProfileStoreError.unsafePath } }
    private func validateComponents(of url: URL) throws {
        let path = url.path
        var current = ""
        for component in path.split(separator: "/") {
            current += "/" + component
            var info = stat()
            if lstat(current, &info) == 0 {
                if (info.st_mode & S_IFMT) == S_IFLNK {
                    guard current == "/var" || current == "/tmp" else { throw CharacterProfileStoreError.unsafePath }
                    let expected = current == "/var" ? "private/var" : "private/tmp"
                    guard (try? FileManager.default.destinationOfSymbolicLink(atPath: current)) == expected else { throw CharacterProfileStoreError.unsafePath }
                }
            } else if errno != ENOENT {
                throw CharacterProfileStoreError.unsafePath
            }
        }
    }

    private static func platformCanonicalURL(_ url: URL) -> URL {
        let path = url.path
        if path == "/var" || path.hasPrefix("/var/") { return URL(fileURLWithPath: "/private" + path) }
        if path == "/tmp" || path.hasPrefix("/tmp/") { return URL(fileURLWithPath: "/private" + path) }
        return url.standardizedFileURL
    }
}

private struct Selection: Codable { let version: Int; let profile: String? }
private struct ImportManifest: Codable {
    let id: String?
    let displayName: String
    let description: String
    let spriteVersionNumber: Int
    let spritesheetPath: String
    let referenceImagePaths: [String]
    init(from decoder: Decoder) throws {
        let raw = try decoder.container(keyedBy: DynamicCodingKey.self)
        guard Set(raw.allKeys.map(\.stringValue)).isSubset(of: Set(CodingKeys.allCases.map(\.rawValue))) else { throw CharacterProfileStoreError.invalidManifest }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        description = try c.decode(String.self, forKey: .description)
        spriteVersionNumber = try c.decode(Int.self, forKey: .spriteVersionNumber)
        spritesheetPath = try c.decode(String.self, forKey: .spritesheetPath)
        referenceImagePaths = try c.decodeIfPresent([String].self, forKey: .referenceImagePaths) ?? []
    }
    private enum CodingKeys: String, CodingKey, CaseIterable { case id, displayName, description, spriteVersionNumber, spritesheetPath, referenceImagePaths }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
