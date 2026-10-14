import SwiftUI
import TravelCore
import TravelStorage
import CryptoKit
import AppKit

public enum PostcardArtworkPresentation: Equatable, Sendable {
    case legacy
    case photograph
    case scenic
    /// Keep a bordered card's complete photograph, with text inside its bounds.
    case scenicPhotograph
}

/// Mounting a SwiftUI Image is insufficient: an ordered, unoccluded window and
/// a nonempty intersection with the actual photograph must both be present.
struct PostcardImageVisibilitySnapshot: Equatable, Sendable {
    let windowIsVisible: Bool
    let windowIsMiniaturized: Bool
    let windowIsOccluded: Bool
    let windowIsClosing: Bool
    let viewIsHidden: Bool
    let imageRect: CGRect
    let visibleRect: CGRect

    var canReportVisibility: Bool {
        guard windowIsVisible, !windowIsMiniaturized, !windowIsOccluded,
              !windowIsClosing, !viewIsHidden else { return false }
        let intersection = imageRect.intersection(visibleRect)
        return !intersection.isNull && !intersection.isEmpty
            && intersection.width.isFinite && intersection.height.isFinite
    }
}

@MainActor
struct PostcardImageVisibilityObserver: NSViewRepresentable {
    let requestID: String
    let imageRect: CGRect
    let onVisible: () -> Void

    func makeNSView(context: Context) -> PostcardImageVisibilityTrackingView {
        let view = PostcardImageVisibilityTrackingView()
        view.configure(requestID: requestID, imageRect: imageRect, onVisible: onVisible)
        return view
    }

    func updateNSView(_ view: PostcardImageVisibilityTrackingView, context: Context) {
        view.configure(requestID: requestID, imageRect: imageRect, onVisible: onVisible)
    }

    static func dismantleNSView(_ view: PostcardImageVisibilityTrackingView, coordinator: ()) {
        view.invalidate()
    }
}

@MainActor
final class PostcardImageVisibilityTrackingView: NSView {
    private var requestID = ""
    private var imageRect = CGRect.zero
    private var onVisible: (() -> Void)?
    private var hasReported = false
    private var isClosing = false
    private var isActive = true
    private var checkIsScheduled = false

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(requestID: String, imageRect: CGRect, onVisible: @escaping () -> Void) {
        if self.requestID != requestID { hasReported = false }
        self.requestID = requestID
        self.imageRect = imageRect
        self.onVisible = onVisible
        scheduleVisibilityCheck()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        isClosing = false
        observeHierarchy()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        observeHierarchy()
    }

    override func viewDidHide() { super.viewDidHide(); scheduleVisibilityCheck() }
    override func viewDidUnhide() { super.viewDidUnhide(); scheduleVisibilityCheck() }
    override func layout() { super.layout(); scheduleVisibilityCheck() }

    func invalidate() {
        isActive = false
        onVisible = nil
        NotificationCenter.default.removeObserver(self)
    }

