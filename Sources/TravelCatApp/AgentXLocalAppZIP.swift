import Foundation
import Darwin

/// Strict ZIP subset: single-disk ZIP32, UTF-8 names, stored/deflated regular files,
/// optional ordinary directories. No extraction writes into either source or live root.
enum AgentXLocalAppZIP {
    struct Entry {
        let name: String
        let directory: Bool
        let method: Int
        let compressedSize: Int
        let size: Int
        let crc: UInt32
        let payload: Range<Int>
    }
    static func read(_ url: URL) throws -> Data {
        _ = try AgentXPackageFiles.safeURL(url.lastPathComponent, root: url.deletingLastPathComponent())
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw AgentXError.unsafePath }
        defer { close(fd) }
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFREG, status.st_nlink == 1,
              status.st_size >= 0, status.st_size <= AgentXPackageFiles.maximumBytes else { throw AgentXError.unsafePath }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count >= 0 else { throw AgentXError.corrupt }
            if count == 0 { break }
            guard data.count + count <= AgentXPackageFiles.maximumBytes else { throw AgentXError.invalid("ZIP 超过 8 MiB 上限。") }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
    static func files(_ data: Data) throws -> [String: Data] {
        let entries = try entries(data)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("AgentX-ZIP-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let archive = temporary.appendingPathComponent("reviewed.zip")
        try data.write(to: archive, options: .atomic)
        var files: [String: Data] = [:]
        for entry in entries where !entry.directory {
            let bytes: Data
            if entry.method == 0 { bytes = data.subdata(in: entry.payload) }
            else { bytes = try inflate(archive, entry: entry) }
            guard bytes.count == entry.size, crc32(bytes) == entry.crc else { throw AgentXError.invalid("ZIP 数据校验失败。") }
            files[entry.name] = bytes
        }
        return files
    }
    static func entries(_ data: Data) throws -> [Entry] {
        guard data.count >= 22, data.count <= AgentXPackageFiles.maximumBytes else { throw AgentXError.corrupt }
        func value(_ offset: Int, _ count: Int) throws -> Int {
            guard offset >= 0, offset <= data.count - count else { throw AgentXError.corrupt }
            return (0..<count).reduce(0) { $0 | (Int(data[offset + $1]) << (8 * $1)) }
        }
        func extra(_ offset: Int, _ length: Int) throws {
            guard offset >= 0, length >= 0, offset <= data.count - length else { throw AgentXError.corrupt }
            var position = offset
            while position < offset + length {
                guard position + 4 <= offset + length else { throw AgentXError.corrupt }
                let type = try value(position, 2), size = try value(position + 2, 2)
                // Reject UNIX link fields, ZIP64, Unicode name overrides and encryption metadata.
                guard [0x5455, 0x7875].contains(type), position + 4 + size <= offset + length else { throw AgentXError.invalid("ZIP 包含不支持的扩展字段。") }
                position += 4 + size
            }
        }
        let lower = max(0, data.count - 22 - 65535)
        let end: Int? = stride(from: data.count - 22, through: lower, by: -1).first { offset in
            guard let signature = try? value(offset, 4), signature == 0x06054b50,
                  let commentSize = try? value(offset + 20, 2) else { return false }
            return offset + 22 + commentSize == data.count
        }
        guard let end else { throw AgentXError.corrupt }
        let count = try value(end + 10, 2), centralSize = try value(end + 12, 4), central = try value(end + 16, 4)
        guard try value(end + 4, 2) == 0, try value(end + 6, 2) == 0, try value(end + 8, 2) == count,
              count > 0, count <= AgentXPackageFiles.maximumEntries, central + centralSize == end else { throw AgentXError.invalid("不支持分卷、ZIP64 或超量条目的 ZIP。") }
        var cursor = central, seen = Set<String>(), total = 0, entries: [Entry] = [], localRanges: [Range<Int>] = []
        for _ in 0..<count {
            guard try value(cursor, 4) == 0x02014b50 else { throw AgentXError.corrupt }
            let platform = try value(cursor + 5, 1), flags = try value(cursor + 8, 2), method = try value(cursor + 10, 2)
            let crc = UInt32(try value(cursor + 16, 4)), compressed = try value(cursor + 20, 4), size = try value(cursor + 24, 4)
            let nameSize = try value(cursor + 28, 2), extraSize = try value(cursor + 30, 2), commentSize = try value(cursor + 32, 2)
            let attributes = try value(cursor + 38, 4), local = try value(cursor + 42, 4)
            let next = cursor + 46 + nameSize + extraSize + commentSize
            guard next <= end, nameSize > 0, nameSize <= 512, [0, 3].contains(platform), flags & ~0x080e == 0,
                  flags & 1 == 0, [0, 8].contains(method), try value(cursor + 34, 2) == 0,
                  compressed <= AgentXPackageFiles.maximumBytes, size <= AgentXPackageFiles.maximumBytes,
                  size <= max(compressed * 100, 1024), local < central else { throw AgentXError.invalid("ZIP 条目类型、加密或解压大小不受支持。") }
            let nameBytes = data.subdata(in: cursor + 46..<cursor + 46 + nameSize)
            guard let name = String(data: nameBytes, encoding: .utf8) else { throw AgentXError.unsafePath }
            let directory = name.hasSuffix("/")
            let path = directory ? String(name.dropLast()) : name
            try AgentXPackageFiles.validatePath(path)
            let folded = path.precomposedStringWithCanonicalMapping.lowercased()
            guard seen.insert(folded).inserted else { throw AgentXError.invalid("ZIP 包含大小写或 Unicode 重复路径。") }
            let mode = (attributes >> 16) & 0xf000
            guard mode == 0 || mode == (directory ? 0x4000 : 0x8000),
                  (attributes & 0x10 == 0 || directory), !directory || size == 0 else { throw AgentXError.unsafePath }
            try extra(cursor + 46 + nameSize, extraSize)
            guard try value(local, 4) == 0x04034b50, try value(local + 6, 2) == flags, try value(local + 8, 2) == method,
                  try value(local + 26, 2) == nameSize else { throw AgentXError.corrupt }
            let localExtraSize = try value(local + 28, 2), payloadStart = local + 30 + nameSize + localExtraSize
            guard payloadStart <= central, payloadStart + compressed <= central,
                  data.subdata(in: local + 30..<local + 30 + nameSize) == nameBytes else { throw AgentXError.corrupt }
            try extra(local + 30 + nameSize, localExtraSize)
            if flags & 8 == 0 {
                guard try value(local + 14, 4) == Int(crc), try value(local + 18, 4) == compressed, try value(local + 22, 4) == size else { throw AgentXError.corrupt }
            }
            guard method != 0 || size == compressed else { throw AgentXError.corrupt }
            var rangeEnd = payloadStart + compressed
            if flags & 8 != 0 {
                if try value(rangeEnd, 4) == 0x08074b50 { rangeEnd += 4 }
                guard rangeEnd + 12 <= central, try value(rangeEnd, 4) == Int(crc), try value(rangeEnd + 4, 4) == compressed, try value(rangeEnd + 8, 4) == size else { throw AgentXError.corrupt }
                rangeEnd += 12
            }
            let range = local..<rangeEnd
            guard !localRanges.contains(where: { $0.overlaps(range) }) else { throw AgentXError.corrupt }
            localRanges.append(range)
            total += size
            guard total <= AgentXPackageFiles.maximumBytes else { throw AgentXError.invalid("ZIP 解压总量超过 8 MiB。") }
            let payload: Range<Int> = payloadStart..<(payloadStart + compressed)
            entries.append(Entry(name: path, directory: directory, method: method,
                                 compressedSize: compressed, size: size, crc: crc, payload: payload))
            cursor = next
        }
        guard cursor == end else { throw AgentXError.corrupt }
        // No hidden local records, executable prefix, or concatenated archives.
        var expected = 0
        for range in localRanges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            guard range.lowerBound == expected else { throw AgentXError.corrupt }; expected = range.upperBound
        }
        guard expected == central else { throw AgentXError.corrupt }
        for entry in entries where !entry.directory {
            let prefix = entry.name.precomposedStringWithCanonicalMapping.lowercased() + "/"
            guard !seen.contains(where: { $0.hasPrefix(prefix) }) else { throw AgentXError.unsafePath }
        }
        return entries
    }
    private static func inflate(_ archive: URL, entry: Entry) throws -> Data {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xOf", archive.path, "--", entry.name]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
        try process.run()
        // The archive and advertised output are bounded before launching. Also bound wall time
        // and actual stdout in case the system decompressor encounters malformed input.
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
        defer { timeout.cancel(); if process.isRunning { process.terminate() }; try? output.fileHandleForReading.close() }
        var data = Data()
        while let chunk = try output.fileHandleForReading.read(upToCount: 16_384), !chunk.isEmpty {
            guard data.count + chunk.count <= entry.size else { process.terminate(); throw AgentXError.invalid("ZIP 实际解压大小超限。") }
            data.append(chunk)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw AgentXError.invalid("ZIP 解压失败或超过时间限制。") }
        return data
    }
    private static let crcTable: [UInt32] = (0..<256).map { input in
        var crc = UInt32(input)
        for _ in 0..<8 { crc = crc & 1 == 0 ? crc >> 1 : (crc >> 1) ^ 0xedb88320 }
        return crc
    }
    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data { crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 0xff)] }
        return crc ^ 0xffffffff
    }
}
