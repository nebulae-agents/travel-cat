import Foundation
import Darwin
import Yams

enum AgentXDefinitionError: LocalizedError {
    case invalidDocument, unsafeReference, missingReference, unsupportedCapability, unpublished, immutableRevision, runningInstance
    var errorDescription: String? {
        switch self {
        case .invalidDocument: "定义文件格式无效、内容为空或超过大小限制。"
        case .unsafeReference: "定义只允许安全的相对文件路径，不允许链接或保留目录。"
        case .missingReference: "定义引用的文件或目录不存在，请补齐后再保存。"
        case .unsupportedCapability: "此定义要求尚未接入的运行框架、工具或执行设置。原文可保存为草稿，但不能发布执行。"
        case .unpublished: "定义尚未发布，或所选发布版本不存在。"
        case .immutableRevision: "已发布版本不可覆盖，请创建新版本。"
        case .runningInstance: "实例仍在运行，请等待或取消后再修改配置。"
        }
    }
}

/// Text files are kept verbatim; parsing never rewrites unknown frontmatter fields.
struct AgentXDefinitionDocument: Codable, Equatable, Sendable {
    var source: String
    var files: [String: String] = [:]
    var directories: [String] = []
    private static let byteLimit = 4 * 1_024 * 1_024

    func bodyText() throws -> String { try parsed().body }
    func replacingBody(_ body: String) throws -> Self {
        let parsed = try parsed()
        var copy = self
        copy.source = parsed.prefix + body
        return copy
    }
    func validate() throws {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              source.utf8.count + files.values.reduce(0, { $0 + $1.utf8.count }) <= Self.byteLimit,
              files.count + directories.count <= 1_000 else { throw AgentXDefinitionError.invalidDocument }
        let paths = ["agent.md"] + Array(files.keys) + directories
        guard Set(paths.map { $0.lowercased() }).count == paths.count else { throw AgentXDefinitionError.unsafeReference }
        for path in files.keys { guard try Self.path(path) == path else { throw AgentXDefinitionError.unsafeReference } }
        for path in directories { guard try Self.path(path) == path else { throw AgentXDefinitionError.unsafeReference } }
        let metadata = try parsed().metadata
        for key in ["soul", "arc", "guardrails"] {
            if let value = metadata[key] {
                guard let reference = value as? String else { throw AgentXDefinitionError.invalidDocument }
                let path = try Self.path(reference)
                guard files[path] != nil else { throw AgentXDefinitionError.missingReference }
            }
        }
        if let tools = metadata["tools"] as? String {
            guard files[try Self.path(tools)] != nil else { throw AgentXDefinitionError.missingReference }
        }
        if let seed = (metadata["memory"] as? [String: Any])?["seed"] as? String {
            let path = try Self.path(seed)
            guard directories.contains(path) || files[path] != nil || files.keys.contains(where: { $0.hasPrefix(path + "/") }) else { throw AgentXDefinitionError.missingReference }
        }
    }
    func executionPrompt() throws -> String {
        try validate()
        let parsed = try parsed()
        let metadata = parsed.metadata
        if let runtime = metadata["runtime"], runtime as? String != "host-text" { throw AgentXDefinitionError.unsupportedCapability }
        for key in ["tools", "mcp", "memory", "limits", "guardrails", "shared"] {
            if let value = metadata[key], !(value is NSNull) {
                if let array = value as? [Any], array.isEmpty { continue }
                if let dictionary = value as? [String: Any], dictionary.isEmpty { continue }
                throw AgentXDefinitionError.unsupportedCapability
            }
        }
        if let model = metadata["model"] as? [String: Any], !Set(model.keys).isSubset(of: ["provider", "model"]) { throw AgentXDefinitionError.unsupportedCapability }
        var parts = [parsed.body]
        for key in ["soul", "arc"] {
            if let reference = metadata[key] as? String, let content = files[try Self.path(reference)] { parts.append(content) }
        }
        let result = parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
        guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AgentXDefinitionError.invalidDocument }
        return result
    }
    private func parsed() throws -> (metadata: [String: Any], body: String, prefix: String) {
        guard source.hasPrefix("---\n") || source.hasPrefix("---\r\n") else { return ([:], source, "") }
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        guard let end = lines.indices.dropFirst().first(where: { lines[$0].trimmingCharacters(in: .whitespacesAndNewlines) == "---" }) else { throw AgentXDefinitionError.invalidDocument }
        let header = lines[1..<end].joined(separator: "\n")
        let metadata: [String: Any]
        if header.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { metadata = [:] }
        else {
            guard let parsed = try? Yams.load(yaml: header), let dictionary = parsed as? [String: Any] else { throw AgentXDefinitionError.invalidDocument }
            metadata = dictionary
        }
        let prefix = lines[...end].joined(separator: "\n") + (end < lines.count - 1 ? "\n" : "")
        let body = lines.dropFirst(end + 1).joined(separator: "\n")
        return (metadata, body, prefix)
    }
    static func path(_ value: String) throws -> String {
        var value = value
        if value.hasPrefix("./") { value.removeFirst(2) }
        if value.hasSuffix("/") { value.removeLast() }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !value.isEmpty, !value.contains("\\"), !value.contains("\0"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !["versions", "definition.yaml"].contains(String(components[0]).lowercased()) else { throw AgentXDefinitionError.unsafeReference }
        return value
    }

    /// Import bounded UTF-8 files. Link checks are repeated through anchored file descriptors.
    static func importDirectory(_ directory: URL, excluding: Set<String> = []) throws -> Self {
        let suppliedRoot = directory.standardizedFileURL
        let descriptor = open(suppliedRoot.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw AgentXDefinitionError.unsafeReference }
        defer { close(descriptor) }
        // Foundation enumeration canonicalizes /var to /private/var on macOS.
        // Normalize its display prefix only after anchoring and rejecting a linked root.
        guard let canonical = realpath(suppliedRoot.path, nil) else { throw AgentXDefinitionError.unsafeReference }
        defer { free(canonical) }
        let root = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
        var enumerationError = false
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], errorHandler: { _, _ in enumerationError = true; return false }) else { throw AgentXDefinitionError.invalidDocument }
        var files: [String: String] = [:]
        var directories: [String] = []
        var total = 0
        for case let url as URL in enumerator {
            let relative = String(url.path.dropFirst(root.path.count + 1))
            let first = relative.split(separator: "/").first.map(String.init) ?? ""
            if excluding.contains(first) { enumerator.skipDescendants(); continue }
            let path = try Self.path(relative)
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw AgentXDefinitionError.unsafeReference }
            if values.isDirectory == true { directories.append(path) }
            else {
                let data = try readFile(root: descriptor, path: path)
                total += data.count
                guard total <= byteLimit, let string = String(data: data, encoding: .utf8) else { throw AgentXDefinitionError.invalidDocument }
                files[path] = string
            }
            guard files.count + directories.count <= 1_000 else { throw AgentXDefinitionError.invalidDocument }
        }
        guard !enumerationError, let source = files.removeValue(forKey: "agent.md") else { throw AgentXDefinitionError.invalidDocument }
        let document = Self(source: source, files: files, directories: directories.sorted())
        try document.validate()
        return document
    }
    private static func readFile(root: Int32, path: String) throws -> Data {
        let components = path.split(separator: "/").map(String.init)
        var directory = dup(root)
        guard directory >= 0 else { throw AgentXDefinitionError.unsafeReference }
        defer { close(directory) }
        for component in components.dropLast() {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard next >= 0 else { throw AgentXDefinitionError.unsafeReference }
            close(directory); directory = next
        }
        guard let last = components.last else { throw AgentXDefinitionError.unsafeReference }
        let file = openat(directory, last, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard file >= 0 else { throw AgentXDefinitionError.unsafeReference }
        defer { close(file) }
        var status = stat()
        guard fstat(file, &status) == 0, status.st_mode & S_IFMT == S_IFREG, status.st_nlink == 1,
              status.st_size >= 0, status.st_size <= byteLimit else { throw AgentXDefinitionError.unsafeReference }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(file, &buffer, buffer.count)
            guard count >= 0 else { throw AgentXDefinitionError.invalidDocument }
            if count == 0 { break }
            guard data.count + count <= byteLimit else { throw AgentXDefinitionError.invalidDocument }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}

struct AgentXDefinitionRevision: Codable, Equatable, Sendable {
    var number: Int
    var document: AgentXDefinitionDocument
    var publishedAt: Date?
}