    private func observeHierarchy() {
        NotificationCenter.default.removeObserver(self)
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
                         NSWindow.didBecomeMainNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification, NSWindow.didExposeNotification,
                         NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                         NSWindow.didUpdateNotification, NSWindow.willCloseNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowChanged(_:)),
                    name: name, object: window)
            }
        }
        var ancestor: NSView? = self
        while let view = ancestor {
            view.postsBoundsChangedNotifications = true
            view.postsFrameChangedNotifications = true
            for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(geometryChanged(_:)),
                    name: name, object: view)
            }
            ancestor = view.superview
        }
        scheduleVisibilityCheck()
    }

    @objc private func windowChanged(_ notification: Notification) {
        if notification.name == NSWindow.willCloseNotification { isClosing = true }
        else if window?.isVisible == false { isClosing = false }
        scheduleVisibilityCheck()
    }

    @objc private func geometryChanged(_ notification: Notification) { scheduleVisibilityCheck() }

    private func scheduleVisibilityCheck() {
        guard isActive, !checkIsScheduled, !hasReported else { return }
        checkIsScheduled = true
        // Recheck after the current layout/window transition, never mutate the model
        // while SwiftUI is updating its NSViewRepresentable hierarchy.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.checkIsScheduled = false
            self.reportIfVisible()
        }
    }

    private func reportIfVisible() {
        guard isActive, !hasReported, let window, let contentView = window.contentView else { return }
        var isTransparent = window.alphaValue <= 0
        var ancestor: NSView? = self
        while let view = ancestor {
            isTransparent = isTransparent || view.alphaValue <= 0 || view.layer?.opacity == 0
            ancestor = view.superview
        }
        let contentVisibleRect = contentView.convert(contentView.visibleRect, to: self)
        let snapshot = PostcardImageVisibilitySnapshot(
            windowIsVisible: window.isVisible, windowIsMiniaturized: window.isMiniaturized,
            windowIsOccluded: !window.occlusionState.contains(.visible), windowIsClosing: isClosing,
            viewIsHidden: isHiddenOrHasHiddenAncestor || isTransparent,
            imageRect: imageRect.intersection(bounds),
            visibleRect: visibleRect.intersection(contentVisibleRect))
        guard snapshot.canReportVisibility else { return }
        hasReported = true
        onVisible?()
    }
}

@MainActor
public struct PostcardScenicArtworkView: View {
    public let event: TripEvent
    public let rootURL: URL?
    public let height: CGFloat?
    public let profile: PostcardOverlayProfile
    public let presentation: PostcardArtworkPresentation

    @State private var image: CGImage?
    @State private var analysis: PostcardVisualAnalysis?
    @State private var analysisFailed = false
    @State private var currentRequestID = ""
    @State private var imageRelativePath: String?
    @State private var loadFailed = false
    private let isPreloaded: Bool
    private let onImageVisible: ((String) -> Void)?

    public init(event: TripEvent, rootURL: URL?, height: CGFloat? = nil, profile: PostcardOverlayProfile,
                onImageVisible: ((String) -> Void)? = nil,
                presentation: PostcardArtworkPresentation = .legacy) {
        self.event = event
        self.rootURL = rootURL
        self.height = height
        self.profile = profile
        self.onImageVisible = onImageVisible
        self.presentation = presentation
        isPreloaded = false
    }

    init(event: TripEvent, rootURL: URL, image: CGImage, analysis: PostcardVisualAnalysis?,
         profile: PostcardOverlayProfile = .detail, presentation: PostcardArtworkPresentation = .legacy) {
        self.event = event
        self.rootURL = rootURL
        height = nil
        self.profile = profile
        self.presentation = presentation
        isPreloaded = true
        onImageVisible = nil
        _image = State(initialValue: image)
        _analysis = State(initialValue: analysis)
    }

    public static func accessibilityText(event: TripEvent) -> String {
        let metadata = PostcardArtworkMetadata(event: event)
        return "\(metadata.spokenLocationLabel)。\(metadata.fullMessage)"
    }

