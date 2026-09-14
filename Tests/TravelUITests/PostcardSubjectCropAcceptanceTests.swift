import AppKit
import CoreGraphics
import ImageIO
import SwiftUI
import XCTest
import TravelCore
@testable import TravelUI

/// Read-only fixtures; no model request or production repository writer is used.
final class PostcardSubjectCropAcceptanceTests: XCTestCase {
    @MainActor
    func testRetainedSudiPostcardUsesClearLakeSpace() throws {
        guard let path = ProcessInfo.processInfo.environment["TRAVEL_CAT_SUDI_FIXTURE"] else {
            throw XCTSkip("Supply the retained Sudi original to opt in.")
        }
        try exercise(path: path, name: "sudi",
                     knownCat: CGRect(x: 0.17, y: 0.54, width: 0.25, height: 0.38),
                     location: Location(country: "中国", city: "杭州", place: "苏堤"),
                     quote: "今天适合慢一点。", moodLevel: 0, moodLabel: "平静")
    }

    @MainActor
    func testRetainedCompactPostcardKeepsItsCatAndMessageOnImage() throws {
        guard let path = ProcessInfo.processInfo.environment["TRAVEL_CAT_COMPACT_FIXTURE"] else {
            throw XCTSkip("Supply the retained compact journey original to opt in.")
        }
        try exercise(path: path, name: "compact-journey",
                     knownCat: CGRect(x: 0.145, y: 0.51, width: 0.34, height: 0.43),
                     location: Location(country: "中国", city: "杭州", place: "曲院风荷"),
                     quote: "今天适合慢一点。", moodLevel: 0, moodLabel: "平静")
    }

    @MainActor
    func testRetainedJourneyKeepsKnownCatVisibleAtActualWindowSizes() throws {
        guard let path = ProcessInfo.processInfo.environment["TRAVEL_CAT_CROP_FIXTURE"] else {
            throw XCTSkip("Supply the retained journey original to opt in to image acceptance.")
        }
        try exercise(path: path, name: "journey", knownCat: CGRect(x: 0.615, y: 0.715, width: 0.14, height: 0.22),
                     location: Location(country: "中国", city: "杭州", place: "河坊街"), quote: "今天适合慢一点。",
                     moodLevel: 0, moodLabel: "平静")
    }

    @MainActor
    func testOriginalGardenKeepsCatAndIntegratedQuoteAtActualWindowSizes() throws {
        guard let path = ProcessInfo.processInfo.environment["TRAVEL_CAT_CAPTION_FIXTURE"] else {
            throw XCTSkip("Supply the original garden postcard to opt in to image acceptance.")
        }
        try exercise(path: path, name: "garden", knownCat: CGRect(x: 0.465, y: 0.43, width: 0.51, height: 0.515),
                     location: Location(country: "China", city: "Suzhou", place: "Master of the Nets Garden"),
                     quote: "一盏灯，一杯茶，刚好安放夜色。")
    }

