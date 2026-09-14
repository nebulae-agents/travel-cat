import Foundation
import Darwin
import CryptoKit
import CoreGraphics
import ImageIO
import TravelCore

public enum PostcardPresentationError: Error { case unsafePath, unsafeFile, changedFile, invalidManifest, invalidImage, invalidBinding, ioFailure }

/// Prepares immutable artifacts only. Repository code owns publication and reference selection.
public struct PostcardPresentationStore: Sendable {
    public enum HandwritingInput: Sendable {
        case generated(Data)
        case localFallback(PostcardHandwritingFallbackReason)
    }
    public struct ValidatedPresentation: Sendable {
        public let manifest: PostcardPresentationManifest
        public let sourceData: Data
        public let landscapeData: Data
        public let handwritingData: Data?
    }
    public static let maximumManifestBytes = 65_536
    public static let maximumImageBytes = 15 * 1024 * 1024
    private let root: URL
    public init(root: URL) { self.root = root }

    public func prepare(event: TripEvent, expectedSourceRelativePath: String, derivedLandscapeData: Data? = nil, handwriting: HandwritingInput, placement: PostcardPresentationRect, styleVersion: String) throws -> PostcardPresentationReference {
        try Task.checkCancellation()
        guard placement.isValid, !styleVersion.isEmpty, styleVersion.utf8.count <= 256 else { throw PostcardPresentationError.invalidManifest }
        let sourcePath = try sourcePath(event, expectedSourceRelativePath)
        let files = try PresentationFiles(root: root)
        let sourceData = try files.read(Self.physicalSourcePath(sourcePath), limit: Self.maximumImageBytes)
        try Self.validateImage(sourceData, path: sourcePath, landscape: false, handwriting: false)
        let landscapeData = derivedLandscapeData ?? sourceData
        try Self.validateImage(landscapeData, path: derivedLandscapeData == nil ? sourcePath : "derived.png", landscape: true, handwriting: false)
        if case let .generated(data) = handwriting { try Self.validateImage(data, path: "ink.png", landscape: false, handwriting: true) }
        try Task.checkCancellation()
        let prefix = "postcards/\(event.tripID.uuidString.lowercased())"
        try files.ensureDirectory(prefix)
        let source = PostcardPresentationAsset(relativePath: sourcePath, sha256: Self.digest(sourceData))
        let landscape: PostcardPresentationAsset
        if let data = derivedLandscapeData { landscape = try files.writeAsset(data, prefix: prefix, suffix: "landscape.png") }
        else { landscape = source }
        let ink: PostcardPresentationHandwriting
        switch handwriting {
        case let .generated(data): ink = .generated(try files.writeAsset(data, prefix: prefix, suffix: "handwriting.png"))
        case let .localFallback(reason): ink = .localFallback(reason)
        }
        let manifest = PostcardPresentationManifest(eventID: event.id, tripID: event.tripID, source: source, landscape: landscape, quote: event.mood.quote, quoteSHA256: Self.digest(Data(event.mood.quote.utf8)), styleVersion: styleVersion, placement: placement, handwriting: ink)
        let data = try JSONEncoder().encode(manifest)
        guard data.count <= Self.maximumManifestBytes else { throw PostcardPresentationError.invalidManifest }
        try files.revalidate()
        try Task.checkCancellation()
        let asset = try files.writeAsset(data, prefix: prefix, suffix: "presentation.json")
        return PostcardPresentationReference(relativePath: asset.relativePath, sha256: asset.sha256)
    }

    public func load(reference: PostcardPresentationReference, event: TripEvent, expectedSourceRelativePath: String) throws -> ValidatedPresentation {
        try withValidatedPresentation(reference: reference, event: event, expectedSourceRelativePath: expectedSourceRelativePath) { value, revalidate in
            try revalidate(); return value
        }
    }

