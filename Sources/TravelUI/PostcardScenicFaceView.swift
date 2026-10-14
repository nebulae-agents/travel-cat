import AppKit
import CoreText
import SwiftUI
import TravelCore

/// Display choices only. Resolving a layout never changes a published event or its photo.
public enum PostcardScenicStyle: String, CaseIterable, Equatable, Sendable {
    case paperBorder
    case fullBleed
    case journal

    public static func resolve(event: TripEvent) -> Self {
        let scene = scene(event: event)
        switch scene.category {
        case .waterside, .garden: return .paperBorder
        case .heritage, .market: return .journal
        case .mountain, .urban: return .fullBleed
        case .everyday: return allCases[scene.compositionVariant]
        }
    }

    static func scene(event: TripEvent) -> PostcardSceneStyle {
        // Reuse the existing scene classifier for historical cards too, without opting
        // their persisted artwork into a new generation version.
        let displayEvent = TripEvent(id: event.id, tripID: event.tripID,
            previousEventID: event.previousEventID, occurredAt: event.occurredAt,
            phase: event.phase, location: event.location, transport: event.transport,
            summary: event.summary, mood: event.mood, continuityReferences: event.continuityReferences,
            openHook: event.openHook, consumedItemID: event.consumedItemID,
            postcardStatus: event.postcardStatus, postcardRelativePath: event.postcardRelativePath,
            postcardStyleVersion: 1)
        return PostcardSceneStyle.resolve(event: displayEvent)!
    }
}

@MainActor
enum PostcardScenicTypography {
    static func handwriting() -> PostcardHandwritingStyle {
        let face = PostcardBundledFontRegistry.face(named: "LXGWWenKaiLite-Regular")
        return .init(family: .serene, fontPostScriptName: face?.postScriptName,
            fontWeight: face?.actualWeight ?? 0, sizeScale: 1, lineSpacing: 1.18, pawOpacity: 0.60)
    }

    static func bodyFont(size: CGFloat) -> NSFont {
        PostcardOverlayTypography.measurementFont(fontSize: size, handwriting: handwriting())!
    }

    static func titleFont(category: PostcardSceneCategory, size: CGFloat,
        lookup: (String, CGFloat) -> NSFont? = { NSFont(name: $0, size: $1) }) -> NSFont {
        let names = category == .heritage
            ? ["STSongti-SC-Regular", "STSong", "SongtiSC-Regular"]
            : ["PingFangSC-Regular", "HiraginoSansGB-W3"]
        for name in names {
            guard let font = lookup(name, max(size, 1)) else { continue }
            var characters = Array("猫旅风景".utf16)
            var glyphs = [CGGlyph](repeating: 0, count: characters.count)
            if CTFontGetGlyphsForCharacters(font as CTFont, &characters, &glyphs, characters.count) { return font }
        }
        return NSFont.systemFont(ofSize: max(size, 1), weight: .regular)
    }

    /// The fitted NSFont is also the one passed to SwiftUI; there is no synthetic weight.
    static func fittedFont(text: String, width: CGFloat, height: CGFloat, preferred: CGFloat,
        minimum: CGFloat, titleCategory: PostcardSceneCategory? = nil) -> NSFont {
        var size = max(preferred, minimum)
        while true {
            let font = titleCategory.map { titleFont(category: $0, size: size) } ?? bodyFont(size: size)
            let bounds = (text as NSString).boundingRect(
                with: CGSize(width: max(width, 1), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
            if bounds.height <= height || size <= minimum { return font }
            size = max(size - 0.5, minimum)
        }
    }
}

/// Shared scenery face used by the album, the flip view and PNG export.
@MainActor
public struct PostcardScenicFaceView: View {
    public static let aspectRatio: CGFloat = 1.5
    public let event: TripEvent
    public let rootURL: URL?
    public let profile: PostcardOverlayProfile
    public let style: PostcardScenicStyle

    private let onImageVisible: ((String) -> Void)?
    private let preparedImage: CGImage?
    private let preparedAnalysis: PostcardVisualAnalysis?
    private let paper = Color(red: 0.985, green: 0.968, blue: 0.923)
    private let ink = Color(red: 0.29, green: 0.27, blue: 0.23)

    public init(event: TripEvent, rootURL: URL?, profile: PostcardOverlayProfile,
                onImageVisible: ((String) -> Void)? = nil) {
        self.event = event
        self.rootURL = rootURL
        self.profile = profile
        self.style = PostcardScenicStyle.resolve(event: event)
        self.onImageVisible = onImageVisible
        self.preparedImage = nil
        self.preparedAnalysis = nil
    }

    init(event: TripEvent, rootURL: URL, image: CGImage, analysis: PostcardVisualAnalysis?,
         style: PostcardScenicStyle? = nil, profile: PostcardOverlayProfile = .detail) {
        self.event = event
        self.rootURL = rootURL
        self.profile = profile
        self.style = style ?? PostcardScenicStyle.resolve(event: event)
        self.onImageVisible = nil
        self.preparedImage = image
        self.preparedAnalysis = analysis
    }

    public var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                paper
                switch style {
                case .fullBleed:
                    artwork(presentation: .scenic)
                        .frame(width: size.width, height: size.height)
                case .paperBorder:
                    insetArtwork(size: size, fraction: 0.035)
                case .journal:
                    insetArtwork(size: size, fraction: 0.055)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            .overlay(Rectangle().strokeBorder(ink.opacity(0.17), lineWidth: 0.6))
        }
        .aspectRatio(Self.aspectRatio, contentMode: .fit)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("风景面，" + PostcardScenicArtworkView.accessibilityText(event: event))
    }

    @ViewBuilder
    private func artwork(presentation: PostcardArtworkPresentation) -> some View {
        if let preparedImage, let rootURL {
            PostcardScenicArtworkView(event: event, rootURL: rootURL, image: preparedImage,
                analysis: preparedAnalysis, profile: profile, presentation: presentation)
        } else {
            PostcardScenicArtworkView(event: event, rootURL: rootURL, profile: profile,
                onImageVisible: onImageVisible, presentation: presentation)
        }
    }

    /// Uniform proportional insets preserve the photograph's 3:2 shape. The
    /// quote and location belong to the picture in all three display styles.
    private func insetArtwork(size: CGSize, fraction: CGFloat) -> some View {
        artwork(presentation: .scenicPhotograph)
            .frame(width: size.width * (1 - fraction * 2),
                   height: size.height * (1 - fraction * 2))
            .overlay(Rectangle().strokeBorder(ink.opacity(0.14), lineWidth: 0.7 * size.width / 640))
            .frame(width: size.width, height: size.height)
    }
}