    @MainActor
    private func exercise(path: String, name: String, knownCat: CGRect, location: Location, quote: String,
                          moodLevel: Int = 1, moodLabel: String = "惬意") throws {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let analysis = try PostcardVisualAnalyzer.analyze(image)
        print("crop-acceptance: foreground=\(analysis.foregroundRegions) salient=\(analysis.salientRegions)")
        let event = TripEvent(id: UUID(), tripID: UUID(), previousEventID: nil,
                             occurredAt: Date(timeIntervalSince1970: 1_700_000_000), phase: .postcardReady,
                             location: location, transport: nil, summary: "明信片显示验收",
                             mood: Mood(level: moodLevel, label: moodLabel, quote: quote), continuityReferences: [],
                             openHook: nil, consumedItemID: nil, postcardStatus: .ready,
                             postcardRelativePath: "postcards/fixture.png")
        var sizes: [(PostcardOverlayProfile, CGSize)] = [(.detail, CGSize(width: 696, height: 230)),
            (.detail, CGSize(width: 900, height: 450)), (.compact, CGSize(width: 320, height: 180))]
        if name == "sudi" { sizes.append((.compact, CGSize(width: 320, height: 120))) }
        for (profile, size) in sizes {
            let transform = PostcardImageGeometry(
                imageSize: CGSize(width: image.width, height: image.height), containerSize: size, analysis: analysis)
            let displayed = transform.displayRect(forImageNormalized: knownCat)
            let retained = transform.imageRect(forDisplayNormalized: displayed)
            XCTAssertEqual(retained.minX, knownCat.minX, accuracy: 0.001)
            XCTAssertEqual(retained.minY, knownCat.minY, accuracy: 0.001)
            XCTAssertEqual(retained.width, knownCat.width, accuracy: 0.001)
            XCTAssertEqual(retained.height, knownCat.height, accuracy: 0.001,
                           "The complete independently observed cat must survive cropping at \(size)")
            let canvas = transform.visibleCanvas
            let layout = PostcardArtworkLayoutResolver.resolve(metadata: .init(event: event),
                analysis: transform.displayAnalysis(analysis), profile: profile, containerSize: canvas.size)
            print("crop-layout: name=\(name) size=\(size) canvas=\(canvas) reason=\(String(describing: layout.fallbackReason))")
            XCTAssertEqual(layout.messagePlacement, .onImage,
                           "These originals have sufficient clear image space for their complete short quotes at \(size)")
            if layout.messagePlacement == .onImage {
                let message = layout.messageFrame(profile: profile, containerSize: canvas.size)
                let catFrame = CGRect(x: displayed.minX * canvas.width, y: displayed.minY * canvas.height,
                                      width: displayed.width * canvas.width, height: displayed.height * canvas.height)
                XCTAssertFalse(message.intersects(catFrame), "Caption must avoid independently marked cat")
                XCTAssertTrue(CGRect(origin: .zero, size: canvas.size).contains(message))
                if layout.showsLocationLabel {
                    XCTAssertFalse(layout.locationSafetyRect.intersects(displayed))
                }
                let textLayout = layout.messageTextLayout(message: quote, profile: profile, containerSize: canvas.size)
                XCTAssertTrue(textLayout.fits, "Complete quote must fit without truncation")
                XCTAssertEqual(textLayout.lines.map(\.text).joined(), quote)
                if name == "journey" || profile == .detail {
                    XCTAssertNotEqual(layout.pawSignature.placement.mode, .omitted,
                                      "These fixtures have safe room for a visible paw signature")
                }
                try PostcardPawRasterAssertions.assertClearance(message: quote, layout: layout,
                    profile: profile, canvasSize: canvas.size, minimumGap: profile == .detail ? 4 : 2)
            }
            let rendered = ImageRenderer(content: PostcardArtworkFrame(height: size.height, profile: profile,
                caption: layout.messagePlacement == .belowImage ? quote : nil) {
                ZStack(alignment: .topLeading) {
                    Color.blue.opacity(0.12)
                    PostcardRenderedImage(image: image, geometry: transform)
                    if layout.messagePlacement == .onImage {
                        PostcardArtworkView(event: event, rootURL: nil, height: size.height, profile: profile)
                            .overlay(metadata: .init(event: event), layout: layout, containerSize: canvas.size)
                            .offset(x: canvas.minX, y: canvas.minY)
                    }
                }.frame(width: size.width, height: size.height).clipped()
            }.frame(width: size.width).background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, .dark))
            let raster = try XCTUnwrap(rendered.cgImage)
            XCTAssertEqual(raster.width, Int(size.width))
            if let directory = ProcessInfo.processInfo.environment["TRAVEL_CAT_CROP_RENDER_DIR"] {
                let bytes = try XCTUnwrap(NSBitmapImageRep(cgImage: raster).representation(using: .png, properties: [:]))
                let output = URL(fileURLWithPath: directory)
                    .appendingPathComponent("\(name)-\(Int(size.width))x\(Int(size.height)).png")
                try bytes.write(to: output, options: .atomic)
                print("crop-acceptance: render=\(output.path) mode=\(transform.contentMode) placement=\(layout.messagePlacement)")
            }
        }
    }
}