    /// Retains verified descriptors until body returns. Call revalidate inside the repository's
    /// final publication lock, immediately BEFORE persisting a reference. It never publishes itself.
    public func withValidatedPresentation<T>(reference: PostcardPresentationReference, event: TripEvent, expectedSourceRelativePath: String, body: (ValidatedPresentation, () throws -> Void) throws -> T) throws -> T {
        let sourcePath = try sourcePath(event, expectedSourceRelativePath)
        let prefix = "postcards/\(event.tripID.uuidString.lowercased())"
        try Self.checkCanonical(reference.relativePath, prefix: prefix, extensions: ["json"])
        let files = try PresentationFiles(root: root)
        let bytes = try files.read(reference.relativePath, limit: Self.maximumManifestBytes)
        guard Self.digest(bytes) == reference.sha256 else { throw PostcardPresentationError.invalidBinding }
        try StrictJSONPreflight.validate(bytes)
        let manifest = try JSONDecoder().decode(PostcardPresentationManifest.self, from: bytes)
        // Comparing the parsed JSON with its typed re-encoding rejects unknown keys at every depth.
        let original = try JSONSerialization.jsonObject(with: bytes) as AnyObject
        let canonical = try JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as AnyObject
        guard original.isEqual(canonical), manifest.schemaVersion == 1, manifest.eventID == event.id, manifest.tripID == event.tripID,
              manifest.source.relativePath == sourcePath, Data(manifest.quote.utf8) == Data(event.mood.quote.utf8),
              manifest.quoteSHA256 == Self.digest(Data(event.mood.quote.utf8)), manifest.placement.isValid,
              !manifest.styleVersion.isEmpty, manifest.styleVersion.utf8.count <= 256 else { throw PostcardPresentationError.invalidManifest }
        func readAsset(_ asset: PostcardPresentationAsset, landscape: Bool, ink: Bool) throws -> Data {
            if asset.relativePath != sourcePath { try Self.checkCanonical(asset.relativePath, prefix: prefix, extensions: ["png", "webp"]) }
            let data = try files.read(asset.relativePath == sourcePath ? Self.physicalSourcePath(sourcePath) : asset.relativePath, limit: Self.maximumImageBytes)
            guard Self.digest(data) == asset.sha256 else { throw PostcardPresentationError.invalidBinding }
            try Self.validateImage(data, path: asset.relativePath, landscape: landscape, handwriting: ink)
            return data
        }
        let source = try readAsset(manifest.source, landscape: false, ink: false)
        let landscape = try readAsset(manifest.landscape, landscape: true, ink: false)
        let handwriting: Data?
        switch manifest.handwriting {
        case let .generated(asset): handwriting = try readAsset(asset, landscape: false, ink: true)
        case .localFallback: handwriting = nil
        }
        try files.revalidate()
        return try body(ValidatedPresentation(manifest: manifest, sourceData: source, landscapeData: landscape, handwritingData: handwriting), { try files.revalidate() })
    }

    private func sourcePath(_ event: TripEvent, _ path: String) throws -> String {
        let prefix = "postcards/\(event.tripID.uuidString.lowercased())"
        if event.postcardStatus == .ready {
            guard path == event.postcardRelativePath else { throw PostcardPresentationError.invalidBinding }
            // Legacy persisted repository paths represent postcards/<directory>/<filename>.
            if path.split(separator: "/", omittingEmptySubsequences: false).count == 2 {
                let components = path.components(separatedBy: "/")
                try Self.checkCanonical("postcards/" + path, prefix: "postcards/" + components[0], extensions: ["png", "webp"])
                return path
            }
        } else { guard event.postcardStatus == .pendingImage else { throw PostcardPresentationError.invalidBinding } }
        try Self.checkCanonical(path, prefix: prefix, extensions: ["png", "webp"])
        return path
    }

    fileprivate static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func physicalSourcePath(_ path: String) -> String {
        path.components(separatedBy: "/").count == 2 ? "postcards/" + path : path
    }
    private static func checkCanonical(_ path: String, prefix: String, extensions: Set<String>) throws {
        let parts = path.components(separatedBy: "/")
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789._-".utf8)
        guard parts.count == 3, path == prefix + "/" + parts[2], parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.allSatisfy(allowed.contains) }),
              parts[2].first?.isLetter == true || parts[2].first?.isNumber == true,
              extensions.contains((parts[2] as NSString).pathExtension) else { throw PostcardPresentationError.unsafePath }
    }

    private static func validateImage(_ data: Data, path: String, landscape: Bool, handwriting: Bool) throws {
        if (path as NSString).pathExtension == "png" {
            guard data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
                  data.suffix(12).elementsEqual([0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130]) else { throw PostcardPresentationError.invalidImage }
        }
        guard !data.isEmpty, data.count <= maximumImageBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let type = CGImageSourceGetType(source) as String?,
              type == ((path as NSString).pathExtension == "png" ? "public.png" : "org.webmproject.webp"),
              !handwriting || type == "public.png",
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= PostcardGenerationContract.maximumAxis, height <= PostcardGenerationContract.maximumAxis,
              width <= PostcardGenerationContract.maximumPixels / height,
              (props[kCGImagePropertyOrientation] as? Int ?? 1) == 1,
              !landscape || PostcardGenerationContract.accepts(width: width, height: height),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
              image.width == width, image.height == height else { throw PostcardPresentationError.invalidImage }
        if handwriting {
            guard [.first, .last, .premultipliedFirst, .premultipliedLast].contains(image.alphaInfo),
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { throw PostcardPresentationError.invalidImage }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { throw PostcardPresentationError.invalidImage }
            var minimumX = width; var minimumY = height; var maximumX = -1; var maximumY = -1
            for y in 0..<height {
                for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 0 {
                    minimumX = min(minimumX, x); minimumY = min(minimumY, y)
                    maximumX = max(maximumX, x); maximumY = max(maximumY, y)
                }
            }
            guard maximumX >= minimumX, maximumY >= minimumY,
                  minimumX > 0, minimumY > 0, maximumX < width - 1, maximumY < height - 1 else { throw PostcardPresentationError.invalidImage }
        }
    }
}

