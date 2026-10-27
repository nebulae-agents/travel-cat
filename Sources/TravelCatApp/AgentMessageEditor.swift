import AppKit
import SwiftUI

/// Return sends; an IME composition and Shift/Option-Return remain normal text input.
@MainActor
struct AgentMessageEditor: NSViewRepresentable {
    @Binding var text: String
    let canSend: Bool
    let focusRequest: UUID
    let onHeight: (CGFloat) -> Void
    let send: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let editor = MessageTextView()
        editor.isRichText = false; editor.importsGraphics = false; editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 14); editor.textColor = NSColor(WorkbenchTheme.ink)
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false; editor.isContinuousSpellCheckingEnabled = false
        editor.isHorizontallyResizable = false; editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 4, height: 5)
        editor.minSize = .zero; editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.setAccessibilityLabel("输入消息")
        editor.delegate = context.coordinator
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? MessageTextView else { return }
        if editor.string != text && !editor.hasMarkedText() {
            let selection = editor.selectedRange()
            editor.string = text
            editor.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
        }
        editor.canSend = canSend; editor.send = send
        if context.coordinator.lastFocus != focusRequest {
            context.coordinator.lastFocus = focusRequest
            DispatchQueue.main.async { [weak editor] in
                guard let editor, let window = editor.window, window.isKeyWindow else { return }
                window.makeFirstResponder(editor)
            }
        }
        context.coordinator.measure(editor)
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AgentMessageEditor
        var lastFocus: UUID?
        private var lastHeight: CGFloat = 0
        init(_ parent: AgentMessageEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            if parent.text != editor.string { parent.text = editor.string }
            measure(editor)
        }
        func measure(_ editor: NSTextView) {
            guard let layout = editor.layoutManager, let container = editor.textContainer else { return }
            layout.ensureLayout(for: container)
            let height = min(150, max(60, ceil(layout.usedRect(for: container).height) + editor.textContainerInset.height * 2))
            guard abs(height - lastHeight) > 1 else { return }
            lastHeight = height
            DispatchQueue.main.async { [weak self] in self?.parent.onHeight(height) }
        }
    }
    @MainActor final class MessageTextView: NSTextView {
        var canSend = false
        var send: (() -> Void)?
        override func keyDown(with event: NSEvent) {
            if [36, 76].contains(event.keyCode), !event.modifierFlags.contains(.shift), !event.modifierFlags.contains(.option), !hasMarkedText() {
                if canSend { send?() }
                return
            }
            super.keyDown(with: event)
        }
    }
}

