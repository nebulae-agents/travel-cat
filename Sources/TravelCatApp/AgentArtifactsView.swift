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
        if let text = WorkbenchArtifactText.decode(bytes) {
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
    @State private var comparison: WorkbenchArtifactComparison?
    private var currentFile: WorkbenchArtifact? { model.artifactInventories[taskID]?.files.first { $0.path == preview?.artifact.path } }
    private var previewStatus: WorkbenchArtifactPreview.VersionStatus { preview?.versionStatus(current:currentFile) ?? .unverified }

    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text("任务制品").font(CottageTheme.title)
                Spacer()
                Button("刷新",systemImage:"arrow.clockwise") { refresh() }.disabled(busy)
                Button("关闭") { generation = UUID(); dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("相对实际提交前的 SHA 基线核对变化，不代表作者归属。单文件最多读取 4 MiB；只在提交任务或主动读取时扫描。")
                .font(.caption).foregroundStyle(CottageTheme.mutedInk)
            if let inventory = model.artifactInventories[taskID] {
                Text(inventory.notice).font(.caption).foregroundStyle(CottageTheme.mutedInk)
            }
            HSplitView {
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:5) {
                        ForEach(files) { file in
                            Button { select(file) } label: {
                                VStack(alignment:.leading,spacing:3) {
                                    Text(file.path).lineLimit(2).multilineTextAlignment(.leading)
                                    Text(file.changeLabel + " · " + ByteCountFormatter.string(fromByteCount:Int64(file.size),countStyle:.file)).font(.caption).foregroundStyle(CottageTheme.mutedInk)
                                    if file.sha256 == nil { Text("SHA 未核实" + (file.readable ? "" : " · 仅元数据")).font(.caption2).foregroundStyle(CottageTheme.mutedInk) }
                                }.frame(maxWidth:.infinity,alignment:.leading).padding(8)
                                    .background(selected == file.path ? CottageTheme.moss.opacity(0.12) : Color.clear).clipShape(RoundedRectangle(cornerRadius:8))
                            }.buttonStyle(.plain).disabled(busy || !file.readable)
                        }
                        if files.isEmpty && !busy { Text("暂无可读取的文件").font(.callout).foregroundStyle(CottageTheme.mutedInk).padding(8) }
                    }
                }.frame(minWidth:150,idealWidth:210,maxWidth:270)
                VStack(alignment:.leading,spacing:8) {
                    if let preview, let presentation {
                        Text(preview.artifact.path).font(CottageTheme.heading).lineLimit(2).textSelection(.enabled)
                        Text("预览 SHA：" + preview.sha256).font(.caption2).textSelection(.enabled).lineLimit(2)
                        if previewStatus == .old {
                            HStack {
                                Text("当前文件已变化，下面保留的是旧预览。下载仍保存旧字节。").font(.caption).foregroundStyle(CottageTheme.terracotta)
                                Button("读取新版本") { if let currentFile { select(currentFile) } }.disabled(busy)
                                Button("比较新版本") { compareLatest() }.disabled(busy)
                            }
                        } else if previewStatus == .unverified {
                            Text("当前 SHA 未核实；此处是已读取的预览，刷新后可重新核对。").font(.caption).foregroundStyle(CottageTheme.mutedInk)
                        }
                        if let comparison {
                            HStack { Text("已查看版本比较").font(.caption); Spacer(); Button("返回预览") { self.comparison = nil } }
                            ReadOnlyArtifactText(text:comparison.text).frame(maxWidth:.infinity,maxHeight:.infinity).background(CottageTheme.card)
                        } else { previewContent(presentation).frame(maxWidth:.infinity,maxHeight:.infinity) }
                        history(path:preview.artifact.path)
                        Text("确认前会重新读取当前 SHA；确认记录按路径和 SHA 保留，与审批、已读和执行完成分别保存。")
                            .font(.caption).foregroundStyle(CottageTheme.mutedInk)
                        HStack {
                            if presentation.canConfirm {
                                Button(model.isArtifactConfirmed(taskID:taskID,preview:preview) ? "此版本已确认" : "确认此版本") { confirm(preview) }
                                    .disabled(busy || comparison != nil || previewStatus == .old || model.isArtifactConfirmed(taskID:taskID,preview:preview))
                            }
                            Spacer()
                            Button(previewStatus == .old ? "下载旧预览版本" : "下载预览版本",systemImage:"arrow.down.to.line") { download(preview) }.disabled(busy)
                        }
                    } else {
                        Spacer(); Text(busy ? "正在读取…" : "选择一个文件进行只读预览").foregroundStyle(CottageTheme.mutedInk).frame(maxWidth:.infinity); Spacer()
                    }
                }.padding(.leading,10).frame(minWidth:280)
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
            if busy { ProgressView().controlSize(.small) }
            if let issue { Text(issue).font(.callout).foregroundStyle(CottageTheme.terracotta).textSelection(.enabled) }
            if let notice { Text(notice).font(.callout).foregroundStyle(CottageTheme.moss) }
            if let reason = model.artifactHistoryNotice[taskID] { Text(reason).font(.caption).foregroundStyle(CottageTheme.mutedInk) }
        }.padding(18).frame(minWidth:540,idealWidth:780,maxWidth:820,minHeight:380,idealHeight:580,maxHeight:620)
            .cottageSurface().onAppear { refresh() }.onDisappear { generation = UUID() }
            .onChange(of:taskID) { _,_ in generation = UUID(); busy = false; files = []; selected = nil; preview = nil; presentation = nil; comparison = nil; refresh() }
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
        let token = UUID(); generation = token; let id = taskID
        Task { @MainActor in
            do { let result = try await model.listArtifacts(taskID:id); guard generation == token, taskID == id else { return }; files = result }
            catch { guard generation == token, taskID == id else { return }; files = []; issue = error.localizedDescription }
            if generation == token { busy = false }
        }
    }
    private func select(_ file: WorkbenchArtifact) {
        guard !busy else { return }; busy = true; issue = nil; notice = nil
        if selected != file.path { preview = nil; presentation = nil }
        selected = file.path; comparison = nil
        let token = UUID(); generation = token; let id = taskID
        Task { @MainActor in
            do {
                let result = try await model.loadArtifact(taskID:id,artifact:file)
                guard generation == token, taskID == id, selected == file.path else { return }
                preview = result; presentation = .decode(result); pageIndex = 0
                do { try model.rememberArtifactPreview(taskID:id,preview:result) }
                catch { issue = "预览已读取，但查看历史未保存：" + error.localizedDescription }
            } catch { guard generation == token, taskID == id else { return }; issue = error.localizedDescription }
            if generation == token { busy = false }
        }
    }
    @ViewBuilder private func history(path: String) -> some View {
        let versions = model.artifactHistory(taskID:taskID,path:path)
        let confirmations = model.state.tasks.first { $0.id == taskID }?.artifactReviews?.filter { $0.path == path } ?? []
        DisclosureGroup("最近两次已查看版本（较旧确认只保留 SHA 元数据）") {
            VStack(alignment:.leading,spacing:5) {
                ForEach(versions) { version in
                    HStack {
                        Text(String(version.sha256.prefix(12)) + " · " + version.viewedAt.formatted(date:.abbreviated,time:.shortened)).font(.caption).textSelection(.enabled)
                        if let preview { Button("与预览比较") { comparison = .compare(old:version,current:preview) }.disabled(busy) }
                        if version.text != nil {
                            Button("查看已存正文") {
                                issue = nil; notice = nil
                                do {
                                    try model.viewSavedArtifactVersion(taskID:taskID,version:version) { saved in
                                        preview = saved; selected = path; presentation = .decode(saved); comparison = nil; pageIndex = 0
                                    }
                                } catch { issue = "历史正文查看记录未能更新：" + error.localizedDescription }
                            }.disabled(busy)
                        } else { Text("仅元数据").font(.caption).foregroundStyle(CottageTheme.mutedInk) }
                    }
                }
                if versions.isEmpty { Text("尚无已保存的查看历史。").font(.caption) }
                Text("正文每个文件最多 256 KiB；总计 2 MiB。二进制、图片和 PDF 仅保存 SHA、大小；历史不代表完整任务差异。").font(.caption2).foregroundStyle(CottageTheme.mutedInk)
                if !confirmations.isEmpty {
                    Text("已确认 \(confirmations.count) 个内容版本；确认 SHA 独立保留。").font(.caption)
                }
            }.padding(.top,4)
        }.font(.caption)
    }
    private func compareLatest() {
        guard !busy, let old = preview, let file = currentFile else { return }
        busy = true; issue = nil; let token = generation; let id = taskID
        Task { @MainActor in
            do {
                let current = try await model.loadArtifact(taskID:id,artifact:file)
                guard generation == token, taskID == id, preview == old else { return }
                let saved = WorkbenchArtifactVersion(path:old.artifact.path,sha256:old.sha256,size:old.bytes.count,viewedAt:Date(),text:WorkbenchArtifactText.savedText(old),reason:nil)
                comparison = .compare(old:saved,current:current)
                do { try model.rememberArtifactPreview(taskID:id,preview:current) }
                catch { issue = "比较已读取，但查看历史未保存：" + error.localizedDescription }
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
