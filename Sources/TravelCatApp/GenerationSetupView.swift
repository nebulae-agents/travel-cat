import AppKit
import ImageIO
import SwiftUI

@MainActor
struct GenerationSetupView: View {
    @ObservedObject var controller: GenerationServiceController
    let credentials: any TravelServiceCredentialStoring
    let executor: CodexTravelExecutor
    var completed: () -> Void = {}
    @State private var draft: TravelGenerationConfiguration
    @State private var narrativeSecret = ""
    @State private var imageSecret = ""
    @State private var narrativeNoKey = false
    @State private var imageNoKey = false
    @State private var message = ""
    @State private var busy = false
    @State private var testTask: Task<Void, Never>?
    @State private var preview: NSImage?

    init(controller: GenerationServiceController, credentials: any TravelServiceCredentialStoring,
         executor: CodexTravelExecutor, completed: @escaping () -> Void = {}) {
        self.controller = controller
        self.credentials = credentials
        self.executor = executor
        self.completed = completed
        var initial = controller.configuration
        if !controller.isReady {
            initial.narrative.kind = .openAICompatible
            initial.image.kind = .openAICompatible
        }
        _draft = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(controller.isReady ? "模型与连接" : "欢迎来到小黑的家").font(.title2.bold())
            Text("选择写旅行日记和拍明信片的服务。完成配置后，小黑会按旅行设置随机出发；历史相册始终保留。")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    serviceSection("1 · 旅行日记", service: $draft.narrative, secret: $narrativeSecret,
                                   noKey: $narrativeNoKey, isImage: false)
                    serviceSection("2 · 明信片照片", service: $draft.image, secret: $imageSecret,
                                   noKey: $imageNoKey, isImage: true)
                    if let preview {
                        Image(nsImage: preview).resizable().scaledToFit().frame(maxHeight: 190)
                            .accessibilityLabel("连接测试照片，仅预览，不计入相册")
                    }
                    Text("密钥保存在此 Mac 的系统钥匙串中。旅行故事和角色参考图会发送给你选择的服务。试生成和自动旅行可能产生服务费用。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !message.isEmpty { Text(message).font(.callout).textSelection(.enabled) }
            HStack {
                if busy {
                    ProgressView().controlSize(.small)
                    Button("取消测试") { testTask?.cancel() }
                }
                Spacer()
                Button("保存并完成配置") { save() }.buttonStyle(.borderedProminent).disabled(busy)
            }
        }
        .padding(22).frame(minWidth: 600, minHeight: 630)
        .onChange(of: draft) { _, _ in message = ""; preview = nil }
        .onChange(of: narrativeSecret) { _, _ in message = "" }
        .onChange(of: imageSecret) { _, _ in message = "" }
        .onDisappear { testTask?.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if (notification.object as? NSWindow)?.title == "Travel Cat · 模型与连接" { testTask?.cancel() }
        }
    }

