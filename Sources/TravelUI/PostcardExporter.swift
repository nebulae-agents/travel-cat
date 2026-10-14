import AppKit
import ImageIO
import SwiftUI
import TravelCore
import UniformTypeIdentifiers

public enum PostcardExportError: Error { case unavailable, invalidImage, renderFailed }

@MainActor
public enum PostcardExporter {
    static func isInsideDataRoot(_ url: URL, rootURL: URL) -> Bool {
        let sourceRoot = rootURL.standardizedFileURL.resolvingSymlinksInPath().path
        // Foundation normalizes existing /private/var directories differently from
        // a not-yet-created file. Resolve the existing parent before adding its name.
        let parentResolved = url.deletingLastPathComponent().standardizedFileURL
            .resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).path
        let fullyResolved = url.standardizedFileURL.resolvingSymlinksInPath().path
        return [parentResolved, fullyResolved].contains {
            $0 == sourceRoot || $0.hasPrefix(sourceRoot + "/")
        }
    }

    public static func pngData(event: TripEvent, rootURL: URL, face: PostcardFace = .scenic,
        recipient: PostcardRecipientInfo = .empty, travelDate: Date? = nil) async throws -> Data {
        try Task.checkCancellation()
        return try await pngData(event: event, rootURL: rootURL, face: face,
            recipient: recipient, travelDate: travelDate,
            homeLocation: face == .message ? PostcardPostage.homeLocation(rootURL: rootURL) : nil)
    }

    // The on-screen export action supplies its exact snapshot, including nil.
    // A home-city change during the save dialog must not change the printed postage.
    static func pngData(event: TripEvent, rootURL: URL, face: PostcardFace = .scenic,
        recipient: PostcardRecipientInfo = .empty, travelDate: Date? = nil,
        homeLocation: HomeLocation?) async throws -> Data {
        try Task.checkCancellation()
        if face == .message {
            return try renderPNG(PostcardMessageFaceView(event: event, recipient: recipient,
                travelDate: travelDate, isUnread: false, homeLocation: homeLocation))
        }
        guard event.postcardStatus == .ready, let path = event.postcardRelativePath else { throw PostcardExportError.unavailable }
        let style = PostcardScenicStyle.resolve(event: event)
        let preparation = Task.detached {
            try Task.checkCancellation()
            let data = try PostcardImageLoader.loadData(relativePath: path, rootURL: rootURL)
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let type = CGImageSourceGetType(source) as String?,
                  [UTType.png.identifier, UTType.webP.identifier].contains(type),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
                throw PostcardExportError.invalidImage
            }
            do { try PostcardImageDecoder.validateDimensions(width: width, height: height) }
            catch { throw PostcardExportError.invalidImage }
            try Task.checkCancellation()
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1536,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw PostcardExportError.invalidImage
            }
            try Task.checkCancellation()
            let analysis = try? PostcardVisualAnalyzer.analyze(image)
            return (image, analysis)
        }
        let prepared = try await withTaskCancellationHandler {
            try await preparation.value
        } onCancel: {
            preparation.cancel()
        }
        try Task.checkCancellation()
        return try renderPNG(PostcardScenicFaceView(event: event, rootURL: rootURL,
            image: prepared.0, analysis: prepared.1, style: style))
    }

    private static func renderPNG<V: View>(_ face: V) throws -> Data {
        let content = face.frame(width: 768, height: 512)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: 768, height: 512)
        guard let image = renderer.cgImage else { throw PostcardExportError.renderFailed }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw PostcardExportError.renderFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw PostcardExportError.renderFailed }
        return output as Data
    }
}

@MainActor
struct PostcardExportButton: View {
    let event: TripEvent
    let rootURL: URL
    let recipient: PostcardRecipientInfo
    let travelDate: Date?
    let homeLocation: HomeLocation?
    @State private var isExporting = false
    @State private var result = ""
    @State private var showsResult = false
    @State private var task: Task<Void, Never>?

    init(event: TripEvent, rootURL: URL, recipient: PostcardRecipientInfo = .empty,
         travelDate: Date? = nil, homeLocation: HomeLocation?) {
        self.event = event
        self.rootURL = rootURL
        self.recipient = recipient
        self.travelDate = travelDate
        self.homeLocation = homeLocation
    }

    var body: some View {
        Menu {
            Button("导出风景面") { export(face: .scenic) }
                .disabled(event.postcardStatus != .ready || event.postcardRelativePath == nil)
            Button("导出文字面") { export(face: .message) }
        } label: {
            Label(isExporting ? "正在导出" : "导出明信片", systemImage: "square.and.arrow.up")
        }
        .menuStyle(.borderlessButton).disabled(isExporting)
        .alert("导出明信片", isPresented: $showsResult) { Button("好", role: .cancel) {} } message: { Text(result) }
        .onDisappear { task?.cancel() }
    }

    private func export(face: PostcardFace) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Travel Cat-\(event.id.uuidString.prefix(8))-\(face.rawValue).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard !PostcardExporter.isInsideDataRoot(url, rootURL: rootURL) else {
            result = "请保存到旅行数据目录之外，避免覆盖原始记录。"
            showsResult = true
            return
        }
        isExporting = true
        task = Task { @MainActor in
            defer { isExporting = false; task = nil }
            do {
                let data = try await PostcardExporter.pngData(event: event, rootURL: rootURL,
                    face: face, recipient: recipient, travelDate: travelDate, homeLocation: homeLocation)
                try Task.checkCancellation()
                guard !PostcardExporter.isInsideDataRoot(url, rootURL: rootURL) else {
                    result = "请保存到旅行数据目录之外，避免覆盖原始记录。"
                    showsResult = true
                    return
                }
                try data.write(to: url, options: .atomic)
                result = "明信片已导出。"
            } catch is CancellationError { return }
            catch { result = "未能导出，请检查照片文件和保存位置。原始明信片保留。" }
            showsResult = true
        }
    }
}
