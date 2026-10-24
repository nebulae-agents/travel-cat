import Foundation

struct WorkbenchArtifactVersion: Codable, Equatable, Identifiable, Sendable {
    let path: String
    let sha256: String
    let size: Int
    let viewedAt: Date
    var text: String?
    var reason: String?
    var id: String { path + ":" + sha256 }
}

struct WorkbenchArtifactInventory: Equatable, Sendable {
    let bindingID: String
    let executionID: String?
    let turnID: String?
    let baselineCapturedAt: Date?
    let checkedAt: Date
    let inventoryComplete: Bool
    let hashComplete: Bool
    let baselineInventoryComplete: Bool
    let baselineHashComplete: Bool
    let reason: String?
    let files: [WorkbenchArtifact]
    var notice: String {
        if baselineCapturedAt == nil { return "本次连接没有实际提交前的基线，变化状态未知。" }
        if !inventoryComplete || !hashComplete || !baselineInventoryComplete || !baselineHashComplete {
            return "扫描或 SHA 未覆盖全部文件；未核实的变化保持未知。"
        }
        return "相对实际提交前的 SHA 基线；文件变化不代表由 Agent 创建或修改。"
    }
}

enum WorkbenchArtifactText {
    static let limit = 256 * 1024
    static func decode(_ bytes: Data) -> String? {
        guard let text = String(data: bytes, encoding: .utf8),
              !text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control && ![9,10,13].contains($0.value) }) else { return nil }
        return text
    }
    static func savedText(_ preview: WorkbenchArtifactPreview) -> String? {
        let ext = (preview.artifact.path as NSString).pathExtension.lowercased()
        guard preview.bytes.count <= limit,
              !["pdf","png","jpg","jpeg","gif","tif","tiff","heic","webp","bmp"].contains(ext) else { return nil }
        return decode(preview.bytes)
    }
}

struct WorkbenchArtifactComparison: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case text, lineEndings, identical, metadata, limited }
    let kind: Kind
    let text: String
    private static let outputLimit = 256 * 1024
    static func compare(old: WorkbenchArtifactVersion?, current: WorkbenchArtifactPreview) -> Self {
        guard let old, old.path == current.artifact.path, let lhs = old.text, let rhs = WorkbenchArtifactText.savedText(current) else {
            let prior = old.map { "旧 SHA：\($0.sha256)（\($0.size) 字节）" } ?? "没有保存旧版本正文。"
            return .init(kind: .metadata, text: "\(prior)\n当前 SHA：\(current.sha256)（\(current.bytes.count) 字节）\n只能比较元数据，无法还原完整任务差异。")
        }
        if old.sha256 == current.sha256 { return .init(kind: .identical, text: "两个已查看版本的 SHA 相同。") }
        let normalize: (String) -> String = { $0.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") }
        let before = normalize(lhs), after = normalize(rhs)
        if before.utf8.elementsEqual(after.utf8) { return .init(kind: .lineEndings, text: "正文逐行相同，但换行符不同（CRLF / LF / CR）；SHA 已变化。") }
        let a = before.components(separatedBy: "\n"), b = after.components(separatedBy: "\n")
        guard lhs.utf8.count <= WorkbenchArtifactText.limit, rhs.utf8.count <= WorkbenchArtifactText.limit,
              a.count <= 2000, b.count <= 2000, a.count * b.count <= 1_000_000 else {
            return .init(kind: .limited, text: "文本比较超过 2,000 行或计算限额；请核对 SHA、大小或下载两个已查看版本。")
        }
        // Bounded LCS over saved UTF-8 only; output is plain text, including HTML.
        let aBytes = a.map { Data($0.utf8) }, bBytes = b.map { Data($0.utf8) }
        let width = b.count + 1
        var lengths = [UInt16](repeating: 0, count: (a.count + 1) * width)
        for i in (0..<a.count).reversed() {
            for j in (0..<b.count).reversed() {
                lengths[i*width+j] = aBytes[i] == bBytes[j] ? lengths[(i+1)*width+j+1]+1 : max(lengths[(i+1)*width+j],lengths[i*width+j+1])
            }
        }
        var lines = ["仅比较这两个已查看文本版本；不代表完整任务差异或作者归属。"]
        var size = lines[0].utf8.count, i = 0, j = 0
        while i < a.count || j < b.count {
            let line: String
            if i < a.count && j < b.count && aBytes[i] == bBytes[j] { line = " " + a[i]; i += 1; j += 1 }
            else if i < a.count && (j == b.count || lengths[(i+1)*width+j] >= lengths[i*width+j+1]) { line = "-" + a[i]; i += 1 }
            else { line = "+" + b[j]; j += 1 }
            size += line.utf8.count + 1
            guard size <= outputLimit else { return .init(kind: .limited,text: "差异输出超过 256 KiB，请下载已查看版本核对。") }
            lines.append(line)
        }
        if lhs.unicodeScalars.contains(where: { $0.value == 13 }) || rhs.unicodeScalars.contains(where: { $0.value == 13 }) { lines.append("比较时将 CRLF / CR 按行展开；原始下载保留原换行字节。") }
        let output = lines.joined(separator: "\n")
        guard output.utf8.count <= outputLimit else { return .init(kind: .limited,text: "差异输出超过 256 KiB，请下载已查看版本核对。") }
        return .init(kind: .text,text: output)
    }
}

extension WorkbenchSnapshot {
    func validateArtifactVersions() throws {
        var metadata = 0, bodyBytes = 0
        for task in tasks {
            let versions = task.artifactVersions ?? []
            metadata += versions.count
            guard Set(versions.map(\.path)).count <= 16, Set(versions.map(\.id)).count == versions.count else { throw WorkbenchFailure("保存的文件历史超过路径限制或有重复版本，原数据已保留。") }
            for path in Set(versions.map(\.path)) where versions.filter({ $0.path == path }).count > 2 { throw WorkbenchFailure("保存的文件历史超过每个路径两个版本，原数据已保留。") }
            for version in versions {
                try WorkbenchArtifactLimits.validate(path: version.path)
                guard WorkbenchArtifactLimits.validSHA(version.sha256), (0...WorkbenchArtifactLimits.bytes).contains(version.size), version.reason?.utf8.count ?? 0 <= 256 else { throw WorkbenchFailure("保存的文件历史元数据无效，原数据已保留。") }
                if let text = version.text {
                    let data = Data(text.utf8); bodyBytes += data.count
                    guard data.count <= WorkbenchArtifactText.limit, data.count == version.size,
                          WorkbenchArtifactText.decode(data) != nil, WorkbenchArtifactPreview.digest(data) == version.sha256 else { throw WorkbenchFailure("保存的文件历史正文校验失败，原数据已保留。") }
                }
            }
        }
        guard metadata <= 128, bodyBytes <= 2 * 1024 * 1024 else { throw WorkbenchFailure("保存的文件历史超过总限额，原数据已保留。") }
    }
}
