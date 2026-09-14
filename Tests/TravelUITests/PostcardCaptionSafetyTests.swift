import CoreGraphics
import AppKit
import SwiftUI
import ImageIO
import XCTest
import TravelCore
@testable import TravelUI

final class PostcardCaptionSafetyTests: XCTestCase {
    func testUnknownAnalysisDoesNotDrawDecorationsOverAnUnknownSubject() {
        for (profile, size) in sizes {
            let layout = resolve(nil, profile: profile, size: size)
            XCTAssertFalse(layout.showsLocationLabel)
            XCTAssertEqual(layout.messagePlacement, .belowImage)
            XCTAssertEqual(layout.pawSignature.placement.mode, .omitted)
        }
    }

    func testFullFrameAnimalCannotFallBackToTextOnItsFace() {
        for (profile, size) in sizes {
            let layout = resolve(analysis(CGRect(x: 0, y: 0, width: 1, height: 1)), profile: profile, size: size)
            XCTAssertFalse(layout.showsLocationLabel)
            XCTAssertEqual(layout.messagePlacement, .belowImage)
            XCTAssertEqual(layout.pawSignature.placement.mode, .omitted)
        }
    }

    func testRightHandCatLeavesTheLeftSideAvailable() {
        let cat = CGRect(x: 0.48, y: 0.35, width: 0.5, height: 0.65)
        for (profile, size) in sizes {
            let layout = resolve(analysis(cat).protecting(cat), profile: profile, size: size)
            if layout.messagePlacement == .onImage {
                let message = PostcardOverlayGeometry.rect(for: layout.messageRegion, profile: profile)
                XCTAssertFalse(message.intersects(cat))
            }
            XCTAssertFalse(layout.locationSafetyRect.intersects(cat))
        }
    }

    func testGenericAnimalElsewhereDoesNotCertifyAnUnrecognizedCatIsSafe() {
        let otherAnimal = analysis(CGRect(x: 0.05, y: 0.05, width: 0.15, height: 0.15))
        for (profile, size) in sizes {
            XCTAssertEqual(resolve(otherAnimal, profile: profile, size: size).messagePlacement, .belowImage)
        }
    }

    func testForegroundRegionsRemainProtectedAfterAspectFillAndPreviewAugmentation() {
        let foreground = CGRect(x: 0.5, y: 0.4, width: 0.4, height: 0.5)
        let original = PostcardVisualAnalysis(salientRegions: [],
            samples: .uniform(luminance: 0.4, red: 0.4, green: 0.4, blue: 0.4),
            foregroundRegions: [foreground])
        for (profile, size) in sizes {
            let transform = PostcardAspectFillTransform(imageSize: CGSize(width: 1000, height: 1000), containerSize: size)
            let displayed = transform.displayAnalysis(original)
            let expected = transform.displayRect(forImageNormalized: foreground)
            XCTAssertEqual(displayed.foregroundRegions, [expected])
            XCTAssertEqual(displayed.protecting(CGRect(x: 0.9, y: 0.9, width: 0.1, height: 0.1)).foregroundRegions, [expected])
            let layout = resolve(displayed, profile: profile, size: size)
            if layout.messagePlacement == .onImage {
                XCTAssertFalse(PostcardOverlayGeometry.rect(for: layout.messageRegion, profile: profile).intersects(expected))
            }
        }
    }

    func testCompletelyOccupiedForegroundStillUsesBelowImageFallback() {
        let full = PostcardVisualAnalysis(salientRegions: [],
            samples: .uniform(luminance: 0.4, red: 0.4, green: 0.4, blue: 0.4),
            foregroundRegions: [CGRect(x: 0, y: 0, width: 1, height: 1)])
        for (profile, size) in sizes {
            XCTAssertEqual(resolve(full, profile: profile, size: size).messagePlacement, .belowImage)
        }
    }