/// Every parent is opened from a retained descriptor, including ancestors of root.
private final class PresentationFiles {
    private struct Entry { let fd: Int32; let parent: Int32; let name: String; let snapshot: stat; let data: Data? }
    private var entries: [Entry] = []
    private let rootFD: Int32
    init(root: URL) throws {
        guard root.isFileURL, root.path.hasPrefix("/"), !root.path.contains("/../"), !root.path.contains("/./") else { throw PostcardPresentationError.unsafePath }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw PostcardPresentationError.ioFailure }
        var initial = stat(); guard fstat(fd, &initial) == 0 else { close(fd); throw PostcardPresentationError.ioFailure }
        entries.append(Entry(fd: fd, parent: -1, name: "", snapshot: initial, data: nil))
        do {
            for component in root.path.split(separator: "/") {
                let child = openat(fd, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw PostcardPresentationError.unsafePath }
                var info = stat(); guard fstat(child, &info) == 0 else { close(child); throw PostcardPresentationError.ioFailure }
                entries.append(Entry(fd: child, parent: fd, name: String(component), snapshot: info, data: nil)); fd = child
            }
        } catch { for entry in entries { close(entry.fd) }; throw error }
        rootFD = fd
    }
    deinit { for entry in entries.reversed() { close(entry.fd) } }
    private func parent(_ path: String, create: Bool = false) throws -> (Int32, String) {
        let parts = path.components(separatedBy: "/")
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else { throw PostcardPresentationError.unsafePath }
        var fd = rootFD
        for name in parts.dropLast() {
            if create && mkdirat(fd, name, 0o700) != 0 && errno != EEXIST { throw PostcardPresentationError.ioFailure }
            let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw PostcardPresentationError.unsafePath }
            var info = stat(); guard fstat(child, &info) == 0 else { close(child); throw PostcardPresentationError.ioFailure }
            entries.append(Entry(fd: child, parent: fd, name: name, snapshot: info, data: nil)); fd = child
        }
        return (fd, parts.last!)
    }
    func ensureDirectory(_ path: String) throws { _ = try parent(path + "/placeholder", create: true) }
    func read(_ path: String, limit: Int) throws -> Data {
        let (parent, name) = try parent(path)
        let fd = openat(parent, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw PostcardPresentationError.unsafeFile }
        do {
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_size >= 0, info.st_size <= limit else { throw PostcardPresentationError.unsafeFile }
            let data = try readBounded(fd, limit: limit)
            var after = stat(); guard fstat(fd, &after) == 0, sameFile(info, after), data.count == info.st_size else { throw PostcardPresentationError.changedFile }
            entries.append(Entry(fd: fd, parent: parent, name: name, snapshot: after, data: data)); return data
        } catch { close(fd); throw error }
    }
    func writeAsset(_ data: Data, prefix: String, suffix: String) throws -> PostcardPresentationAsset {
        let path = prefix + "/" + UUID().uuidString.lowercased() + "-" + suffix
        let (parent, name) = try parent(path)
        let fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw PostcardPresentationError.ioFailure }
        defer { close(fd) }
        do {
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let n = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else { throw PostcardPresentationError.ioFailure }; offset += n
                }
            }
            guard fsync(fd) == 0, fsync(parent) == 0 else { throw PostcardPresentationError.ioFailure }
        } catch { unlinkat(parent, name, 0); throw error }
        return PostcardPresentationAsset(relativePath: path, sha256: PostcardPresentationStore.digest(data))
    }
    func revalidate() throws {
        for entry in entries {
            var info = stat(); guard fstat(entry.fd, &info) == 0 else { throw PostcardPresentationError.changedFile }
            if entry.parent >= 0 {
                var linked = stat()
                guard fstatat(entry.parent, entry.name, &linked, AT_SYMLINK_NOFOLLOW) == 0, linked.st_dev == info.st_dev, linked.st_ino == info.st_ino, linked.st_mode & S_IFMT == info.st_mode & S_IFMT else { throw PostcardPresentationError.changedFile }
            }
            if let data = entry.data {
                guard sameFile(entry.snapshot, info), info.st_nlink == 1, try readBounded(entry.fd, limit: data.count) == data else { throw PostcardPresentationError.changedFile }
                var after = stat(); guard fstat(entry.fd, &after) == 0, sameFile(info, after) else { throw PostcardPresentationError.changedFile }
            }
        }
    }
    private func sameFile(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode && a.st_nlink == b.st_nlink && a.st_size == b.st_size && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    private func readBounded(_ fd: Int32, limit: Int) throws -> Data {
        var data = Data(); var buffer = [UInt8](repeating: 0, count: min(65_536, limit + 1))
        while data.count <= limit {
            let count = pread(fd, &buffer, min(buffer.count, limit + 1 - data.count), off_t(data.count))
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw PostcardPresentationError.ioFailure }
            if count == 0 { return data }; data.append(contentsOf: buffer.prefix(count))
        }
        throw PostcardPresentationError.unsafeFile
    }
}
