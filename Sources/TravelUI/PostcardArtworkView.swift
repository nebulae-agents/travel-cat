import CoreGraphics
import SwiftUI
import TravelCore

struct PostcardLocationLabelContent: View {
    let label: String
    let profile: PostcardOverlayProfile
    let minimumScaleFactor: CGFloat

    init(
        label: String,
        profile: PostcardOverlayProfile,
        minimumScaleFactor: CGFloat = 1
    ) {
        self.label = label
        self.profile = profile
        self.minimumScaleFactor = minimumScaleFactor
    }

    var body: some View {
        HStack(spacing: profile == .detail ? 6 : 3) {
            Image(systemName: "location.fill")
            Text(label)
                .lineLimit(PostcardOverlayGeometry.locationLineLimit(profile: profile))
                .minimumScaleFactor(minimumScaleFactor)
                .allowsTightening(true)
        }
        .font(.system(
            size: PostcardOverlayTypography.locationFontSize(profile: profile),
            weight: .medium
        ))
    }
}

/// The production location renderer. Its fallback is a true two-tone glyph edge:
/// eight opaque one-point copies surround the same HStack used for the foreground.
/// The edge has no material, capsule, or other background surface.
struct PostcardLocationLabelView: View {
    let label: String
    let profile: PostcardOverlayProfile
    let minimumScaleFactor: CGFloat
    let ink: PostcardLocationInkStyle

    private static let edgeOffsets = [
        CGSize(width: -1, height: -1), CGSize(width: 0, height: -1),
        CGSize(width: 1, height: -1), CGSize(width: -1, height: 0),
        CGSize(width: 1, height: 0), CGSize(width: -1, height: 1),
        CGSize(width: 0, height: 1), CGSize(width: 1, height: 1),
    ]

    var body: some View {
        if ink.usesContrastEdgeFallback {
            ZStack {
                ForEach(Self.edgeOffsets.indices, id: \.self) { index in
                    content
                        .foregroundStyle(color(ink.shadow))
                        .offset(Self.edgeOffsets[index])
                }
                content
                    .foregroundStyle(color(ink.foreground))
                    .opacity(ink.opacity)
            }
        } else {
            content
                .foregroundStyle(color(ink.foreground))
                .shadow(
                    color: color(ink.shadow).opacity(ink.shadowOpacity),
                    radius: PostcardOverlayTypography.locationShadowRadius,
                    x: PostcardOverlayTypography.locationShadowOffset.width,
                    y: PostcardOverlayTypography.locationShadowOffset.height
                )
                .opacity(ink.opacity)
        }
    }

    private var content: some View {
        PostcardLocationLabelContent(
            label: label,
            profile: profile,
            minimumScaleFactor: minimumScaleFactor
        )
    }

    private func color(_ ink: PostcardInkColor) -> Color {
        Color(red: ink.red, green: ink.green, blue: ink.blue)
    }
}

public enum PostcardAnalysisCachePolicy {
    public static let maximumItemCount = 8
}

struct PostcardArtworkLoadIdentity {
    static func shouldPublish(requestID: String, currentID: String) -> Bool {
        requestID == currentID
    }
}

struct PostcardAspectFillTransform: Equatable, Sendable {
    let imageSize: CGSize
    let containerSize: CGSize
    let imageFrame: CGRect

    init(imageSize: CGSize, containerSize: CGSize, imageFrame: CGRect? = nil) {
        self.imageSize = imageSize
        self.containerSize = containerSize
        if let imageFrame {
            self.imageFrame = imageFrame
        } else if imageSize.width > 0, imageSize.height > 0,
                  containerSize.width > 0, containerSize.height > 0 {
            let scale = max(
                containerSize.width / imageSize.width,
                containerSize.height / imageSize.height
            )
            let rendered = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            self.imageFrame = CGRect(
                x: (containerSize.width - rendered.width) / 2,
                y: (containerSize.height - rendered.height) / 2,
                width: rendered.width,
                height: rendered.height
            )
        } else {
            self.imageFrame = .zero
        }
    }

