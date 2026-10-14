import Darwin
import Foundation
import TravelCore

public struct PostcardArtworkRevisionRequest: Codable, Sendable {
    public let eventID: UUID
    public let narrativeHash: String
    public let originalRelativePath: String
    public let relativePath: String
    public let contentHash: String

    public init(eventID: UUID, narrativeHash: String, originalRelativePath: String,
                relativePath: String, contentHash: String) {
        self.eventID = eventID; self.narrativeHash = narrativeHash
        self.originalRelativePath = originalRelativePath; self.relativePath = relativePath
        self.contentHash = contentHash
    }
}

public struct PostcardArtworkCandidate: Codable, Sendable {
    public let event: TripEvent
    public let narrativeHash: String
}

public struct PostcardArtworkRevisionData: Sendable {
    public let data: Data
    public let relativePath: String
    public let contentHash: String
}

/// Explicit artwork maintenance only. Never rewrites a published event, retry or original photo.
/// The presentation loader uses this index; a damaged revision falls back to its original.
public final class PostcardArtworkRevisionStore: @unchecked Sendable {
    private struct Revision: Codable {
        let request: PostcardArtworkRevisionRequest
        let tripID: UUID
        let installedAt: Date
    }
    private struct Index: Codable {
        var schemaVersion = 1
        var revisions: [Revision] = []
    }
    private struct Supplements: Decodable { let supplements: [TripEvent] }
    private let root: URL
    private var url: URL { root.appendingPathComponent("state/postcard-artwork-revisions.json") }

    public init(root: URL) throws { self.root = root.standardizedFileURL }

    public func candidates() throws -> [PostcardArtworkCandidate] {
        let repository = try TravelRepository(root: root, clock: SystemClock(), initialize: false)
        return try repository.withExclusiveLock {
            let stateFD = try stateDirectory()
            defer { _ = close(stateFD) }
            let published = try events(repository)
            let prepared = try repository.presentationReferencesUnlocked(events: published)
            return try published.filter {
                $0.postcardStatus == .ready && $0.postcardRelativePath != nil && prepared[$0.id] == nil
            }.map { PostcardArtworkCandidate(event: $0, narrativeHash: try NarrativeHasher.hash($0)) }
        }
    }

    public func install(_ requests: [PostcardArtworkRevisionRequest]) throws {
        guard !requests.isEmpty, Set(requests.map(\.eventID)).count == requests.count else {
            throw RepositoryError.invalidImageResult
        }
        let repository = try TravelRepository(root: root, clock: SystemClock(), initialize: false)
        try repository.withExclusiveLock {
            let stateFD = try stateDirectory()
            defer { _ = close(stateFD) }
            let published = try events(repository)
            let prepared = try repository.presentationReferencesUnlocked(events: published)
            var index = try load()
            var additions: [Revision] = []
            guard Set(requests.map(\.relativePath)).count == requests.count else { throw RepositoryError.invalidImageResult }
            for request in requests {
                let matching = published.filter { $0.id == request.eventID }
                guard matching.count == 1, let event = matching.first,
                      event.postcardStatus == .ready,
                      prepared[event.id] == nil,
                      event.postcardRelativePath == request.originalRelativePath,
                      try NarrativeHasher.hash(event) == request.narrativeHash else {
                    throw RepositoryError.invalidImageResult
                }
                guard request.relativePath != request.originalRelativePath,
                      !published.contains(where: { $0.postcardRelativePath == request.relativePath }),
                      !index.revisions.contains(where: { $0.request.relativePath == request.relativePath &&
                          ($0.request.contentHash != request.contentHash || $0.request.eventID != request.eventID) }) else {
                    throw RepositoryError.invalidImageResult
                }
                let image = try repository.validateReadyImage(request.relativePath, tripID: event.tripID)
                defer { image.closeAll() }
                guard image.hasPostcardAspectRatio, image.contentHash == request.contentHash else {
                    throw RepositoryError.invalidImageResult
                }
                try repository.requireUnchanged(image)
                additions.append(Revision(request: request, tripID: event.tripID, installedAt: Date()))
            }
            // Keep previous revisions for rollback; a repeat of the same accepted batch is a no-op.
            for revision in additions where !index.revisions.contains(where: {
                $0.request.eventID == revision.request.eventID && $0.request.relativePath == revision.request.relativePath
                    && $0.request.contentHash == revision.request.contentHash
            }) { index.revisions.append(revision) }
            try save(JSONEncoder.travelCat.encode(index))
        }
    }

    public func resolvedPath(for originalRelativePath: String) -> String {
        revisionData(for: originalRelativePath)?.relativePath ?? originalRelativePath
    }

    public func revisionIdentity(for originalRelativePath: String) -> String {
        guard let revision = revisionData(for: originalRelativePath) else { return "" }
        return revision.relativePath + "\u{0}" + revision.contentHash
    }

