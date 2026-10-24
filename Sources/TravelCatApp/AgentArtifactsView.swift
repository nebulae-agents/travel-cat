import SwiftUI
import AppKit
import ImageIO
import PDFKit

// Raster previews never instantiate a web view or follow document links.
private enum ArtifactPresentation {
    case text(String), image(NSImage), pdf(PDFDocument), unsupported(String)
    var canConfirm: Bool { if case .unsupported = self { return false }; return true }
    static func decode(_ preview: WorkbenchArtifactPreview) -> Self {
        let bytes = preview.bytes
        let ext = (preview.artifact.path as NSString).pathExtension.lowercased()
        if ["pdf"].contains(ext) {
            guard bytes.starts(with:Data("%PDF-".utf8)), let document = PDFDocument(data:bytes),
                  !document.isLocked, document.pageCount > 0, document.pageCount <= 500,
                  let page = document.page(at:0), valid(page.bounds(for:.mediaBox)) else {
                return .unsupported("此 PDF 无法安全预览，请下载后核对。")
            }
            return .pdf(document)
        }
        if ["png","jpg","jpeg","gif","tif","tiff","heic","webp","bmp"].contains(ext) {
            guard let source = CGImageSourceCreateWithData(bytes as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                  width.doubleValue > 0, height.doubleValue > 0, width.doubleValue <= 16384, height.doubleValue <= 16384,
                  width.doubleValue * height.doubleValue <= 40_000_000,
                  let image = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:1600,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else {
                return .unsupported("图片尺寸过大或无法安全解码，请下载后核对。")
            }
            return .image(NSImage(cgImage:image,size:.zero))
        }
        if let text = String(data:bytes,encoding:.utf8), !text.unicodeScalars.contains(where:{ $0.value == 0 || ($0.value < 32 && ![9,10,13].contains($0.value)) }) {
            return .text(text)
        }
        return .unsupported("此格式暂不支持内嵌预览，请下载后核对。")
    }
    static func valid(_ rect: CGRect) -> Bool { rect.width.isFinite && rect.height.isFinite && rect.width > 0 && rect.height > 0 && rect.width <= 20000 && rect.height <= 20000 }
}

struct AgentArtifactsView: View {
    @ObservedObject var model: AgentWorkbenchModel
    let taskID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var files: [WorkbenchArtifact] = []
    @State private var selected: String?
    @State private var preview: WorkbenchArtifactPreview?
    @State private var presentation: ArtifactPresentation?
    @State private var busy = false
    @State private var generation = UUID()
    @State private var issue: String?
    @State private var notice: String?
    @State private var pageIndex = 0

    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text("任务制品").font(CottageTheme.title)
                Spacer()
                Button("刷新",systemImage:"arrow.clockwise") { refresh() }.disabled(busy)
                Button("关闭") { generation = UUID(); dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("此任务工作目录的文件，列表不代表全部为本轮新建。单个文件最多 4 MiB。")
                .font(.caption).foregroundStyle(CottageTheme.mutedInk)
            HSplitView {
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:5) {
                        ForEach(files) { file in
                            Button { select(file) } label: {
                                VStack(alignment:.leading,spacing:3) {
                                    Text(file.path).lineLimit(2).multilineTextAlignment(.leading)
                                    Text(ByteCountFormatter.string(fromByteCount:Int64(file.size),countStyle:.file)).font(.caption).foregroundStyle(CottageTheme.mutedInk)
                                }.frame(maxWidth:.infinity,alignment:.leading).padding(8)
                                    .background(selected == file.path ? CottageTheme.moss.opacity(0.12) : Color.clear).clipShape(RoundedRectangle(cornerRadius:8))
                            }.buttonStyle(.plain).disabled(busy)
                        }
                        if files.isEmpty && !busy { Text("暂无可读取的文件").font(.callout).foregroundStyle(CottageTheme.mutedInk).padding(8) }
                    }
                }.frame(minWidth:150,idealWidth:210,maxWidth:270)
                VStack(alignment:.leading,spacing:8) {
                    if let preview, let presentation {
                        Text(preview.artifact.path).font(CottageTheme.heading).lineLimit(2).textSelection(.enabled)
                        previewContent(presentation).frame(maxWidth:.infinity,maxHeight:.infinity)
                        Text("确认只记录此文件的当前内容版本，与任务审批、已读和执行完成分别保存。")
                            .font(.caption).foregroundStyle(CottageTheme.mutedInk)
                        HStack {
                            if presentation.canConfirm {
                                Button(model.isArtifactConfirmed(taskID:taskID,preview:preview) ? "此版本已确认" : "确认此版本") { confirm(preview) }
                                    .disabled(busy || model.isArtifactConfirmed(taskID:taskID,preview:preview))
                            }
                            Spacer()
                            Button("下载预览版本",systemImage:"arrow.down.to.line") { download(preview) }.disabled(busy)
                        }
                    } else {
                        Spacer(); Text(busy ? "正在读取…" : "选择一个文件进行只读预览").foregroundStyle(CottageTheme.mutedInk).frame(maxWidth:.infinity); Spacer()
                    }
                }.padding(.leading,10).frame(minWidth:280)
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
            if busy { ProgressView().controlSize(.small) }
            if let issue { Text(issue).font(.callout).foregroundStyle(CottageTheme.terracotta).textSelection(.enabled) }
            if let notice { Text(notice).font(.callout).foregroundStyle(CottageTheme.moss) }
        }.padding(18).frame(minWidth:540,idealWidth:780,maxWidth:820,minHeight:380,idealHeight:580,maxHeight:620)
            .cottageSurface().onAppear { refresh() }.onDisappear { generation = UUID() }
            .onChange(of:taskID) { _,_ in generation = UUID(); busy = false; files = []; selected = nil; preview = nil; presentation = nil; refresh() }
    }
    @ViewBuilder private func previewContent(_ content: ArtifactPresentation) -> some View {
        switch content {
        case .text(let text): ReadOnlyArtifactText(text:text).background(CottageTheme.card).clipShape(RoundedRectangle(cornerRadius:8))
        case .image(let image):
            VStack { Image(nsImage:image).resizable().scaledToFit(); Text("图片预览为第一帧，按可用空间缩放。").font(.caption).foregroundStyle(CottageTheme.mutedInk) }
        case .pdf(let document):
            VStack {
                if let page = document.page(at:pageIndex), ArtifactPresentation.valid(page.bounds(for:.mediaBox)) {
                    Image(nsImage:page.thumbnail(of:NSSize(width:1100,height:1400),for:.mediaBox)).resizable().scaledToFit()
                } else { Text("此页无法安全预览，请下载核对。") }
                HStack {
                    Button("上一页") { pageIndex -= 1 }.disabled(pageIndex == 0)
                    Text("第 \(pageIndex+1) / \(document.pageCount) 页").font(.caption)
                    Button("下一页") { pageIndex += 1 }.disabled(pageIndex+1 >= document.pageCount)
                }
            }
        case .unsupported(let message): Text(message).foregroundStyle(CottageTheme.mutedInk).frame(maxWidth:.infinity,maxHeight:.infinity)
        }
    }
    private func refresh() {
        guard !busy else { return }; busy = true; issue = nil; notice = nil
        preview = nil; presentation = nil; selected = nil
        let token = UUID(); generation = token; let id = taskID
        Task { @MainActor in
            do { let result = try await model.listArtifacts(taskID:id); guard generation == token, taskID == id else { return }; files = result }
            catch { guard generation == token, taskID == id else { return }; files = []; issue = error.localizedDescription }
            if generation == token { busy = false }
        }
    }
    private func select(_ file: WorkbenchArtifact) {
        guard !busy else { return }; busy = true; issue = nil; notice = nil; selected = file.path; preview = nil; presentation = nil
        let token = UUID(); generation = token; let id = taskID
        Task { @MainActor in
            do {
                let result = try await model.loadArtifact(taskID:id,artifact:file)
                guard generation == token, taskID == id, selected == file.path else { return }
                preview = result; presentation = .decode(result); pageIndex = 0
            } catch { guard generation == token, taskID == id else { return }; issue = error.localizedDescription }
            if generation == token { busy = false }
        }
    }
    private func confirm(_ value: WorkbenchArtifactPreview) {
        guard !busy else { return }; busy = true; issue = nil; notice = nil
        let token = generation; let id = taskID
        Task { @MainActor in
            do { try await model.confirmArtifact(taskID:id,preview:value); guard generation == token, taskID == id else { return }; notice = "此内容版本已确认并保存。" }
            catch { guard generation == token, taskID == id else { return }; issue = error.localizedDescription }
            if generation == token { busy = false }
        }
    }
    private func download(_ value: WorkbenchArtifactPreview) {
        guard !busy else { return }; busy = true; issue = nil; notice = nil; defer { busy = false }
        let panel = NSSavePanel(); panel.nameFieldStringValue = (value.artifact.path as NSString).lastPathComponent
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try model.downloadArtifactPreview(taskID:taskID,preview:value,to:url); notice = "预览版本已保存。" }
        catch { issue = error.localizedDescription }
    }
}
private struct ReadOnlyArtifactText: NSViewRepresentable {
    let text: String
    func makeNSView(context:Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        let view = NSTextView(); view.isEditable = false; view.isSelectable = true
        view.isRichText = false; view.isAutomaticLinkDetectionEnabled = false; view.isAutomaticDataDetectionEnabled = false
        view.font = .monospacedSystemFont(ofSize:12,weight:.regular); view.textContainerInset = NSSize(width:10,height:10)
        view.isVerticallyResizable = true; view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
        scroll.documentView = view; return scroll
    }
    func updateNSView(_ scroll:NSScrollView,context:Context) { if let view = scroll.documentView as? NSTextView, view.string != text { view.string = text } }
}