    private func serviceSection(_ title: String, service: Binding<TravelServiceConfiguration>,
                                secret: Binding<String>, noKey: Binding<Bool>, isImage: Bool) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 9) {
                Picker("使用服务", selection: service.kind) {
                    Text("OpenAI 兼容服务 / 本机模型").tag(TravelServiceKind.openAICompatible)
                    Text("Codex（需已安装并登录）").tag(TravelServiceKind.codex)
                }
                if service.wrappedValue.kind == .openAICompatible {
                    HStack {
                        Button("OpenAI") {
                            service.wrappedValue.baseURL = "https://api.openai.com/v1"
                            service.wrappedValue.model = isImage ? "gpt-image-1" : ""
                            secret.wrappedValue = ""; noKey.wrappedValue = false
                        }
                        if !isImage {
                            Button("本机 Ollama") {
                                service.wrappedValue.baseURL = "http://localhost:11434/v1"
                                service.wrappedValue.model = ""
                                secret.wrappedValue = ""; noKey.wrappedValue = true
                            }
                        }
                    }.buttonStyle(.borderless)
                    TextField("服务地址，例如 https://api.example.com/v1", text: service.baseURL)
                    TextField(isImage ? "图片模型名称" : "文字模型名称（使用服务中可用的名称）", text: service.model)
                    SecureField("API Key（留空保留同一服务的已有密钥）", text: secret).disabled(noKey.wrappedValue)
                    Toggle("此服务无需密钥", isOn: noKey)
                    if isImage {
                        Toggle("使用角色参考图（服务需支持图片编辑接口）", isOn: service.useImageEdits)
                        if !service.wrappedValue.useImageEdits {
                            Text("仅按描述生成，角色外观的一致性会降低。").font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Toggle("要求 JSON 输出（不支持时可关闭）", isOn: service.jsonMode)
                    }
                } else {
                    Text("复用本机 Codex CLI 登录。无需打开 Codex 桌面应用；照片还需要该账号支持图片生成。")
                        .font(.caption).foregroundStyle(.secondary)
                    Link("Codex 安装与登录说明", destination: URL(string: "https://developers.openai.com/codex/cli/")!)
                }
                Button(isImage ? "试生成照片（可能计费）" : "测试文字连接") { probe(isImage: isImage) }
            }.padding(8).disabled(busy)
        } label: { Text(title).font(.headline) }
    }

    private func save() {
        do {
            try controller.save(draft, narrativeSecret: narrativeSecret, imageSecret: imageSecret,
                                narrativeNoKey: narrativeNoKey, imageNoKey: imageNoKey)
            narrativeSecret = ""; imageSecret = ""
            message = "配置已保存。自动旅行将遵循旅行设置。"
            completed()
        } catch { message = safeMessage(error) }
    }

    private func key(for service: TravelServiceConfiguration, isImage: Bool) throws -> String? {
        let noKey = isImage ? imageNoKey : narrativeNoKey
        let secret = isImage ? imageSecret : narrativeSecret
        if noKey { return nil }
        if !secret.isEmpty { return secret }
        let saved = isImage ? controller.configuration.image : controller.configuration.narrative
        guard service.kind == saved.kind, service.baseURL == saved.baseURL else {
            throw GenerationSetupError.newEndpointNeedsCredentialChoice
        }
        return try credentials.read(id: saved.credentialID)
    }

    private func probe(isImage: Bool) {
        busy = true
        message = isImage ? "正在试生成照片；不会加入历史相册…" : "正在测试文字连接…"
        preview = nil
        testTask = Task { @MainActor in
            defer { busy = false; testTask = nil }
            do {
                let service = isImage ? draft.image : draft.narrative
                try service.validate()
                let client = OpenAICompatibleTravelClient()
                let data: Data
                if service.kind == .codex {
                    data = try await probeCodex(isImage: isImage)
                } else if isImage {
                    let generator = ConfiguredTravelContentGenerator(configuration: { draft }, credentials: credentials,
                        codex: CodexTravelContentGenerator(executor: executor), client: client)
                    data = try await generator.generateImage(service: service,
                        scene: "{\"location\":\"杭州西湖湖边\",\"mood\":\"安静愉快\",\"scene\":\"午后柔和自然光，黑猫回头看向湖面\"}",
                        apiKey: key(for: service, isImage: true), useStoredCredential: false)
                } else {
                    data = try await client.text(baseURL: service.validatedBaseURL(), model: service.model,
                        apiKey: key(for: service, isImage: false),
                        prompt: "Connection test. Return only the JSON object {\"ok\":true}.", jsonMode: service.jsonMode)
                }
                try Task.checkCancellation()
                if isImage {
                    guard data.count <= 15 * 1024 * 1024,
                          let source = CGImageSourceCreateWithData(data as CFData, nil),
                          CGImageSourceGetType(source) as String? == "public.png",
                          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                          let width = properties[kCGImagePropertyPixelWidth] as? Int,
                          let height = properties[kCGImagePropertyPixelHeight] as? Int,
                          width >= 1152, height >= 768, width <= 8192, height <= 8192,
                          Int64(width) * Int64(height) <= 16_000_000,
                          abs(Double(width) - Double(height) * 1.5) <= 1,
                          CGImageSourceCreateImageAtIndex(source, 0, nil) != nil,
                          let rendered = NSImage(data: data) else { throw GenerationSetupError.invalidProbe }
                    preview = rendered
                    message = "照片连接成功，已通过横向 3:2 和尺寸检查。请查看角色与画面；这张测试照不会写入相册。"
                } else {
                    let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    guard value?["ok"] as? Bool == true else { throw GenerationSetupError.invalidProbe }
                    message = "文字连接成功。完整旅行内容仍会经过应用检查。"
                }
            } catch {
                message = Task.isCancelled ? "测试已取消。" : safeMessage(error)
            }
        }
    }

    private func probeCodex(isImage: Bool) async throws -> Data {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("travelcat-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: workspace) }
        if !isImage {
            return try await executor.run(prompt: "Connection test. Return only {\"ok\":true}. Do not write files.", workspace: workspace)
        }
        guard let resources = CodexTravelContentGenerator.generationResourceRoot() else { throw GenerationSetupError.invalidProbe }
        let images = ["front.png", "side.png", "sitting.png"].map { resources.appendingPathComponent($0) }
        _ = try await executor.run(prompt: TravelGenerationPrompts.image
            + " Use the built-in image generation tool. Scene: quiet afternoon at Hangzhou West Lake."
            + " Save actual PNG to postcard.png in this workspace. No other services or fallback tools."
            + " Return only {\"status\":\"ready\",\"reason\":\"none\"} when the file is ready; otherwise status failed and reason tool_unavailable.",
            workspace: workspace, schema: resources.appendingPathComponent("image.schema.json"), images: images)
        let url = workspace.appendingPathComponent("postcard.png")
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= 15 * 1024 * 1024 else { throw GenerationSetupError.invalidProbe }
        return try Data(contentsOf: url)
    }

    private func safeMessage(_ error: Error) -> String {
        if let error = error as? LocalizedError, let description = error.errorDescription { return description }
        return "操作未完成，请检查服务地址、模型名称和访问权限后重试。"
    }
}