@MainActor
struct AgentComposerView: View {
    @Binding var draft: WorkbenchSubmissionDraft
    let instance: WorkbenchInstance?
    let parentTitle: String?
    let removeParent: () -> Void
    let isNew: Bool
    let canSend: Bool
    let focusRequest: UUID
    let hint: String?
    @Binding var allowModelAccess: Bool
    let onFailure: (String) -> Void
    let send: () -> Void
    @State private var editorHeight: CGFloat = 60
    @State private var showingScope = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if isNew, let instance, let native = instance.native {
                Button { showingScope.toggle() } label: {
                    Label(URL(fileURLWithPath: native.workspace).lastPathComponent.isEmpty ? "工作目录" : URL(fileURLWithPath: native.workspace).lastPathComponent, systemImage: "folder")
                        .font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                }.buttonStyle(.plain).foregroundStyle(WorkbenchTheme.muted)
                .popover(isPresented: $showingScope) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("任务范围").font(.headline)
                        Text(verbatim: native.workspace).font(.caption.monospaced()).textSelection(.enabled)
                        Text("任务上下文将提交给官方账号模型；文件读写限于所选目录，工具操作按规则审批。").font(.caption)
                    }.padding(18).frame(width: 340).workbenchSurface()
                }
            }
            if isNew, instance?.native == nil, instance != nil {
                Toggle("本任务持续允许向所选模型提交上下文", isOn: $allowModelAccess).font(.system(size: 12)).toggleStyle(.checkbox)
                Text(allowModelAccess ? "包含本任务的后续追问，每次调用仍保留审计。" : "默认逐次确认模型请求；文件读取不等于允许上传。")
                    .font(.system(size: 12)).foregroundStyle(WorkbenchTheme.muted)
            }
            if let parentID = draft.parentTaskID {
                HStack(spacing: 8) {
                    Label("承接来源：" + (parentTitle.map(WorkbenchConversationPresentation.shortTitle) ?? "原对话 \(parentID.uuidString.prefix(8))"), systemImage: "arrow.turn.down.right")
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button("移除承接来源", action: removeParent).buttonStyle(.borderless)
                        .help("仅移除来源关联，保留正文和文件。")
                }.font(.system(size: 12)).padding(8)
                    .background(WorkbenchTheme.sidebar, in: RoundedRectangle(cornerRadius: 8))
            }
            VStack(spacing: 5) {
                ZStack(alignment: .topLeading) {
                    if draft.text.isEmpty { Text(isNew ? "想让 Agent 帮你做什么？" : "继续说说你的想法…").font(.system(size: 14)).foregroundStyle(WorkbenchTheme.muted.opacity(0.75)).padding(.leading, 9).padding(.top, 7).allowsHitTesting(false) }
                    AgentMessageEditor(text: $draft.text, canSend: canSend, focusRequest: focusRequest, onHeight: { editorHeight = $0 }, send: send).frame(height: editorHeight)
                }
                HStack(spacing: 8) {
                    if isNew, instance?.native == nil, instance != nil {
                        Button { chooseFiles() } label: { Image(systemName: "paperclip") }.buttonStyle(.plain).help("添加输入文件").accessibilityLabel("添加输入文件")
                    }
                    if !draft.files.isEmpty {
                        Menu("文件 · \(draft.files.count)") {
                            ForEach(Array(draft.files.enumerated()), id: \.offset) { _, file in Text(file["name"] ?? "文件") }
                            Button("清除输入文件") { draft.files = [] }
                        }.font(.caption).fixedSize()
                    }
                    Text(modelLabel).font(.system(size: 12)).foregroundStyle(WorkbenchTheme.muted).lineLimit(1)
                    Spacer(minLength: 8)
                    Button(action: send) { Image(systemName: "arrow.up").font(.system(size: 13, weight: .semibold)).frame(width: 28, height: 28) }
                        .buttonStyle(.borderedProminent).controlSize(.small).disabled(!canSend).accessibilityLabel("发送消息")
                        .keyboardShortcut(.return, modifiers: .command)
                }.padding(.horizontal, 7).padding(.bottom, 5)
            }.padding(8).workbenchPanel()
            HStack {
                Text(hint ?? (isNew ? "发送即允许将任务上下文提交给所选模型服务。" : "Enter 发送 · Shift + Enter 换行"))
                    .font(.system(size: 11)).foregroundStyle(WorkbenchTheme.muted).lineLimit(2)
                Spacer(minLength: 0)
            }
        }
    }
    private var modelLabel: String {
        guard let instance else { return "先添加或选择 Agent" }
        if isNew { return (instance.native?.model ?? instance.provider.model).isEmpty ? instance.name : (instance.native?.model ?? instance.provider.model) }
        return instance.native != nil ? "本机 Codex · 沿用原会话模型" : "ACP · 本任务模型服务"
    }
    private func chooseFiles() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        do {
            guard panel.urls.count <= 32 else { throw WorkbenchFailure("一次最多选择 32 个文件。") }
            var files: [[String: String]] = []; var total = 0
            for url in panel.urls {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 1024 * 1024 else { throw WorkbenchFailure("输入文件必须为普通文件，且每个不超过 1 MiB。") }
                let bytes = try Data(contentsOf: url); total += bytes.count
                guard total <= 4 * 1024 * 1024 else { throw WorkbenchFailure("输入文件合计不能超过 4 MiB。") }
                files.append(["name": url.lastPathComponent, "base64": bytes.base64EncodedString()])
            }
            try WorkbenchSubmissionDraft.validateFiles(files)
            draft.files = files
        } catch { onFailure(error.localizedDescription) }
    }
}
