import Foundation
import TravelCore
import TravelStorage

@MainActor
final class CodexTravelContentGenerator: TravelContentGenerating {
    private let executor: CodexTravelExecutor
    private let diagnostics: @Sendable (Data) -> Void
    init(executor: CodexTravelExecutor, diagnostics: @escaping @Sendable (Data) -> Void = { _ in }) {
        self.executor = executor
        self.diagnostics = diagnostics
    }

    func narrative(for request: TravelEventRequest) async throws -> TravelNarrative {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("travelcat-story-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: workspace) }
        try JSONEncoder.travelCat.encode(request).write(to: workspace.appendingPathComponent("request.json"))
        let schema = try copyResource("narrative.schema.json", into: workspace)
        let prompt = TravelGenerationPrompts.narrative()
        let output = try await executor.run(prompt: prompt, workspace: workspace, schema: schema)
        do {
            return try JSONDecoder.travelCat.decode(TravelNarrative.self, from: output)
        } catch {
            recordDiagnostic(.invalidOutput, startedAt: Date())
            throw error
        }
    }

    func image(for work: PendingImageWork, in workspace: URL) async throws -> URL {
        let startedAt = Date()
        try JSONEncoder.travelCat.encode(work.event).write(to: workspace.appendingPathComponent("event.json"))
        let schema = try copyResource("image.schema.json", into: workspace)
        let images = try ["front.png", "side.png", "sitting.png"].map { try copyResource($0, into: workspace) }
        _ = try copyResource("identity.json", into: workspace)
        let prompt = TravelGenerationPrompts.codexImage(for: work.event)
        let output = try await executor.run(prompt: prompt, workspace: workspace, schema: schema, images: images)
        struct Result: Decodable { let status: String; let reason: String }
        let result: Result
        do {
            result = try JSONDecoder().decode(Result.self, from: output)
        } catch {
            recordDiagnostic(.invalidOutput, startedAt: startedAt)
            throw TravelImageGenerationFailure.invalidImage
        }
        guard result.status == "ready", result.reason == "none" else {
            let code: CodexGenerationDiagnostic.Code
            switch result.reason {
            case "tool_unavailable": code = .toolUnavailable
            case "network_error": code = .networkUnavailable
            case "invalid_image", "file_unavailable": code = .invalidOutput
            default: code = .generationFailed
            }
            recordDiagnostic(code, startedAt: startedAt)
            throw TravelImageGenerationFailure(rawValue: result.reason) ?? .fileUnavailable
        }
        let target = workspace.appendingPathComponent("postcard.png")
        guard FileManager.default.fileExists(atPath: target.path) else {
            recordDiagnostic(.invalidOutput, startedAt: startedAt)
            throw TravelImageGenerationFailure.fileUnavailable
        }
        return target
    }

    private func recordDiagnostic(_ code: CodexGenerationDiagnostic.Code, startedAt: Date) {
        let diagnostic = CodexGenerationDiagnostic(code: code, recordedAt: Date(),
            durationMilliseconds: max(0, Int(Date().timeIntervalSince(startedAt) * 1000)), exitStatus: nil)
        if let data = try? JSONEncoder().encode(diagnostic) { diagnostics(data) }
    }

    static func generationResourceRoot(in bundle: Bundle = .main) -> URL? {
        if bundle.bundleURL.pathExtension == "app" {
            guard let resources = bundle.resourceURL else { return nil }
            let packaged = resources.appendingPathComponent("TravelCat_TravelCatApp.bundle/Generation")
            return FileManager.default.fileExists(atPath: packaged.path) ? packaged : nil
        }
        return Bundle.module.resourceURL?.appendingPathComponent("Generation")
    }

    private func copyResource(_ name: String, into workspace: URL) throws -> URL {
        guard let root = Self.generationResourceRoot(),
              FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let target = workspace.appendingPathComponent(name)
        try FileManager.default.copyItem(at: root.appendingPathComponent(name), to: target)
        return target
    }
}

enum TravelImageGenerationFailure: String, Error, LocalizedError {
    case toolUnavailable = "tool_unavailable"
    case networkError = "network_error"
    case invalidImage = "invalid_image"
    case fileUnavailable = "file_unavailable"
    var errorDescription: String? {
        switch self {
        case .toolUnavailable: "Codex 暂未提供图片生成，文字来信已保留。"
        case .networkError: "照片生成遇到连接问题，稍后重试。"
        case .invalidImage: "照片未通过画面或比例检查，稍后重试。"
        case .fileUnavailable: "照片文件尚未就绪，稍后重试。"
        }
    }
}
