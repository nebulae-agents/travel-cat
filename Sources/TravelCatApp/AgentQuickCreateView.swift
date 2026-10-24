import SwiftUI
import AppKit

/// A guided path for a new managed instance. Discovery never imports existing sessions.
@MainActor
struct AgentQuickCreateView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AgentWorkbenchModel
    let openManual: () -> Void
    let didSave: (UUID) -> Void

    @State private var selectedImage: LocalRuntimeInventory.Image?
    @State private var preset: ACPAdapterPreset = .codex
    @State private var draft: QuickCreateDraft?
    @State private var formError: String?
    @State private var step = 0
    @State private var selectedContext = ""
    @State private var saving = false

    private var selectedVerified: Bool {
        guard let selectedImage, let proof = model.probeVerification else { return false }
        return proof.matches(image: selectedImage, command: preset.command)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("添加 ACP Agent").font(.title3.weight(.semibold)); Spacer()
                if step == 0 {
                    Button(model.scanningLocal ? "扫描中…" : "重新扫描") { draft = nil; Task { await model.scanLocal() } }
                        .disabled(model.scanningLocal || model.probingLocal)
                }
            }
            HStack(spacing: 10) {
                ForEach(Array(["选择镜像", "兼容性检查", "模型配置"].enumerated()), id: \.offset) { index, title in
                    Text("\(index + 1)  \(title)").font(.caption).foregroundStyle(step == index ? WorkbenchTheme.accent : WorkbenchTheme.muted)
                    if index < 2 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(WorkbenchTheme.line) }
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let issue = model.localScanError { Text(issue).font(.callout).foregroundStyle(CottageTheme.terracotta) }
                    if model.scanningLocal && model.localInventory == nil { ProgressView("正在读取本机环境…") }
                    if step == 0, let inventory = model.localInventory {
                        Picker("运行环境", selection: $selectedContext) {
                            Text("请选择环境").tag("")
                            ForEach(inventory.contexts.filter { $0.local && $0.available }) { Text($0.name).tag($0.name) }
                        }
                        imageSection(inventory)
                        DisclosureGroup("环境与发现详情") {
                            VStack(spacing: 12) { toolSection(inventory); contextSection(inventory); containerSection(inventory) }.padding(.top, 10)
                        }.font(.caption)
                    }
                    if let retained = model.retainedProbe {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("隔离容器清理待确认").font(.headline)
                            if let name = retained.containerName { Text(verbatim: name).font(.caption.monospaced()).textSelection(.enabled) }
                            Button(model.probingLocal ? "清理中…" : "重试清理") { Task { await model.retryProbeCleanup() } }.disabled(model.probingLocal || saving)
                        }.padding(12).background(WorkbenchTheme.warning, in: RoundedRectangle(cornerRadius: 9))
                    }
                    if step == 1, let selectedImage {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("检查所选镜像").font(.headline)
                            Text(verbatim: selectedImage.ref).font(.caption.monospaced()).textSelection(.enabled)
                            Text("Docker · \(selectedImage.context)").font(.caption).foregroundStyle(WorkbenchTheme.muted)
                            Picker("启动预设", selection: $preset) { ForEach(ACPAdapterPreset.allCases) { Text($0.title).tag($0) } }
                            Button(model.probingLocal ? "检查中…" : "检查 ACP 兼容性") { draft = nil; Task { await model.probe(image: selectedImage, preset: preset) } }
                                .disabled(model.probingLocal || model.retainedProbe != nil)
                            Text("临时启动无网络、只读的隔离容器，完成握手后清理；不发送任务或模型请求。").font(.caption).foregroundStyle(WorkbenchTheme.muted)
                            if let notice = model.probeNotice { Text(notice).font(.caption).foregroundStyle(selectedVerified ? WorkbenchTheme.accent : CottageTheme.terracotta) }
                        }.padding(16).workbenchPanel()
                    }
                    if step == 2, selectedVerified, draft != nil { shortForm }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let formError { Text(formError).font(.caption).foregroundStyle(CottageTheme.terracotta) }
            HStack {
                Button("高级手动配置") { dismiss(); openManual() }.disabled(model.probingLocal || saving)
                Spacer()
                Button("取消") { dismiss() }.disabled(model.probingLocal || saving).keyboardShortcut(.cancelAction)
                if step > 0 { Button("上一步") { step -= 1 }.disabled(model.probingLocal || saving) }
                if step < 2 {
                    Button("下一步") { step += 1 }.buttonStyle(.borderedProminent)
                        .disabled(model.probingLocal || model.scanningLocal || (step == 0 ? selectedImage == nil : !selectedVerified || draft == nil))
                } else {
                    Button(saving ? "正在保存…" : "保存 Agent") { saveDraft() }.buttonStyle(.borderedProminent).disabled(!selectedVerified || draft == nil || saving)
                }
            }
        }.padding(22).frame(width: min(700, (NSScreen.main?.visibleFrame.width ?? 900) - 100), height: min(600, (NSScreen.main?.visibleFrame.height ?? 800) - 100))
        .workbenchSurface()
        .interactiveDismissDisabled(model.probingLocal || saving)
        .task { if model.localInventory == nil { await model.scanLocal() }; selectAvailableContext() }
        .onChange(of: model.localInventory) { _, _ in selectAvailableContext() }
        .onChange(of: selectedContext) { _, value in
            if selectedImage?.context != value { selectedImage = nil; draft = nil; formError = nil }
        }
        .onChange(of: selectedImage) { _, _ in draft = nil; formError = nil }
        .onChange(of: preset) { _, _ in draft = nil; formError = nil }
        .onChange(of: model.probeVerification) { _, proof in
            draft = proof.flatMap { $0.matches(image: selectedImage ?? $0.image, command: preset.command) ? QuickCreateDraft(verification: $0) : nil }
            if draft == nil && step == 2 { step = 1 }
        }
    }

    private func toolSection(_ inventory: LocalRuntimeInventory) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("经典 Agent 命令行工具").font(CottageTheme.heading)
            ForEach(["codex", "claude", "dsh"], id: \.self) { kind in
                let tool = inventory.tools.first { $0.kind == kind }
                let status = tool.map { $0.running > 0 ? "当前用户进程 \($0.running)" : "已安装" } ?? "未发现"
                HStack {
                    Text(kind == "claude" ? "Claude Code" : kind == "dsh" ? "DSH" : "Codex")
                        .fontWeight(.medium)
                    Text(status)
                        .font(.caption).foregroundStyle(CottageTheme.mutedInk)
                    Spacer()
                }
                if let tool, !tool.path.isEmpty {
                    Text(verbatim: tool.path).font(.caption.monospaced()).foregroundStyle(CottageTheme.mutedInk).textSelection(.enabled)
                }
            }
            Text("只识别安装位置与进程数，不读取会话或登录信息。")
                .font(.caption).foregroundStyle(CottageTheme.mutedInk)
        }.padding(10).cottageCard()
    }

    private func contextSection(_ inventory: LocalRuntimeInventory) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Docker 环境").font(CottageTheme.heading)
            if inventory.contexts.isEmpty { Text("未发现本机 Docker context。") }
            ForEach(inventory.contexts) { context in
                HStack {
                    Text(context.name)
                    Spacer()
                    Text(!context.local ? "远程 · 未连接" : context.available ? "本机 · 可用" : "本机 · 不可用")
                        .font(.caption).foregroundStyle(CottageTheme.mutedInk)
                }
            }
        }.padding(10).cottageCard()
    }

    private func imageSection(_ inventory: LocalRuntimeInventory) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("固定摘要镜像").font(CottageTheme.heading)
            let candidates = WorkbenchConversationPresentation.images(in: inventory, context: selectedContext)
            if candidates.filter({ $0.suggestedPreset != nil }).isEmpty { Text(selectedContext.isEmpty ? "先选择可用的本机运行环境。" : "所选环境尚无已识别的 ACP 候选镜像。") }
            ForEach(candidates.filter { $0.suggestedPreset != nil }) { image in
                Button {
                    selectedImage = image
                    preset = image.suggestedPreset ?? .codex
                } label: {
                    HStack {
                        Image(systemName: selectedImage == image ? "checkmark.circle.fill" : "circle")
                        VStack(alignment: .leading) {
                            Text(image.suggestedPreset?.title ?? "ACP 候选")
                            Text(verbatim: image.context + " · " + image.ref)
                                .font(.caption.monospaced()).lineLimit(2)
                        }
                        Spacer()
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            let otherImages = candidates.filter { $0.suggestedPreset == nil }
            if !otherImages.isEmpty {
                Text("其他固定摘要镜像 · 需自选预设并检查").font(.caption).foregroundStyle(CottageTheme.mutedInk)
                ForEach(otherImages) { image in
                    Button {
                        selectedImage = image
                        preset = .codex
                    } label: {
                        HStack {
                            Image(systemName: selectedImage == image ? "checkmark.circle.fill" : "circle")
                            Text(verbatim: image.context + " · " + image.ref)
                                .font(.caption.monospaced()).lineLimit(2)
                            Spacer()
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }.padding(10).cottageCard()
    }

    private func containerSection(_ inventory: LocalRuntimeInventory) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("正在运行的相关容器").font(CottageTheme.heading)
            if inventory.containers.isEmpty { Text("未发现相关容器。") }
            ForEach(inventory.containers) { container in
                Text(verbatim: "\(container.name) · \(container.context) · \(container.state)").font(.caption)
            }
            Text("这些容器仅供识别，不会自动接管或停止。")
                .font(.caption).foregroundStyle(CottageTheme.mutedInk)
        }.padding(10).cottageCard()
    }

    private var shortForm: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("新建受管实例").font(CottageTheme.heading)
            TextField("实例名称", text: Binding(get: { draft?.name ?? "" }, set: { draft?.name = $0 }))
            Picker("模型接口", selection: Binding(get: { draft?.provider.api ?? .responses }, set: { draft?.provider.api = $0 })) {
                ForEach(WorkbenchAPI.allCases) { api in Text(api.title).tag(api) }
            }
            TextField("HTTPS 模型服务地址", text: Binding(get: { draft?.provider.baseURL ?? "" }, set: { draft?.provider.baseURL = $0 }))
            TextField("模型名称", text: Binding(get: { draft?.provider.model ?? "" }, set: { draft?.provider.model = $0 }))
            SecureField("API Key（保存到钥匙串）", text: Binding(get: { draft?.newKey ?? "" }, set: { draft?.newKey = $0 }))
            Text("镜像和命令已由本次检查固定。保存只建立实例；任务需要你另行发起。")
                .font(.caption).foregroundStyle(CottageTheme.mutedInk)
        }.textFieldStyle(.roundedBorder).padding(10).cottageCard(fill: CottageTheme.leafPaper)
    }

    private func selectAvailableContext() {
        guard let inventory = model.localInventory else { selectedContext = ""; return }
        let available = inventory.contexts.filter { $0.local && $0.available }
        if !available.contains(where: { $0.name == selectedContext }) {
            selectedContext = available.first(where: { context in inventory.images.contains { $0.context == context.name } })?.name ?? available.first?.name ?? ""
        }
    }

    private func saveDraft() {
        guard let draft, model.probeVerification == draft.verification else {
            formError = "兼容性检查已失效，请重新检查。"; return
        }
        guard !saving else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                let instance = try draft.validatedInstance()
                try await model.saveInstance(instance: instance, newKey: draft.newKey)
                didSave(instance.id)
                dismiss()
            } catch { formError = error.localizedDescription }
        }
    }
}