    /// A reload hint only. Never validates, reads or decodes the artwork pixels.
    /// Loading must still use revisionData's descriptor and integrity checks.
    public func revisionChangeToken(for originalRelativePath: String) -> String {
        let rootToken = filesystemToken(root, includeTimes: false)
        guard rootToken.isDirectory else { return rootToken.token }
        let stateToken = filesystemToken(root.appendingPathComponent("state"), includeTimes: false)
        guard stateToken.isDirectory else { return rootToken.token + "\u{0}" + stateToken.token }
        var tokens = [rootToken.token, stateToken.token, filesystemToken(url).token]
        guard let index = try? load(),
              let revision = index.revisions.last(where: { $0.request.originalRelativePath == originalRelativePath }),
              (try? TravelRepository.validateReadyImagePath(revision.request.relativePath, tripID: revision.tripID)) != nil else {
            return tokens.joined(separator: "\u{0}")
        }
        tokens.append(contentsOf: [revision.request.relativePath, revision.request.contentHash])
        let components = revision.request.relativePath.split(separator: "/")
        var path = root
        for (offset, component) in components.enumerated() {
            path.appendPathComponent(String(component))
            let isParent = offset < components.count - 1
            let metadata = filesystemToken(path, includeTimes: !isParent)
            tokens.append(metadata.token)
            // Do not follow a symlink parent merely to obtain metadata.
            if isParent && !metadata.isDirectory { break }
        }
        return tokens.joined(separator: "\u{0}")
    }

    private func filesystemToken(_ path: URL, includeTimes: Bool = true) -> (token: String, isDirectory: Bool) {
        var info = stat()
        guard lstat(path.path, &info) == 0 else { return ("unavailable:\(errno)", false) }
        var fields = [String(info.st_dev), String(info.st_ino), String(info.st_mode),
                      String(info.st_uid), String(info.st_gid)]
        if includeTimes {
            fields += [String(info.st_nlink), String(info.st_size),
                       String(info.st_mtimespec.tv_sec), String(info.st_mtimespec.tv_nsec),
                       String(info.st_ctimespec.tv_sec), String(info.st_ctimespec.tv_nsec)]
        }
        return (fields.joined(separator: ":"), info.st_mode & S_IFMT == S_IFDIR)
    }

    /// Return pixels from the same descriptor that was validated, never reopen the accepted path.
    public func revisionData(for originalRelativePath: String) -> PostcardArtworkRevisionData? {
        guard let index = try? load(),
              let revision = index.revisions.last(where: { $0.request.originalRelativePath == originalRelativePath }),
              let repository = try? TravelRepository(root: root, clock: SystemClock(), initialize: false),
              let image = try? repository.validateReadyImage(revision.request.relativePath, tripID: revision.tripID) else {
            return nil
        }
        defer { image.closeAll() }
        guard image.hasPostcardAspectRatio, image.contentHash == revision.request.contentHash,
              (try? repository.requireUnchanged(image)) != nil else { return nil }
        return PostcardArtworkRevisionData(data: image.data, relativePath: revision.request.relativePath,
            contentHash: image.contentHash)
    }

    private func events(_ repository: TravelRepository) throws -> [TripEvent] {
        let journal = try repository.readEventsUnlocked()
        let backlog = root.appendingPathComponent("state/postcard-backlog.json")
        let extra = FileManager.default.fileExists(atPath: backlog.path)
            ? try JSONDecoder.travelCat.decode(Supplements.self, from: Data(contentsOf: backlog)).supplements : []
        return journal + extra
    }

    private func load() throws -> Index {
        if !FileManager.default.fileExists(atPath: url.path) { return Index() }
        let parent = try stateDirectory()
        defer { _ = close(parent) }
        let fd = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw RepositoryError.invalidImageResult }
        defer { _ = close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_size <= 1_048_576 else { throw RepositoryError.invalidImageResult }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.read(upToCount: 1_048_577) ?? Data()
        guard data.count <= 1_048_576 else { throw RepositoryError.invalidImageResult }
        let index = try JSONDecoder.travelCat.decode(Index.self, from: data)
        guard index.schemaVersion == 1 else { throw RepositoryError.invalidImageResult }
        return index
    }

    private func stateDirectory() throws -> Int32 {
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard rootFD >= 0 else { throw RepositoryError.unsafePostcardPath }
        defer { _ = close(rootFD) }
        let stateFD = openat(rootFD, "state", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard stateFD >= 0 else { throw RepositoryError.unsafePostcardPath }
        return stateFD
    }

    private func save(_ data: Data) throws {
        let parent = try stateDirectory()
        defer { _ = close(parent) }
        let name = ".artwork-\(UUID().uuidString).tmp"
        let fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw RepositoryError.invalidImageResult }
        defer { _ = close(fd); _ = unlinkat(parent, name, 0) }
        try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: data)
        guard fsync(fd) == 0,
              renameat(parent, name, parent, url.lastPathComponent) == 0,
              fsync(parent) == 0 else { throw RepositoryError.invalidImageResult }
    }
}
