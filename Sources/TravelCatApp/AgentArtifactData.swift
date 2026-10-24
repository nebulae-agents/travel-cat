import Foundation
import CryptoKit

struct WorkbenchArtifact: Identifiable, Equatable, Sendable {
    let path: String
    let size: Int
    var id: String { path }
}
struct WorkbenchArtifactPreview: Equatable, Sendable {
    let artifact: WorkbenchArtifact
    let bytes: Data
    let sha256: String
    init(artifact: WorkbenchArtifact, bytes: Data) {
        self.artifact = artifact; self.bytes = bytes
        sha256 = Self.digest(bytes)
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
struct WorkbenchArtifactReview: Codable, Equatable, Sendable {
    let path: String
    let sha256: String
    let reviewedAt: Date
}
enum WorkbenchArtifactLimits {
    static let bytes = 4 * 1024 * 1024
    static func validate(path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.count <= 2048, !parts.isEmpty, parts.count <= 9 else { throw WorkbenchFailure("文件路径无效。") }
        for part in parts {
            let lower = part.lowercased()
            guard !part.isEmpty, part.utf8.count <= 200, !part.hasPrefix("."),
                  !part.contains("\\"), !part.unicodeScalars.contains(where: { $0.value < 32 }),
                  !["key", "secret", "credential", "token", "id_rsa", "id_ed25519"].contains(where: lower.contains),
                  ![".pem", ".p12", ".pfx"].contains(where: lower.hasSuffix) else {
                throw WorkbenchFailure("此文件路径不可读取，隐藏文件和凭据文件不提供预览。")
            }
        }
    }
    static func validate(_ preview: WorkbenchArtifactPreview) throws {
        try validate(path: preview.artifact.path)
        guard preview.bytes.count <= bytes, preview.bytes.count == preview.artifact.size,
              WorkbenchArtifactPreview.digest(preview.bytes) == preview.sha256 else { throw WorkbenchFailure("预览数据无效，请重新读取文件。") }
    }
}