    private var geometry: PostcardImageGeometry {
        PostcardImageGeometry(
            imageSize: imageSize,
            containerSize: containerSize,
            imageFrame: imageFrame
        )
    }

    func displayRect(forImageNormalized rect: CGRect) -> CGRect {
        geometry.displayRect(forImageNormalized: rect)
    }

    func imageRect(forDisplayNormalized rect: CGRect) -> CGRect {
        geometry.imageRect(forDisplayNormalized: rect)
    }

    func displayAnalysis(_ analysis: PostcardVisualAnalysis) -> PostcardVisualAnalysis {
        geometry.displayAnalysis(analysis)
    }
}

private struct PostcardAnalysisKey: Hashable, Sendable {
    let rootPath: String
    let relativePath: String
    let pixelWidth: Int
    let pixelHeight: Int
}

private actor PostcardAnalysisCache {
    static let shared = PostcardAnalysisCache()
    private var values: [PostcardAnalysisKey: PostcardVisualAnalysis] = [:]
    private var order: [PostcardAnalysisKey] = []

    func analysis(
        for image: CGImage,
        rootURL: URL,
        relativePath: String
    ) async throws -> PostcardVisualAnalysis {
        let key = PostcardAnalysisKey(
            rootPath: rootURL.standardizedFileURL.path,
            relativePath: relativePath,
            pixelWidth: image.width,
            pixelHeight: image.height
        )
        if let cached = values[key] { return cached }
        try Task.checkCancellation()
        let work = Task.detached { try PostcardVisualAnalyzer.analyze(image) }
        let value = try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
        try Task.checkCancellation()
        if order.count >= PostcardAnalysisCachePolicy.maximumItemCount, let oldest = order.first {
            order.removeFirst()
            values.removeValue(forKey: oldest)
        }
        values[key] = value
        order.append(key)
        return value
    }
}

@MainActor
struct PostcardArtworkFrame<Artwork: View>: View {
    let height: CGFloat
    let profile: PostcardOverlayProfile
    let caption: String?
    var handwriting: PostcardHandwritingStyle = .sereneSystemFallback
    @ViewBuilder let artwork: () -> Artwork

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            artwork().frame(height: height).clipped()
            if let caption {
                Text(caption)
                    .font(Font(PostcardOverlayTypography.measurementFont(
                        fontSize: profile == .detail ? 18 : 13,
                        handwriting: handwriting
                    )!))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
            }
        }
    }
}

@MainActor
public struct PostcardArtworkView: View {
    public let event: TripEvent
    public let rootURL: URL?
    public let height: CGFloat
    public let profile: PostcardOverlayProfile

    @State private var image: CGImage?
    @State private var analysis: PostcardVisualAnalysis?
    @State private var analysisFailed = false
    @State private var currentRequestID = ""
    @State private var messageBelowImage = true

    public init(event: TripEvent, rootURL: URL?, height: CGFloat, profile: PostcardOverlayProfile) {
        self.event = event
        self.rootURL = rootURL
        self.height = height
        self.profile = profile
    }

    public static func accessibilityText(event: TripEvent) -> String {
        let metadata = PostcardArtworkMetadata(event: event)
        return "\(metadata.spokenLocationLabel)。\(metadata.fullMessage)"
    }

