import Foundation
import TravelStorage

/// Delay executable discovery until a run: retained albums do not require the CLI.
struct JourneyTestDiscoveredModelGenerator: JourneyTestModelGenerating {
    enum Unavailable: LocalizedError {
        case codex
        var errorDescription: String? { "找不到可用的 Codex 命令行，请先安装并登录 Codex 后重试。已完成的测试旅行册仍可查看。" }
    }

    func generateJSON(prompt: String, schema: Data, session: JourneyTestSession, referenceImage: URL?) async throws -> Data {
        let installation: JourneyTestCodexInstallation
        do { installation = try JourneyTestCodexInstallation.discover() }
        catch { throw Unavailable.codex }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = installation.searchPath
        environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        let runner = try JourneyTestModelRunner(executableURL: installation.executableURL, environment: environment)
        return try await runner.generateJSON(prompt: prompt, schema: schema, session: session, referenceImage: referenceImage)
    }
}
