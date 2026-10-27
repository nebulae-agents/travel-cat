import Foundation

// A revision protects newer edits even when the user changes text back to its old value.
struct WorkbenchSubmissionDraft: Codable, Equatable, Sendable {
    var text = "" { didSet { revision = UUID() } }
    var files: [[String: String]] = [] { didSet { revision = UUID() } }
    var parentTaskID: UUID? { didSet { revision = UUID() } }
    private(set) var revision = UUID()

    mutating func clear(ifUnchangedSince submittedRevision: UUID) {
        guard revision == submittedRevision else { return }
        text = ""; files = []; parentTaskID = nil
    }
}

enum WorkbenchDraftTarget: Hashable, Codable, Sendable {
    case new(UUID?)
    case task(UUID)
    private enum CodingKeys: String, CodingKey { case kind, id }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "new": self = .new(try container.decodeIfPresent(UUID.self, forKey: .id))
        case "task": self = .task(try container.decode(UUID.self, forKey: .id))
        default: throw WorkbenchFailure("草稿目标无法识别，原数据已保留。")
        }
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .new(id): try container.encode("new", forKey: .kind); try container.encodeIfPresent(id, forKey: .id)
        case let .task(id): try container.encode("task", forKey: .kind); try container.encode(id, forKey: .id)
        }
    }
    fileprivate var sortKey: String {
        switch self { case let .new(id): "new:" + (id?.uuidString ?? ""); case let .task(id): "task:" + id.uuidString }
    }
}

struct WorkbenchDraftCollection: Codable, Sendable {
    private struct Record: Codable { let target: WorkbenchDraftTarget; let draft: WorkbenchSubmissionDraft }
    private var values: [WorkbenchDraftTarget: WorkbenchSubmissionDraft] = [:]
    init() {}
    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            let record = try container.decode(Record.self)
            guard values[record.target] == nil else { throw WorkbenchFailure("草稿目标重复，原数据已保留。") }
            try record.draft.validate()
            values[record.target] = record.draft
        }
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        for target in values.keys.sorted(by: { $0.sortKey < $1.sortKey }) {
            try container.encode(Record(target: target, draft: values[target]!))
        }
    }
    func validate() throws { for draft in values.values { try draft.validate() } }
    func draft(for target: WorkbenchDraftTarget) -> WorkbenchSubmissionDraft { values[target] ?? WorkbenchSubmissionDraft() }
    mutating func update(_ target: WorkbenchDraftTarget, _ change: (inout WorkbenchSubmissionDraft) -> Void) {
        var draft = self.draft(for: target)
        change(&draft)
        if draft.isEmpty { values.removeValue(forKey: target) } else { values[target] = draft }
    }
    mutating func clear(_ target: WorkbenchDraftTarget, submittedRevision: UUID) {
        guard values[target]?.revision == submittedRevision else { return }
        values.removeValue(forKey: target)
    }
}

extension WorkbenchSubmissionDraft {
    var isEmpty: Bool { text.isEmpty && files.isEmpty && parentTaskID == nil }
    func validate() throws {
        guard text.count <= 100_000, text.utf8.count <= 512 * 1024 else {
            throw WorkbenchFailure("草稿正文超过 100,000 字符或 512 KiB，未保存；请缩短后重试。")
        }
        try Self.validateFiles(files)
    }
    static func validateFiles(_ files: [[String: String]]) throws {
        func failure() -> WorkbenchFailure { WorkbenchFailure("草稿文件无效或超限，未保存；请检查文件名与内容后重试。") }
        guard files.count <= 32 else { throw failure() }
        var seen = Set<String>(), total = 0
        for file in files {
            guard Set(file.keys) == Set(["name", "base64"]), let name = file["name"],
                  !name.isEmpty, name.utf8.count <= 200, !name.hasPrefix("."),
                  !name.contains("/"), !name.contains("\\"), !name.unicodeScalars.contains(where: { $0.value < 32 }),
                  seen.insert(name).inserted, let encoded = file["base64"], encoded.utf8.count <= 1024 * 1024 * 4 / 3 + 4,
                  let bytes = Data(base64Encoded: encoded), bytes.count <= 1024 * 1024 else { throw failure() }
            let lower = name.lowercased()
            guard !["key", "secret", "credential", "token", "id_rsa", "id_ed25519"].contains(where: lower.contains),
                  ![".pem", ".p12", ".pfx"].contains(where: lower.hasSuffix) else { throw failure() }
            total += bytes.count
            guard total <= 4 * 1024 * 1024 else { throw failure() }
        }
    }
}
