import AppKit
import SwiftUI

/// Swift String equality normalizes Unicode; a source update must compare original bytes.
struct AgentMarkdownSourceIdentity: Equatable {
    let text: String
    init(_ text: String) { self.text = text }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.text.utf8.elementsEqual(rhs.text.utf8) }
}

struct AgentMarkdownRawSnapshot: Identifiable {
    let id = UUID()
    let text: String
}

/// Retained by SwiftUI identity: constructing a message view never reparses its body.
@MainActor final class AgentMarkdownReadingState: ObservableObject {
    @Published private(set) var content: AgentMarkdownContent?
    private let parse: (String) -> AgentMarkdownContent
    init(parse: @escaping (String) -> AgentMarkdownContent = AgentMarkdownContent.parse) { self.parse = parse }
    @discardableResult func update(_ source: String) -> Bool {
        if let content, AgentMarkdownSourceIdentity(content.source) == AgentMarkdownSourceIdentity(source) { return false }
        content = parse(source)
        return true
    }
    func rawSnapshot() -> AgentMarkdownRawSnapshot { .init(text: content?.source ?? "") }
}

@MainActor enum AgentMarkdownCopy {
    @discardableResult static func raw(_ source: String, to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(source, forType: .string)
    }
    @discardableResult static func code(_ content: AgentMarkdownContent, block: AgentMarkdownContent.Block, to pasteboard: NSPasteboard) -> Bool {
        guard case .code = block.kind, content.blocks.contains(block) else { return false }
        return raw(content.text(in: block.contentRange), to: pasteboard)
    }
}

@MainActor struct AgentMarkdownMessageView: View {
    let text: String
    @StateObject private var reading = AgentMarkdownReadingState()
    @State private var rawSnapshot: AgentMarkdownRawSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let content = reading.content {
                if content.isDegraded {
                    Text(verbatim: content.preview).textSelection(.enabled)
                    Text("正文较长，当前显示阅读预览。可查看或复制完整原文。")
                        .font(.system(size: 12)).foregroundStyle(WorkbenchTheme.muted)
                } else {
                    ForEach(content.blocks) { block in blockView(block, content: content) }
                }
            }
            HStack(spacing: 14) {
                Button("查看原文") { rawSnapshot = .init(text: text) }
                Button("复制原文") { AgentMarkdownCopy.raw(text, to: .general) }
            }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(WorkbenchTheme.muted)
        }
        .font(.system(size: 14)).lineSpacing(6).frame(maxWidth: .infinity, alignment: .leading)
        .task(id: AgentMarkdownSourceIdentity(text)) { reading.update(text) }
        .sheet(item: $rawSnapshot) { snapshot in AgentMarkdownRawView(snapshot: snapshot) }
    }

    @ViewBuilder private func blockView(_ block: AgentMarkdownContent.Block, content: AgentMarkdownContent) -> some View {
        switch block.kind {
        case .text:
            Text(verbatim: content.text(in: block.contentRange)).textSelection(.enabled)
        case let .listItem(marker, indentation):
            HStack(alignment: .top, spacing: 8) {
                Text(verbatim: marker).monospacedDigit().fixedSize(horizontal: true, vertical: false)
                Text(verbatim: content.text(in: block.contentRange)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.leading, CGFloat(min(indentation, 24)) * 6)
        case let .code(language, closed):
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(verbatim: language.isEmpty ? "代码" : language).lineLimit(1)
                    if !closed { Text("未结束").foregroundStyle(WorkbenchTheme.muted) }
                    Spacer(minLength: 8)
                    Button("复制代码") { AgentMarkdownCopy.code(content, block: block, to: .general) }.buttonStyle(.plain)
                }.font(.system(size: 11)).foregroundStyle(WorkbenchTheme.muted)
                ScrollView([.horizontal, .vertical]) {
                    Text(verbatim: content.text(in: block.contentRange))
                        .font(.system(size: 12, design: .monospaced)).lineSpacing(3).textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 260)
            }.padding(11).background(WorkbenchTheme.sidebar, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

@MainActor private struct AgentMarkdownRawView: View {
    let snapshot: AgentMarkdownRawSnapshot
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("消息原文").font(.headline)
                Spacer()
                Button("复制完整原文") { AgentMarkdownCopy.raw(snapshot.text, to: .general) }
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("此处保留打开时的内容，可自由选择；后续回复会继续显示在对话中。")
                .font(.caption).foregroundStyle(WorkbenchTheme.muted)
            AgentMarkdownRawText(snapshot: snapshot.text)
        }.padding(18).frame(minWidth: 480, idealWidth: 700, minHeight: 320, idealHeight: 500)
    }
}

/// Native plain text, loaded only on explicit raw-view action; noncontiguous layout keeps
/// large (store-bounded) snapshots scrollable without eagerly laying out the entire message.
@MainActor struct AgentMarkdownRawText: NSViewRepresentable {
    let snapshot: String
    static func makeTextView(_ snapshot: String) -> NSTextView {
        let view = NSTextView()
        view.isEditable = false; view.isSelectable = true; view.isRichText = false; view.importsGraphics = false
        view.isAutomaticLinkDetectionEnabled = false; view.isAutomaticDataDetectionEnabled = false
        view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false; view.isContinuousSpellCheckingEnabled = false
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textContainerInset = NSSize(width: 10, height: 10)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = true
        view.minSize = .zero; view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.layoutManager?.allowsNonContiguousLayout = true
        view.setAccessibilityLabel("消息原文（打开时快照）")
        view.string = snapshot
        return view
    }
    static func update(_ view: NSTextView, snapshot: String) { if AgentMarkdownSourceIdentity(view.string) != AgentMarkdownSourceIdentity(snapshot) { view.string = snapshot } }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        scroll.documentView = Self.makeTextView(snapshot)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        if let view = scroll.documentView as? NSTextView { Self.update(view, snapshot: snapshot) }
    }
}