    func testAttentionAndSceneryHeuristicsAloneCannotCertifyTheCatIsSafe() {
        for source in [PostcardSaliencySource.attention, .heuristic] {
            let uncertain = PostcardVisualAnalysis(
                salientRegions: [.init(rect: CGRect(x: 0, y: 0, width: 0.2, height: 0.2), weight: 0.9, source: source)],
                samples: .uniform(luminance: 0.5, red: 0.5, green: 0.5, blue: 0.5))
            XCTAssertEqual(resolve(uncertain, profile: .detail, size: sizes[0].1).messagePlacement, .belowImage)
        }
    }

    @MainActor
    func testProvidedPostcardAvoidsItsKnownCatFaceAfterAspectFill() throws {
        guard let path = ProcessInfo.processInfo.environment["TRAVEL_CAT_CAPTION_FIXTURE"] else {
            throw XCTSkip("Set TRAVEL_CAT_CAPTION_FIXTURE to check a user-provided original without copying it into the repository")
        }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let rawAnalysis = try PostcardVisualAnalyzer.analyze(image)
        // The supplied garden postcard: full cat head (ears included), not just eyes.
        let imageHead = CGRect(x: 0.47, y: 0.44, width: 0.35, height: 0.31)
        for (profile, size) in sizes {
            let transform = PostcardAspectFillTransform(imageSize: CGSize(width: image.width, height: image.height), containerSize: size)
            let layout = resolve(transform.displayAnalysis(rawAnalysis), profile: profile, size: size)
            XCTAssertEqual(layout.messagePlacement, .onImage, "The garden has usable whitespace away from the cat")
            let head = transform.displayRect(forImageNormalized: imageHead)
            if layout.messagePlacement == .onImage {
                XCTAssertFalse(PostcardOverlayGeometry.rect(for: layout.messageRegion, profile: profile).intersects(head))
                XCTAssertFalse(layout.locationSafetyRect.intersects(head))
                let messageFrame = PostcardOverlayPresentation.frame(for: layout.messageRegion, profile: profile, containerSize: size)
                let padding: CGFloat = profile == .detail ? 10 : 4
                let textRenderer = ImageRenderer(content: Text("一盏灯，一杯茶，刚好安放夜色。")
                    .font(Font(layout.messageFont)).fontWeight(.semibold)
                    .lineLimit(layout.messageLineLimit).lineSpacing(layout.messageLineSpacing)
                    .frame(width: messageFrame.width - 2 * padding)
                    .fixedSize(horizontal: false, vertical: true))
                let textImage = try XCTUnwrap(textRenderer.cgImage)
                XCTAssertLessThanOrEqual(CGFloat(textImage.height), messageFrame.height - 2 * padding,
                    "Complete quote must fit the actual SwiftUI text, not be ellipsized")
                print("quote metrics \(profile): \(layout.messageRegion), font \(layout.messageFontSize), actual \(textImage.height), available \(messageFrame.height - 2 * padding)")
                if let output = ProcessInfo.processInfo.environment["TRAVEL_CAT_CAPTION_RENDER_DIR"] {
                    let event = postcardEvent()
                    let rendered = ImageRenderer(content: VStack(alignment: .leading, spacing: 10) {
                        ZStack {
                            Image(decorative: image, scale: 1).resizable().scaledToFill()
                            PostcardArtworkView(event: event, rootURL: nil, height: size.height, profile: profile)
                                .overlay(metadata: .init(event: event), layout: layout, containerSize: size)
                        }.frame(width: size.width, height: size.height).clipped()
                        Text(PostcardDisplayLocation().resolveCompact(event.location)).font(.headline)
                    }.padding(12).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
                    let cgImage = try XCTUnwrap(rendered.cgImage)
                    let data = try XCTUnwrap(NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]))
                    try data.write(to: URL(fileURLWithPath: output).appendingPathComponent("whitespace-\(profile).png"))
                }
            } else {
                let rendered = ImageRenderer(content: PostcardArtworkFrame(height: size.height, profile: profile,
                    caption: "一盏灯，一杯茶，刚好安放夜色。") {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                        .frame(width: size.width, height: size.height).clipped()
                }.frame(width: size.width).padding(12).background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, .dark))
                let cgImage = try XCTUnwrap(rendered.cgImage)
                XCTAssertGreaterThan(cgImage.height, Int(size.height) + 24)
                if let output = ProcessInfo.processInfo.environment["TRAVEL_CAT_CAPTION_RENDER_DIR"] {
                    let data = try XCTUnwrap(NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]))
                    try data.write(to: URL(fileURLWithPath: output).appendingPathComponent("caption-\(profile).png"))
                }
            }
            print("provided postcard \(profile): \(layout.messagePlacement)")
        }
    }

    @MainActor
    func testCaptionGrowsBelowImageWithoutChangingOrClippingArtworkHeight() throws {
        for (profile, size) in sizes {
            let plain = ImageRenderer(content: PostcardArtworkFrame(height: size.height, profile: profile, caption: nil) {
                Color.red
            }.frame(width: size.width))
            let captioned = ImageRenderer(content: PostcardArtworkFrame(height: size.height, profile: profile,
                caption: "一盏灯，一杯茶，刚好安放夜色。" + String(repeating: "夜色很好。", count: 20)) {
                Color.red
            }.frame(width: size.width))
            XCTAssertEqual(try XCTUnwrap(plain.cgImage).height, Int(size.height))
            let rendered = try XCTUnwrap(captioned.cgImage)
            XCTAssertGreaterThan(rendered.height, Int(size.height) + 40)
            XCTAssertEqual(rendered.width, Int(size.width))
        }
    }

    @MainActor
    func testCompactFitRetainsReadableTwoLineRegions() throws {
        let message = "湖光和晨风一起把旧码头点亮了。"
        for (region, size) in [(PostcardOverlayRegion.middleTrailing, CGSize(width: 322, height: 120)),
                               (.bottomLeading, CGSize(width: 340, height: 100))] {
            let frame = PostcardOverlayPresentation.frame(for: region, profile: .compact, containerSize: size).insetBy(dx: 4, dy: 4)
            let style = PostcardMoodTypographyResolver().resolve(mood: Mood(level: 0, label: "平静", quote: message))
            let fit = PostcardOverlayTypography.fit(message: message, region: region, profile: .compact, containerSize: size, handwriting: style)
            let font = try XCTUnwrap(PostcardOverlayTypography.measurementFont(fontSize: fit.fontSize, handwriting: style))
            let actual = ImageRenderer(content: Text(message).font(Font(font)).fontWeight(.semibold)
                .lineLimit(2).frame(width: frame.width).fixedSize(horizontal: false, vertical: true))
            let height = try XCTUnwrap(actual.cgImage).height
            print("compact actual \(height), available \(frame.height), font \(fit.fontSize), natural \(font.ascender - font.descender + font.leading)")
            XCTAssertEqual(fit.fitsVertically, CGFloat(height) <= frame.height)
        }
    }

    private var sizes: [(PostcardOverlayProfile, CGSize)] {
        [(.detail, CGSize(width: 520, height: 260)), (.compact, CGSize(width: 260, height: 120))]
    }

    private func analysis(_ cat: CGRect) -> PostcardVisualAnalysis {
        .init(salientRegions: [.init(rect: cat, weight: 0.95, source: .animal)],
              samples: .uniform(luminance: 0.3, red: 0.3, green: 0.3, blue: 0.3))
    }

    private func resolve(_ analysis: PostcardVisualAnalysis?, profile: PostcardOverlayProfile, size: CGSize) -> PostcardOverlayLayout {
        PostcardArtworkLayoutResolver.resolve(metadata: .init(event: postcardEvent()), analysis: analysis,
                                              profile: profile, containerSize: size)
    }

    private func postcardEvent() -> TripEvent {
        TripEvent(id: UUID(), tripID: UUID(), previousEventID: nil,
                              occurredAt: Date(timeIntervalSince1970: 1_700_000_000), phase: .postcardReady,
                              location: Location(country: "China", city: "Suzhou", place: "Master of the Nets Garden"),
                              transport: nil, summary: "夜游园林", mood: Mood(level: 2, label: "惬意", quote: "一盏灯，一杯茶，刚好安放夜色。"),
                              continuityReferences: [], openHook: nil, consumedItemID: nil,
                              postcardStatus: .ready, postcardRelativePath: "postcards/card.png")
    }
}
