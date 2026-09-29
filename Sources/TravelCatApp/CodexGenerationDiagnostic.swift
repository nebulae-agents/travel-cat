import Foundation
import Darwin
import TravelStorage

/// Only fixed codes and numeric metadata cross the subprocess logging boundary.
/// Never add prompt, output, filesystem paths, or free-form error text here.
struct CodexGenerationDiagnostic: Codable, Equatable, Sendable {
    enum Code: String, Codable, Sendable {
        case succeeded, cancelled, notInstalled, notLoggedIn, timedOut
        case networkUnavailable, toolUnavailable, incompatibleCLI, invalidOutput, generationFailed
    }
    let code: Code
    let recordedAt: Date
    let durationMilliseconds: Int
    let exitStatus: Int32?

    var userMessage: String {
        switch code {
        case .succeeded: "Codex 调用已完成。"
        case .cancelled: "Codex 生成已取消。"
        case .notInstalled: "未找到 Codex 命令行程序，请先安装 Codex。"
        case .notLoggedIn: "Codex 尚未登录或登录已失效，请先在 Codex 中登录。"
        case .timedOut: "Codex 生成超时，请检查连接后重试。"
        case .networkUnavailable: "Codex 报告网络连接失败，请检查网络、代理或沙箱网络限制后重试。"
        case .toolUnavailable: "Codex 报告图像工具不可用，请检查当前账号和 Codex 是否支持图像生成。"
        case .incompatibleCLI: "Codex 命令行版本不支持本次调用参数，请更新 Codex 后重试。"
        case .invalidOutput: "Codex 未提供可用的输出文件，请重试；若重复失败，请检查 Codex 版本与工具支持。"
        case .generationFailed: "Codex 未能完成生成，原因尚未识别，请重试并查看最近诊断。"
        }
    }
}

/// Keeps one sanitized summary, not a transcript or generation history.
final class CodexGenerationDiagnosticStore: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    init(fileURL: URL) { self.fileURL = fileURL }

    func record(_ data: Data) throws {
        guard data.count <= 4096 else { throw CocoaError(.fileReadTooLarge) }
        try record(JSONDecoder().decode(CodexGenerationDiagnostic.self, from: data))
    }

    func record(_ diagnostic: CodexGenerationDiagnostic) throws {
        lock.lock(); defer { lock.unlock() }
        guard diagnostic.durationMilliseconds >= 0 else { throw CocoaError(.coderInvalidValue) }
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(diagnostic)
        try AtomicFileWriter().write(data, to: fileURL)
    }

    func latest() -> CodexGenerationDiagnostic? {
        lock.lock(); defer { lock.unlock() }
        let descriptor = open(fileURL.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1, info.st_size <= 4096 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try? handle.read(upToCount: 4097), data.count <= 4096,
              let diagnostic = try? JSONDecoder().decode(CodexGenerationDiagnostic.self, from: data),
              diagnostic.durationMilliseconds >= 0 else { return nil }
        return diagnostic
    }
}