    public var body: some View {
        GeometryReader { proxy in
            let size = photographSize(in: proxy.size)
            let metadata = PostcardArtworkMetadata(event: event)
            let previewCat = Self.previewCatDescriptor(event: event, rootURL: rootURL)
            ZStack {
                Color.blue.opacity(0.12)
                if let image, isPreloaded || currentRequestID == taskID {
                    photograph(image, size: size)
                        .id(taskID)
                    if let previewCat {
                        PreviewBlackCatOverlay(
                            descriptor: previewCat,
                            containerSize: size,
                            profile: profile
                        )
                    }
                    if presentation != .photograph {
                        overlay(metadata: metadata, layout: resolvedLayout(containerSize: size),
                                containerSize: size)
                    }
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: loadFailed ? "photo.badge.exclamationmark" : "photo")
                        Text(placeholderText).font(.caption).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.secondary)
                    .padding(10)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            .frame(width: proxy.size.width, height: proxy.size.height)
            .background(presentation == .scenicPhotograph
                ? Color(red: 0.985, green: 0.968, blue: 0.923) : .clear)
            .clipped()
        }
        .aspectRatio(3.0 / 2.0, contentMode: .fit)
        .frame(height: height)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityText(event: event)
            + ((image == nil && !isPreloaded) ? "。" + placeholderText : ""))
        .task(id: taskID) { if !isPreloaded { await loadArtwork() } }
    }

    private func photographSize(in container: CGSize) -> CGSize {
        guard presentation == .scenicPhotograph, let image else { return container }
        let scale = min(container.width / CGFloat(image.width), container.height / CGFloat(image.height))
        return CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
    }

    @ViewBuilder
    private func photograph(_ image: CGImage, size: CGSize) -> some View {
        if presentation == .photograph || presentation == .scenicPhotograph {
            Image(decorative: image, scale: 1).resizable().scaledToFit()
                .frame(width: size.width, height: size.height)
                .background { imageVisibilityObserver(image: image, containerSize: size) }
                .background(Color(red: 0.985, green: 0.968, blue: 0.923))
        } else {
            Image(decorative: image, scale: 1).resizable().scaledToFill()
                .frame(width: size.width, height: size.height)
                .background { imageVisibilityObserver(image: image, containerSize: size) }
        }
    }

    @ViewBuilder
    private func imageVisibilityObserver(image: CGImage, containerSize: CGSize) -> some View {
        if !isPreloaded, onImageVisible != nil {
            let imageRect: CGRect = {
                guard presentation == .photograph else { return CGRect(origin: .zero, size: containerSize) }
                let scale = min(containerSize.width / CGFloat(image.width),
                                containerSize.height / CGFloat(image.height))
                let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                return CGRect(x: (containerSize.width - size.width) / 2,
                              y: (containerSize.height - size.height) / 2,
                              width: size.width, height: size.height)
            }()
            PostcardImageVisibilityObserver(requestID: taskID, imageRect: imageRect) {
                guard event.postcardStatus == .ready, currentRequestID == taskID,
                      let relativePath = imageRelativePath,
                      relativePath == event.postcardRelativePath else { return }
                onImageVisible?(relativePath)
            }
        }
    }

    private var placeholderText: String {
        if event.postcardStatus == .pendingImage { return "风景图片正在准备" }
        if loadFailed || event.postcardRelativePath == nil || rootURL == nil
            || event.postcardStatus != .ready { return "风景图片暂时不可用" }
        return "正在读取风景图片"
    }

    @ViewBuilder
    private func overlay(
        metadata: PostcardArtworkMetadata,
        layout: PostcardOverlayLayout,
        containerSize: CGSize
    ) -> some View {
        let locationRect = Self.rect(for: layout.locationRect, in: containerSize)
        let messageRect = Self.rect(for: layout.messageRegion, profile: profile, in: containerSize)
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

            if presentation == .scenic || presentation == .scenicPhotograph {
                Text(metadata.visualMessage)
                    .font(Font(layout.messageFont))
                    .foregroundStyle(color(layout.inkStyle.foreground))
                    .lineLimit(2)
                    .lineSpacing(layout.messageLineSpacing)
                    .multilineTextAlignment(.leading)
                    .shadow(color: color(layout.inkStyle.shadow).opacity(layout.inkStyle.shadowOpacity),
                            radius: layout.inkStyle.shadowRadius, y: 1)
                    .padding(profile == .detail ? 10 : 4)
                    .background(color(layout.inkStyle.wash).opacity(layout.inkStyle.washOpacity),
                                in: RoundedRectangle(cornerRadius: profile == .detail ? 5 : 3))
                    .frame(width: messageRect.width, height: messageRect.height, alignment: .topLeading)
                    .position(x: messageRect.midX, y: messageRect.midY)
            } else {
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
                    Text(metadata.visualMessage)
                        .font(Font(layout.messageFont))
                        .fontWeight(metadata.sceneStyle == nil ? .semibold : nil)
                        .foregroundStyle(color(layout.inkStyle.foreground))
                        .lineLimit(2)
                        .lineSpacing(layout.messageLineSpacing)
                        .multilineTextAlignment(.leading)
                        .shadow(
                            color: color(layout.inkStyle.shadow).opacity(layout.inkStyle.shadowOpacity),
                            radius: layout.inkStyle.shadowRadius,
                            y: 1
                        )
                        .padding(profile == .detail ? 10 : 4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(width: messageRect.width, height: messageRect.height)
                .position(x: messageRect.midX, y: messageRect.midY)
            }

            PostcardPawSignatureView(signature: layout.pawSignature)
        }
        .frame(width: containerSize.width, height: containerSize.height, alignment: .topLeading)
    }

    private func resolvedLayout(containerSize: CGSize) -> PostcardOverlayLayout {
        let metadata = PostcardArtworkMetadata(event: event)
        let displayedAnalysis: PostcardVisualAnalysis?
        if let image, let analysis, !analysisFailed {
            let transform = PostcardAspectFillTransform(
                imageSize: CGSize(width: image.width, height: image.height),
                containerSize: containerSize
            )
            displayedAnalysis = transform.displayAnalysis(analysis)
        } else {
            displayedAnalysis = nil
        }

        let resolvedAnalysis: PostcardVisualAnalysis?
        if let previewCat = Self.previewCatDescriptor(event: event, rootURL: rootURL) {
            let frame = previewCat.placement.frame(
                in: containerSize,
                sourceAspectRatio: PreviewBlackCatPlacement.authorizedSourceAspectRatio
            )
            let normalizedCatRect = Self.normalized(frame, in: containerSize)
            let baseAnalysis = displayedAnalysis ?? PostcardVisualAnalysis(
                salientRegions: [],
                samples: .uniform(luminance: 0.5, red: 0.5, green: 0.5, blue: 0.5)
            )
            resolvedAnalysis = baseAnalysis.protecting(normalizedCatRect)
        } else {
            resolvedAnalysis = displayedAnalysis
        }

        if presentation == .scenic || presentation == .scenicPhotograph {
            let handwriting = PostcardScenicTypography.handwriting()
            guard let resolvedAnalysis else {
                return PostcardOverlaySolver.unknownFallback(message: metadata.visualMessage,
                    profile: profile, containerSize: containerSize, handwriting: handwriting)
            }
            return PostcardOverlaySolver.solve(analysis: resolvedAnalysis,
                locationLabel: metadata.locationLabel, message: metadata.visualMessage,
                profile: profile, containerSize: containerSize, handwriting: handwriting)
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
        imageRelativePath = nil
        analysis = nil
        analysisFailed = false
        loadFailed = false
        guard let relativePath = event.postcardRelativePath, let rootURL,
              presentation == .legacy || event.postcardStatus == .ready else { return }
        do {
            let artwork = try await PostcardImageCache.shared.artwork(relativePath: relativePath, rootURL: rootURL)
            let loaded = artwork.image
            try Task.checkCancellation()
            guard PostcardArtworkLoadIdentity.shouldPublish(requestID: requestID, currentID: currentRequestID) else { return }
            image = loaded
            imageRelativePath = relativePath
            if presentation == .photograph { return }
            do {
                let result = try await PostcardAnalysisCache.shared.analysis(
                    for: loaded, rootURL: rootURL, relativePath: relativePath, contentHash: artwork.contentHash
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
            imageRelativePath = nil
            loadFailed = true
        }
    }

    private var taskID: String {
        PostcardArtworkLoadIdentity.requestID(event: event, rootURL: rootURL)
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

    private static func isTrailing(_ region: PostcardOverlayRegion) -> Bool {
        region == .topTrailing
            || region == .middleTrailing
            || region == .bottomTrailing
            || region == .wideMiddleTrailing
            || region == .wideBottomTrailing
            || region == .locationBottomTrailing
    }

    private static func alignment(for region: PostcardOverlayRegion) -> Alignment {
        isTrailing(region) ? .trailing : .leading
    }

    private func color(_ ink: PostcardInkColor) -> Color {
        Color(red: ink.red, green: ink.green, blue: ink.blue)
    }
}
