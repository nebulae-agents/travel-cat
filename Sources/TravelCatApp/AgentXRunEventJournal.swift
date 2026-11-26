import CoreFoundation
import Darwin
import Foundation
import TravelStorage

/// The desktop writer owns the root lease for the entire lifetime of this journal.
final class AgentXRunEventJournal {
    typealias Fields = [String: Any]
    private struct Head: Codable, Equatable {
        let version: Int
        let app: String
        var sequence: Int
        var segment: Int
        var count: Int
        var offset: Int
        var tip: String
    }

    private let root: URL
    private let appID: String
    private let seal: URL
    private let directory: URL
    private var head: Head?
    private var snapshots: [String: Fields] = [:]
    private static let recordsPerSegment = 64
    private static let segmentBytes = 1 << 20

    init(root: URL, appID: String) throws {
        try AgentXPackageFiles.validateID(appID)
        self.root = root
        self.appID = appID
        seal = try AgentXPackageFiles.safeURL("apps/\(appID)/.run-journal-v1", root: root)
        directory = try AgentXPackageFiles.safeURL("apps/\(appID)/events/run-journal", root: root)
    }

    func load(legacy: () throws -> [String: Fields]) throws -> [String: Fields] {
        head = nil
        snapshots = [:]
        let events = directory.deletingLastPathComponent()
        var parent = root
        for part in ["apps", appID, "events"] {
            let child = parent.appendingPathComponent(part)
            if mkdir(child.path, 0o700) == 0 {
                try Self.syncDirectory(parent)
            } else if errno != EEXIST { throw AgentXError.unavailable }
            try Self.checkDirectory(child)
            parent = child
        }

        let sealedBase = try readSeal()
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            guard errno == ENOENT else { throw AgentXError.unsafePath }
            guard sealedBase == nil else { throw AgentXError.corrupt }
            let imported = try legacy()
            try validate(imported)
            // A single rename publishes both base and head, including an empty migration.
            // A killed process may leave a private, unreferenced staging directory.
            let stage = events.appendingPathComponent(".bootstrap-" + UUID().uuidString)
            guard mkdir(stage.path, 0o700) == 0 else { throw AgentXError.unavailable }
            defer { try? FileManager.default.removeItem(at: stage) }
            let baseline: Fields = ["version": 1, "app": appID, "runs": imported]
            let bytes = try Self.encode(baseline)
            let initial = initialHead(base: bytes)
            try AtomicFileWriter().write(bytes, to: stage.appendingPathComponent("base.json"))
            try AtomicFileWriter().write(JSONEncoder().encode(initial), to: stage.appendingPathComponent("head.json"))
            guard renameatx_np(AT_FDCWD, stage.path, AT_FDCWD, directory.path, UInt32(RENAME_EXCL)) == 0 else {
                throw AgentXError.unavailable
            }
            try Self.syncDirectory(events)
            try writeSeal(base: initial.tip)
            head = initial
            snapshots = imported
            return imported
        }

        try Self.checkDirectory(directory, privateOnly: true)
        let baseline = try Self.read(directory.appendingPathComponent("base.json"))
        guard let base = try JSONSerialization.jsonObject(with: baseline) as? Fields,
              Self.integer(base["version"]) == 1, base["app"] as? String == appID,
              let imported = base["runs"] as? [String: Fields] else { throw AgentXError.corrupt }
        try validate(imported)
        var restored = imported
        var cursor = initialHead(base: baseline)
        let baseDigest = cursor.tip
        guard sealedBase == nil || sealedBase == baseDigest else { throw AgentXError.corrupt }
        let committed = try readHead()
        guard committed.version == 1, committed.app == appID, committed.sequence >= 0,
              committed.segment >= 0, committed.segment <= committed.sequence,
              (0...Self.recordsPerSegment).contains(committed.count), committed.offset >= 0 else { throw AgentXError.corrupt }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        var segments: [Int] = []
        for name in files where name != "head.json" && name != "base.json" {
            if name.hasPrefix("."), name.hasSuffix(".tmp"), UUID(uuidString: String(name.dropFirst().dropLast(4))) != nil { continue }
            guard let match = name.wholeMatch(of: /segment-([0-9]{8,})\.jsonl/), let number = Int(match.1),
                  number > 0, segmentFile(number).lastPathComponent == name else { throw AgentXError.corrupt }
            segments.append(number)
        }
        let sorted = segments.sorted()
        guard committed.segment <= sorted.count, sorted.count - committed.segment <= 1,
              sorted.enumerated().allSatisfy({ $0.offset + 1 == $0.element }) else { throw AgentXError.corrupt }

