import AppKit
import SwiftUI
import TravelUI

@MainActor
final class MailboxViewState: ObservableObject {
    @Published var inbox = MailboxInbox(entries: [])
}

struct MailboxButtonView: View {
    @ObservedObject var state: MailboxViewState
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                MailboxArtwork(hasMail: !state.inbox.entries.isEmpty, multiple: state.inbox.entries.count > 1)
                if let badge = state.inbox.badge {
                    Text(badge).font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(CottageTheme.card).padding(.horizontal, 5).padding(.vertical, 3)
                        .background(CottageTheme.terracotta, in: Capsule())
                        .overlay(Capsule().stroke(CottageTheme.paper, lineWidth: 1))
                }
            }.frame(width: 76, height: 102).contentShape(Rectangle())
        }.buttonStyle(.plain)
        .accessibilityLabel(state.inbox.entries.isEmpty ? "小黑的邮筒，暂无新消息" : "小黑的邮筒，\(state.inbox.entries.count) 条消息")
        .accessibilityHint("单击打开明信片与 Agent 消息；拖动调整相对小屋的位置")
        .help(state.inbox.entries.isEmpty ? "暂无新消息 · 打开邮筒" : "\(state.inbox.entries.count) 条消息 · 打开邮筒")
    }
}

struct MailboxArtwork: View {
    let hasMail: Bool
    let multiple: Bool
    var body: some View {
        ZStack {
            PetMailboxAssetView().frame(width: 76, height: 100)
            if hasMail {
                if multiple { envelope.rotationEffect(.degrees(-13)).offset(x: -5, y: -13) }
                envelope.rotationEffect(.degrees(8)).offset(x: 1, y: -12)
            }
            // A raised flag is a shape cue as well as a color cue. No idle flashing.
            VStack(alignment: .leading, spacing: 0) {
                RoundedRectangle(cornerRadius: 2).fill(CottageTheme.terracotta).frame(width: 14, height: 10)
                Rectangle().fill(CottageTheme.wood).frame(width: 3, height: 16)
            }.rotationEffect(.degrees(hasMail ? 0 : 95), anchor: .bottomLeading).offset(x: 24, y: -24)
        }.accessibilityHidden(true)
    }
    private var envelope: some View {
        Image(systemName: "envelope.fill").font(.system(size: 21))
            .foregroundStyle(CottageTheme.paper).shadow(color: CottageTheme.wood.opacity(0.7), radius: 1, y: 1)
            .overlay(Image(systemName: "envelope").font(.system(size: 21)).foregroundStyle(CottageTheme.wood))
    }
}

struct MailboxInboxView: View {
    @ObservedObject var state: MailboxViewState
    let open: (String) -> Void
    let openAgents: () -> Void
    let openAlbum: () -> Void
    let close: () -> Void
    @State private var selection: String?
    init(state: MailboxViewState, open: @escaping (String) -> Void, openAgents: @escaping () -> Void,
         openAlbum: @escaping () -> Void, close: @escaping () -> Void) {
        self.state = state; self.open = open; self.openAgents = openAgents; self.openAlbum = openAlbum; self.close = close
        _selection = State(initialValue: state.inbox.singleEntry?.id)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "envelope.open.fill").foregroundStyle(CottageTheme.moss)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("小黑的邮筒").font(CottageTheme.title)
                        Text(state.inbox.entries.isEmpty ? "今天也有安静的好时光" : "\(state.inbox.entries.count) 条消息，等你慢慢打开")
                            .font(.caption).foregroundStyle(CottageTheme.mutedInk)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(MailboxWindowDragHandle())
                    .help("拖动顶部可调整消息列表的位置")
                Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.plain).help("关闭邮筒").accessibilityLabel("关闭邮筒")
            }
            Divider().overlay(CottageTheme.border.opacity(0.6))
            ScrollView {
                if let selection, let entry = state.inbox.entries.first(where: { $0.id == selection }) {
                    VStack(alignment: .leading, spacing: 12) {
                        if state.inbox.entries.count > 1 { Button("返回全部消息") { self.selection = nil }.buttonStyle(.plain) }
                        Label(entry.kind == .postcard ? "远方来信" : entry.kind == .approval ? "需要你确认" : "Agent 来信", systemImage: entry.symbol)
                            .font(CottageTheme.heading).foregroundStyle(entry.kind == .approval || entry.kind == .failure ? CottageTheme.terracotta : CottageTheme.moss)
                        Text(verbatim: entry.title).font(CottageTheme.heading).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Text(entry.subtitle).font(.caption).foregroundStyle(CottageTheme.mutedInk)
                        Text(entry.kind == .approval ? "先查看提交内容和所需权限，再决定是否允许。打开这封信不会自动批准。" : entry.kind == .postcard ? "小黑把沿途的风景留在了明信片里。阅读后，这条未读提示会更新。" : "打开任务查看结果、了解异常，或继续对话。")
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                        Button(entry.kind == .postcard ? "阅读明信片" : entry.kind == .approval ? "查看任务并确认" : "查看任务与对话") { open(entry.id) }
                            .buttonStyle(.borderedProminent)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(16).cottageCard(warning: entry.kind == .approval || entry.kind == .failure)
                } else if state.inbox.entries.isEmpty {
                    VStack(spacing: 12) {
                        MailboxArtwork(hasMail: false, multiple: false).frame(width: 76, height: 104)
                        Text("暂无新消息").font(CottageTheme.heading)
                        Text("明信片、任务结果和需要确认的事，都会送到这里。")
                            .font(.callout).foregroundStyle(CottageTheme.mutedInk).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity).padding(20)
                } else {
                    LazyVStack(spacing: 9) {
                        ForEach(state.inbox.entries) { entry in
                            Button { selection = entry.id } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: entry.symbol).foregroundStyle(entry.kind == .approval || entry.kind == .failure ? CottageTheme.terracotta : CottageTheme.moss).frame(width: 22)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(verbatim: entry.title).font(CottageTheme.heading).lineLimit(2)
                                        Text(entry.subtitle).font(.caption).foregroundStyle(CottageTheme.mutedInk)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right").font(.caption)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(12).cottageCard()
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }.frame(maxHeight: .infinity)
            Divider().overlay(CottageTheme.border.opacity(0.6))
            HStack {
                Button("Agent 工作台 · 发起任务", action: openAgents)
                Spacer()
                Button("旅行册", action: openAlbum)
            }.font(.callout)
        }.padding(20).frame(width: 390, height: 430).cottageSurface()
        .onChange(of: state.inbox.entries.map(\.id)) { _, ids in
            if let selection, !ids.contains(selection) { self.selection = nil }
        }
    }
}

/// The header has a real AppKit drag region; controls and scroll content retain their own hit testing.
private struct MailboxWindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> DragRegion { DragRegion() }
    func updateNSView(_ nsView: DragRegion, context: Context) {}
    final class DragRegion: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            NSCursor.closedHand.push()
            window.performDrag(with: event)
            NSCursor.pop()
        }
    }
}
