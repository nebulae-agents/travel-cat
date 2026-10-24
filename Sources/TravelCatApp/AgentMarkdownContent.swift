import Foundation

/// Read-only presentation ranges, always measured in the original source's UTF-8 bytes.
struct AgentMarkdownContent: Equatable {
    static let maximumUTF8Bytes = 128 * 1024
    static let maximumBlocks = 512
    static let previewUTF8Bytes = 8 * 1024

    enum Kind: Equatable {
        case text
        case listItem(marker: String, indentation: Int)
        case code(language: String, closed: Bool)
    }
    struct Block: Equatable, Identifiable {
        let kind: Kind
        let sourceRange: Range<Int>
        let contentRange: Range<Int>
        var id: Int { sourceRange.lowerBound }
    }
    let source: String
    let blocks: [Block]
    let isDegraded: Bool
    let preview: String

    func text(in range: Range<Int>) -> String {
        String(decoding: source.utf8.dropFirst(range.lowerBound).prefix(range.count), as: UTF8.self)
    }

    static func parse(_ source: String) -> Self {
        // Never allocate a byte array proportional to an oversized raw message.
        let bytes = Array(source.utf8.prefix(maximumUTF8Bytes + 1))
        guard bytes.count <= maximumUTF8Bytes else { return degraded(source) }
        let lines = lines(in: bytes)
        var blocks: [Block] = [], index = 0
        while index < lines.count {
            let line = lines[index]
            if let fence = openingFence(line, in: bytes) {
                var end = index + 1
                while end < lines.count, !closes(lines[end], fence: fence, in: bytes) { end += 1 }
                let closed = end < lines.count
                blocks.append(.init(kind: .code(language: fence.language, closed: closed),
                    sourceRange: line.start..<(closed ? lines[end].end : bytes.count),
                    contentRange: line.end..<(closed ? lines[end].start : bytes.count)))
                index = closed ? end + 1 : lines.count
            } else if let item = listItem(line, in: bytes) {
                var end = index + 1
                while end < lines.count {
                    let next = lines[end]
                    if listItem(next, in: bytes) != nil || openingFence(next, in: bytes) != nil { break }
                    let indent = indentation(next, in: bytes)
                    if indent.offset < next.bodyEnd && indent.columns <= item.indentation { break }
                    end += 1
                }
                blocks.append(.init(kind: .listItem(marker: item.marker, indentation: item.indentation),
                    sourceRange: line.start..<lines[end - 1].end,
                    contentRange: item.bodyStart..<lines[end - 1].end))
                index = end
            } else {
                var end = index + 1
                while end < lines.count, openingFence(lines[end], in: bytes) == nil, listItem(lines[end], in: bytes) == nil { end += 1 }
                let range = line.start..<lines[end - 1].end
                blocks.append(.init(kind: .text, sourceRange: range, contentRange: range))
                index = end
            }
            guard blocks.count <= maximumBlocks else { return degraded(source) }
        }
        return .init(source: source, blocks: blocks, isDegraded: false, preview: "")
    }

    private struct Line { let start: Int; let bodyEnd: Int; let end: Int }
    private struct Fence { let character: UInt8; let count: Int; let language: String }
    private struct ListItem { let marker: String; let indentation: Int; let bodyStart: Int }

    private static func lines(in bytes: [UInt8]) -> [Line] {
        var result: [Line] = [], start = 0
        while start < bytes.count {
            var end = start
            while end < bytes.count, bytes[end] != 10, bytes[end] != 13 { end += 1 }
            let bodyEnd = end
            if end < bytes.count {
                if bytes[end] == 13, end + 1 < bytes.count, bytes[end + 1] == 10 { end += 2 }
                else { end += 1 }
            }
            result.append(.init(start: start, bodyEnd: bodyEnd, end: end)); start = end
        }
        return result
    }

    private static func indentation(_ line: Line, in bytes: [UInt8]) -> (offset: Int, columns: Int) {
        var offset = line.start, columns = 0
        while offset < line.bodyEnd {
            if bytes[offset] == 32 { columns += 1 }
            else if bytes[offset] == 9 { columns += 4 - columns % 4 }
            else { break }
            offset += 1
        }
        return (offset, columns)
    }

    private static func listItem(_ line: Line, in bytes: [UInt8]) -> ListItem? {
        let indent = indentation(line, in: bytes)
        var end = indent.offset
        guard end < line.bodyEnd else { return nil }
        if [45, 43, 42].contains(bytes[end]) { end += 1 }
        else {
            while end < line.bodyEnd, (48...57).contains(bytes[end]), end - indent.offset < 9 { end += 1 }
            guard end > indent.offset, end < line.bodyEnd, bytes[end] == 46 || bytes[end] == 41 else { return nil }
            end += 1
        }
        guard end < line.bodyEnd, bytes[end] == 32 || bytes[end] == 9 else { return nil }
        let markerEnd = end
        while end < line.bodyEnd, bytes[end] == 32 || bytes[end] == 9 { end += 1 }
        return .init(marker: String(decoding: bytes[indent.offset..<markerEnd], as: UTF8.self), indentation: indent.columns, bodyStart: end)
    }

    private static func openingFence(_ line: Line, in bytes: [UInt8]) -> Fence? {
        var start = line.start
        while start < line.bodyEnd, bytes[start] == 32 { start += 1 }
        guard start - line.start <= 3, start < line.bodyEnd, bytes[start] == 96 || bytes[start] == 126 else { return nil }
        let character = bytes[start]
        var end = start
        while end < line.bodyEnd, bytes[end] == character { end += 1 }
        guard end - start >= 3 else { return nil }
        let info = bytes[end..<line.bodyEnd]
        guard character != 96 || !info.contains(96) else { return nil }
        return .init(character: character, count: end - start,
            language: String(decoding: info, as: UTF8.self).trimmingCharacters(in: .whitespaces))
    }

    private static func closes(_ line: Line, fence: Fence, in bytes: [UInt8]) -> Bool {
        var start = line.start
        while start < line.bodyEnd, bytes[start] == 32 { start += 1 }
        guard start - line.start <= 3 else { return false }
        var end = start
        while end < line.bodyEnd, bytes[end] == fence.character { end += 1 }
        return end - start >= fence.count && bytes[end..<line.bodyEnd].allSatisfy { $0 == 32 || $0 == 9 }
    }

    private static func degraded(_ source: String) -> Self {
        var prefix = Array(source.utf8.prefix(previewUTF8Bytes))
        // A UTF-8 prefix can end within at most one scalar. Do not insert replacement characters.
        while String(bytes: prefix, encoding: .utf8) == nil { prefix.removeLast() }
        return .init(source: source, blocks: [], isDegraded: true, preview: String(decoding: prefix, as: UTF8.self))
    }
}