        for number in sorted.prefix(committed.segment) {
            let file = segmentFile(number)
            let boundary = number == committed.segment ? committed.offset : nil
            let bytes = try Self.read(file, limit: boundary)
            guard bytes.last == 10 else { throw AgentXError.corrupt }
            cursor.segment = number
            cursor.count = 0
            cursor.offset = 0
            for row in bytes.dropLast().split(separator: 10, omittingEmptySubsequences: false) {
                guard cursor.count < Self.recordsPerSegment else { throw AgentXError.corrupt }
                try apply(Data(row), cursor: &cursor, to: &restored)
            }
        }
        guard cursor == committed else { throw AgentXError.corrupt }
        try validate(restored)
        // Only discard bytes beyond a verified durable commit pointer. A truncated
        // committed record is a storage error and must never be silently rolled back.
        if committed.segment > 0 { try Self.trim(segmentFile(committed.segment), to: committed.offset) }
        if let last = sorted.last, last > committed.segment { try Self.trim(segmentFile(last), to: 0) }
        if sealedBase == nil { try writeSeal(base: baseDigest) }
        head = committed
        snapshots = restored
        return restored
    }

    func append(id: String, previous: Fields?, fields: Fields) throws {
        guard let committed = head else { throw AgentXError.unavailable }
        var next = committed
        guard JSONSerialization.isValidJSONObject(fields) else { throw AgentXError.corrupt }
        let prior = snapshots[id]
        let revision = try validateIdentity(id, fields)
        if let prior {
            guard let previous, let priorRevision = Self.integer(prior["revision"]), priorRevision < Int.max,
                  try validateIdentity(id, previous) == priorRevision, revision == priorRevision + 1 else { throw AgentXError.corrupt }
        } else {
            guard previous == nil, (0...1).contains(revision),
                  !snapshots.keys.contains(where: { $0.caseInsensitiveCompare(id) == .orderedSame }) else { throw AgentXError.corrupt }
        }
        guard next.sequence < Int.max else { throw AgentXError.corrupt }
        var record = try delta(from: prior ?? [:], to: fields)
        if let event = record["event"] as? Fields { try validateEvent(event, id: id, revision: revision) }
        // Only changed model fields need type checking. The preceding projection
        // was already validated, and growing response suffixes are typed strings.
        var changed = record["set"] as? Fields ?? [:]
        changed["appID"] = appID
        changed["id"] = id
        changed["revision"] = revision
        _ = try AgentXRun.serviceProjection(changed)
        record["version"] = 1
        record["app"] = appID
        record["run"] = id
        record["revision"] = revision
        record["sequence"] = next.sequence + 1
        record["parent"] = next.tip
        let bytes = try Self.encode(record)
        var line = bytes
        line.append(10)
        let rotate = next.segment == 0 || next.count >= Self.recordsPerSegment ||
            next.offset > Self.segmentBytes - min(line.count, Self.segmentBytes)
        if rotate {
            next.segment += 1
            next.offset = 0
            next.count = 0
        }
        // A failed fsync or rename can have an ambiguous outcome. Require a full
        // replay before any further writes, even when the caller retries in-process.
        head = nil
        _ = try AgentXPackageFiles.safeURL("apps/\(appID)/events/run-journal", root: root)
        try Self.checkDirectory(directory, privateOnly: true)
        guard try readHead() == committed else { throw AgentXError.corrupt }
        if rotate {
            let file = segmentFile(next.segment)
            var info = stat()
            if lstat(file.path, &info) == 0 {
                try Self.trim(file, to: 0)
            } else if errno != ENOENT { throw AgentXError.unsafePath }
            try AtomicFileWriter().write(line, to: file)
        } else {
            let fd = try Self.openFile(segmentFile(next.segment), O_WRONLY | O_APPEND)
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            guard try handle.seekToEnd() == UInt64(next.offset) else { throw AgentXError.corrupt }
            try handle.write(contentsOf: line)
            try handle.synchronize()
            try handle.close()
        }
        next.sequence += 1
        next.count += 1
        next.offset += line.count
        next.tip = AgentXPackageFiles.digest(bytes)
        try AtomicFileWriter().write(JSONEncoder().encode(next), to: directory.appendingPathComponent("head.json"))
        head = next
        snapshots[id] = fields
    }

    private func segmentFile(_ number: Int) -> URL {
        directory.appendingPathComponent(String(format: "segment-%08lld.jsonl", Int64(number)))
    }

    private func readSeal() throws -> String? {
        var info = stat()
        if lstat(seal.path, &info) != 0 {
            guard errno == ENOENT else { throw AgentXError.unsafePath }
            return nil
        }
        guard let marker = try JSONSerialization.jsonObject(with: Self.read(seal)) as? Fields,
              Self.integer(marker["version"]) == 1, marker["app"] as? String == appID,
              let digest = marker["baseDigest"] as? String,
              digest.wholeMatch(of: /[0-9a-f]{64}/) != nil else { throw AgentXError.corrupt }
        return digest
    }

    private func writeSeal(base digest: String) throws {
        try AtomicFileWriter().write(Self.encode(["version": 1, "app": appID, "baseDigest": digest]), to: seal)
    }

    private func readHead() throws -> Head {
        try JSONDecoder().decode(Head.self, from: Self.read(directory.appendingPathComponent("head.json")))
    }

    private func initialHead(base: Data) -> Head {
        .init(version: 1, app: appID, sequence: 0, segment: 0, count: 0, offset: 0, tip: AgentXPackageFiles.digest(base))
    }

    private func validateIdentity(_ id: String, _ fields: Fields) throws -> Int {
        guard id.wholeMatch(of: /[A-Za-z0-9_-]{1,100}/) != nil,
              fields["id"] as? String == id, fields["appID"] as? String == appID,
              let revision = Self.integer(fields["revision"]), revision >= 0 else { throw AgentXError.corrupt }
        return revision
    }

    private func validate(_ runs: [String: Fields]) throws {
        var ids = Set<String>()
        for (id, fields) in runs {
            guard ids.insert(id.lowercased()).inserted else { throw AgentXError.corrupt }
            _ = try validateIdentity(id, fields)
            _ = try AgentXRun.serviceProjection(fields)
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Int(number.stringValue)
    }

    private static func encode(_ fields: Fields) throws -> Data {
        try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    }

    private static let identityKeys: Set<String> = ["id", "appID", "revision"]

    private static func equal(_ a: Any?, _ b: Any?) throws -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        if let a = a as? String, let b = b as? String { return a.utf8.elementsEqual(b.utf8) }
        // JSON booleans and numbers can compare equal after bridging to NSNumber.
        return try JSONSerialization.data(withJSONObject: [a], options: [.sortedKeys]) ==
            JSONSerialization.data(withJSONObject: [b], options: [.sortedKeys])
    }

    private func delta(from old: Fields, to new: Fields) throws -> Fields {
        var patch: Fields = [:], set: Fields = [:]
        let removed = Set(old.keys).subtracting(new.keys).sorted()
        guard !removed.contains("events"), !removed.contains("auditOutbox") else { throw AgentXError.corrupt }
        if !removed.isEmpty { patch["unset"] = removed }
        for (key, value) in new where !Self.identityKeys.contains(key) {
            if key == "events" {
                guard let events = value as? [Any] else { throw AgentXError.corrupt }
                let before = old[key] as? [Any] ?? []
                if let last = events.last as? Fields, events.count <= Self.recordsPerSegment,
                   try Self.equal(Array(events.dropLast()), Array(before.suffix(63))) {
                    patch["event"] = last
                } else if try !Self.equal(old[key], value) {
                    guard old[key] == nil, events.isEmpty else { throw AgentXError.corrupt }
                    set[key] = events
                }
            } else if key == "auditOutbox" {
                guard let outbox = value as? [Fields] else { throw AgentXError.corrupt }
                let before = old[key] as? [Fields] ?? []
                guard outbox.count >= before.count, try Self.equal(Array(outbox.prefix(before.count)), before) else {
                    throw AgentXError.corrupt
                }
                if outbox.count > before.count || old[key] == nil { patch["auditAppend"] = Array(outbox.dropFirst(before.count)) }
            } else if key == "response", let before = old[key] as? String, let after = value as? String,
                      after.utf8.starts(with: before.utf8) {
                let suffix = after.utf8.dropFirst(before.utf8.count)
                if !suffix.isEmpty { patch["responseAppend"] = String(decoding: suffix, as: UTF8.self) }
            } else if try !Self.equal(old[key], value) {
                set[key] = value
            }
        }
        if !set.isEmpty { patch["set"] = set }
        return patch
    }

    private func validateEvent(_ event: Fields, id: String, revision: Int) throws {
        guard event["runId"] as? String == id, event["eventId"] as? String == "\(id):\(revision)",
              Self.integer(event["revision"]) == revision else { throw AgentXError.corrupt }
    }

    private func apply(_ bytes: Data, cursor: inout Head, to restored: inout [String: Fields]) throws {
        guard let row = try JSONSerialization.jsonObject(with: bytes) as? Fields,
              Self.integer(row["version"]) == 1, row["app"] as? String == appID,
              cursor.sequence < Int.max, Self.integer(row["sequence"]) == cursor.sequence + 1,
              row["parent"] as? String == cursor.tip, let id = row["run"] as? String,
              let revision = Self.integer(row["revision"]) else { throw AgentXError.corrupt }
        let allowed = ["version", "app", "run", "revision", "sequence", "parent", "set", "unset", "event", "auditAppend", "responseAppend"]
        guard Set(row.keys).isSubset(of: allowed) else { throw AgentXError.corrupt }
        var fields = restored[id] ?? [:]
        if let previous = restored[id] {
            guard let prior = Self.integer(previous["revision"]), prior < Int.max, revision == prior + 1 else { throw AgentXError.corrupt }
        } else if !(0...1).contains(revision) { throw AgentXError.corrupt }

        var affected = Set<String>()
        if let removed = row["unset"] {
            guard let keys = removed as? [String] else { throw AgentXError.corrupt }
            for key in keys {
                guard affected.insert(key).inserted, fields.removeValue(forKey: key) != nil else { throw AgentXError.corrupt }
            }
        }
        if let changed = row["set"] {
            guard let values = changed as? Fields else { throw AgentXError.corrupt }
            for (key, value) in values {
                guard affected.insert(key).inserted else { throw AgentXError.corrupt }
                fields[key] = value
            }
        }
        if let value = row["event"] {
            guard affected.insert("events").inserted, let event = value as? Fields else { throw AgentXError.corrupt }
            try validateEvent(event, id: id, revision: revision)
            fields["events"] = Array((fields["events"] as? [Any] ?? []).suffix(63)) + [event]
        }
        if let value = row["auditAppend"] {
            guard affected.insert("auditOutbox").inserted, let entries = value as? [Fields] else { throw AgentXError.corrupt }
            fields["auditOutbox"] = (fields["auditOutbox"] as? [Fields] ?? []) + entries
        }
        if let value = row["responseAppend"] {
            guard affected.insert("response").inserted, let suffix = value as? String,
                  let before = fields["response"] as? String else { throw AgentXError.corrupt }
            fields["response"] = before + suffix
        }
        guard affected.isDisjoint(with: Self.identityKeys) else { throw AgentXError.corrupt }
        fields["appID"] = appID
        fields["id"] = id
        fields["revision"] = revision
        _ = try validateIdentity(id, fields)
        restored[id] = fields
        cursor.sequence += 1
        cursor.count += 1
        cursor.offset += bytes.count + 1
        cursor.tip = AgentXPackageFiles.digest(bytes)
    }

    private static func checkDirectory(_ url: URL, privateOnly: Bool = false) throws {
        var info = stat()
        let forbidden: mode_t = privateOnly ? 0o077 : 0o022
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & forbidden == 0 else { throw AgentXError.unsafePath }
    }

    private static func openFile(_ url: URL, _ flags: Int32) throws -> Int32 {
        let fd = open(url.path, flags | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw AgentXError.unsafePath }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            close(fd)
            throw AgentXError.unsafePath
        }
        return fd
    }

    private static func read(_ url: URL, limit: Int? = nil) throws -> Data {
        let fd = try openFile(url, O_RDONLY)
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        if let limit {
            var size = stat()
            guard fstat(fd, &size) == 0, size.st_size >= limit else { throw AgentXError.corrupt }
            var result = Data()
            while result.count < limit {
                guard let part = try file.read(upToCount: min(1 << 20, limit - result.count)), !part.isEmpty else { throw AgentXError.corrupt }
                result.append(part)
            }
            return result
        }
        return try file.readToEnd() ?? Data()
    }

    private static func trim(_ url: URL, to length: Int) throws {
        let fd = try openFile(url, O_RDWR)
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size >= length else { throw AgentXError.corrupt }
        if info.st_size > length {
            guard ftruncate(fd, off_t(length)) == 0, fsync(fd) == 0 else { throw AgentXError.unavailable }
        }
    }

    private static func syncDirectory(_ directory: URL) throws {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw AgentXError.unsafePath }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw AgentXError.unavailable }
    }
}