    public var body: some View {
        PostcardArtworkFrame(
            height: height,
            profile: profile,
            caption: image != nil && messageBelowImage ? PostcardArtworkMetadata(event: event).visualMessage : nil,
            handwriting: PostcardMoodTypographyResolver().resolve(mood: event.mood)
        ) {
        GeometryReader { proxy in
            let metadata = PostcardArtworkMetadata(event: event)
            let imageGeometry = resolvedImageGeometry(containerSize: proxy.size)
            let visibleCanvas = imageGeometry?.visibleCanvas ?? CGRect(origin: .zero, size: proxy.size)
            let overlayLayout = resolvedLayout(
                containerSize: visibleCanvas.size,
                geometry: imageGeometry
            )
            let previewCat = Self.previewCatDescriptor(event: event, rootURL: rootURL)
            ZStack {
                Color.blue.opacity(0.12)
                if let image, let imageGeometry {
                    PostcardRenderedImage(image: image, geometry: imageGeometry)
                    if let previewCat {
                        PreviewBlackCatOverlay(
                            descriptor: previewCat,
                            containerSize: proxy.size,
                            profile: profile
                        )
                    }
                    if overlayLayout.messagePlacement == .onImage {
                        overlay(
                            metadata: metadata,
                            layout: overlayLayout,
                            containerSize: visibleCanvas.size
                        )
                        .position(x: visibleCanvas.midX, y: visibleCanvas.midY)
                    }
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .onChange(of: overlayLayout.messagePlacement, initial: true) { _, placement in
                messageBelowImage = placement == .belowImage
            }
        }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityText(event: event))
        .task(id: taskID) { await loadArtwork() }
    }

    @ViewBuilder
    func overlay(
        metadata: PostcardArtworkMetadata,
        layout: PostcardOverlayLayout,
        containerSize: CGSize
    ) -> some View {
        let locationRect = Self.rect(for: layout.locationRect, in: containerSize)
        let messageRect = layout.messageFrame(profile: profile, containerSize: containerSize)
        let messageTextLayout = layout.messageTextLayout(
            message: metadata.visualMessage,
            profile: profile,
            containerSize: containerSize
        )
        let locationFit = PostcardOverlayTypography.locationFit(
            label: metadata.locationLabel,
            region: layout.locationRegion,
            profile: profile,
            containerSize: containerSize
        )
        ZStack(alignment: .topLeading) {
            if layout.showsLocationLabel, let locationInk = layout.locationInkStyle {
                PostcardLocationLabelView(
                    label: metadata.locationLabel,
                    profile: profile,
                    minimumScaleFactor: locationFit.minimumScaleFactor,
                    ink: locationInk
                )
                .frame(
                    width: locationRect.width,
                    height: locationRect.height,
                    alignment: Self.alignment(for: layout.locationRegion)
                )
                .position(x: locationRect.midX, y: locationRect.midY)
            }

            ZStack {
                LinearGradient(
                    colors: [
                        color(layout.inkStyle.wash).opacity(layout.inkStyle.washOpacity),
                        color(layout.inkStyle.wash).opacity(layout.inkStyle.washOpacity),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .clipShape(RoundedRectangle(cornerRadius: profile == .detail ? 14 : 9))
            }
            .frame(width: messageRect.width, height: messageRect.height)
            .position(x: messageRect.midX, y: messageRect.midY)

            PostcardMessageTextView(
                layout: messageTextLayout,
                color: color(layout.inkStyle.foreground),
                shadowColor: color(layout.inkStyle.shadow).opacity(layout.inkStyle.shadowOpacity),
                shadowRadius: layout.inkStyle.shadowRadius,
                shadowYOffset: 1
            )

            PostcardPawSignatureView(signature: layout.pawSignature)
        }
        .frame(width: containerSize.width, height: containerSize.height, alignment: .topLeading)
    }

    private func resolvedImageGeometry(containerSize: CGSize) -> PostcardImageGeometry? {
        guard let image else { return nil }
        return PostcardImageGeometry(
            imageSize: CGSize(width: image.width, height: image.height),
            containerSize: containerSize,
            analysis: analysisFailed ? nil : analysis
        )
    }

    private func resolvedLayout(
        containerSize: CGSize,
        geometry: PostcardImageGeometry?
    ) -> PostcardOverlayLayout {
        let metadata = PostcardArtworkMetadata(event: event)
        let displayedAnalysis: PostcardVisualAnalysis?
        if let analysis, !analysisFailed, let geometry {
            displayedAnalysis = geometry.displayAnalysis(analysis)
        } else {
            displayedAnalysis = nil
        }

        let resolvedAnalysis: PostcardVisualAnalysis?
        if let previewCat = Self.previewCatDescriptor(event: event, rootURL: rootURL), let displayedAnalysis {
            let frame = previewCat.placement.frame(
                in: geometry?.containerSize ?? containerSize,
                sourceAspectRatio: PreviewBlackCatPlacement.authorizedSourceAspectRatio
            )
            let visibleCanvas = geometry?.visibleCanvas ?? CGRect(origin: .zero, size: containerSize)
            let normalizedCatRect = Self.normalizedPreviewProtection(
                frame,
                visibleCanvas: visibleCanvas
            )
            resolvedAnalysis = displayedAnalysis.protecting(normalizedCatRect)
        } else {
            resolvedAnalysis = displayedAnalysis
        }

        return PostcardArtworkLayoutResolver.resolve(
            metadata: metadata,
            analysis: resolvedAnalysis,
            profile: profile,
            containerSize: containerSize
        )
    }

    private func loadArtwork() async {
        let requestID = taskID
        currentRequestID = requestID
        image = nil
        analysis = nil
        analysisFailed = false
        messageBelowImage = true
        guard let relativePath = event.postcardRelativePath, let rootURL else { return }
        do {
            let loaded = try await PostcardImageCache.shared.image(relativePath: relativePath, rootURL: rootURL)
            try Task.checkCancellation()
            guard PostcardArtworkLoadIdentity.shouldPublish(requestID: requestID, currentID: currentRequestID) else { return }
            image = loaded
            do {
                let result = try await PostcardAnalysisCache.shared.analysis(
                    for: loaded, rootURL: rootURL, relativePath: relativePath
                )
                try Task.checkCancellation()
                guard PostcardArtworkLoadIdentity.shouldPublish(requestID: requestID, currentID: currentRequestID) else { return }
                analysis = result
            } catch {
                guard !Task.isCancelled,
                      PostcardArtworkLoadIdentity.shouldPublish(requestID: requestID, currentID: currentRequestID) else { return }
                analysisFailed = true
            }
        } catch {
            guard !Task.isCancelled,
                  PostcardArtworkLoadIdentity.shouldPublish(requestID: requestID, currentID: currentRequestID) else { return }
            image = nil
        }
    }

    private var taskID: String {
        (rootURL?.standardizedFileURL.path ?? "") + "\u{0}" + (event.postcardRelativePath ?? "")
    }

    private static func rect(
        for region: PostcardOverlayRegion,
        profile: PostcardOverlayProfile,
        in size: CGSize
    ) -> CGRect {
        PostcardOverlayPresentation.frame(
            for: region,
            profile: profile,
            containerSize: size
        )
    }

    private static func rect(for normalizedRect: CGRect, in size: CGSize) -> CGRect {
        CGRect(
            x: normalizedRect.minX * size.width,
            y: normalizedRect.minY * size.height,
            width: normalizedRect.width * size.width,
            height: normalizedRect.height * size.height
        )
    }

    static func previewCatDescriptor(
        event: TripEvent,
        rootURL: URL?
    ) -> PreviewBlackCatOverlayDescriptor? {
        TravelAlbumPreviewCatalog.overlayDescriptor(event: event, rootURL: rootURL)
    }

    private static func normalized(_ rect: CGRect, in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        return CGRect(
            x: rect.minX / size.width,
            y: rect.minY / size.height,
            width: rect.width / size.width,
            height: rect.height / size.height
        )
    }

    static func normalizedPreviewProtection(
        _ containerRect: CGRect,
        visibleCanvas: CGRect
    ) -> CGRect {
        guard visibleCanvas.width > 0, visibleCanvas.height > 0 else { return .zero }
        let visible = containerRect.intersection(visibleCanvas)
        guard !visible.isNull, !visible.isEmpty else { return .zero }
        return normalized(
            visible.offsetBy(dx: -visibleCanvas.minX, dy: -visibleCanvas.minY),
            in: visibleCanvas.size
        )
    }

    private static func isTrailing(_ region: PostcardOverlayRegion) -> Bool {
        region == .topTrailing
            || region == .middleTrailing
            || region == .bottomTrailing
            || region == .wideMiddleTrailing
            || region == .wideBottomTrailing
            || region == .locationBottomTrailing
            || region == .columnTrailing
    }

    private static func alignment(for region: PostcardOverlayRegion) -> Alignment {
        isTrailing(region) ? .trailing : .leading
    }

    private func color(_ ink: PostcardInkColor) -> Color {
        Color(red: ink.red, green: ink.green, blue: ink.blue)
    }
}
