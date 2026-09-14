import AppKit
import ImageIO
import SwiftUI
import XCTest
import TravelCore
@testable import TravelUI

@MainActor
final class PostcardPreviewMessageAcceptanceTests: XCTestCase {
    func testAllSixPreviewMessagesStayOnImageAtAlbumAndDetailSizes() throws {
        let sizes: [(PostcardOverlayProfile, CGSize)] = [
            (.compact, CGSize(width: 320, height: 120)),
            (.compact, CGSize(width: 320, height: 180)),
            (.detail, CGSize(width: 696, height: 230)),
            (.detail, CGSize(width: 900, height: 450))
        ]
        for definition in TravelAlbumPreviewCatalog.definitions {
            let url = try XCTUnwrap(TravelAlbumPreviewCatalog.resourceURL(for: definition, in: TravelUIResources.bundle))
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let analysis = try PostcardVisualAnalyzer.analyze(image)
            let catURL = try XCTUnwrap(TravelAlbumPreviewCatalog.catResourceURL(for: definition.catPlacement.pose, in: TravelUIResources.bundle))
            let descriptor = PreviewBlackCatOverlayDescriptor(assetURL: catURL, placement: definition.catPlacement)
            let event = TripEvent(id: UUID(), tripID: UUID(), previousEventID: nil,
                occurredAt: Date(timeIntervalSince1970: 1_700_000_000), phase: .postcardReady,
                location: definition.location, transport: nil, summary: definition.summary,
                mood: definition.mood, continuityReferences: [], openHook: nil, consumedItemID: nil,
                postcardStatus: .ready, postcardRelativePath: "postcards/fixture.png")
            for (profile, size) in sizes {
                let geometry = PostcardImageGeometry(imageSize: CGSize(width: image.width, height: image.height),
                    containerSize: size, analysis: analysis)
                let canvas = geometry.visibleCanvas
                let catFrame = definition.catPlacement.frame(in: size,
                    sourceAspectRatio: PreviewBlackCatPlacement.authorizedSourceAspectRatio)
                let cat = PostcardArtworkView.normalizedPreviewProtection(catFrame, visibleCanvas: canvas)
                let displayed = geometry.displayAnalysis(analysis).protecting(cat)
                let layoutStarted = ProcessInfo.processInfo.systemUptime
                let layout = PostcardArtworkLayoutResolver.resolve(metadata: .init(event: event),
                    analysis: displayed, profile: profile, containerSize: canvas.size)
                let layoutMilliseconds = (ProcessInfo.processInfo.systemUptime - layoutStarted) * 1_000
                print("preview-message-timing: \(definition.filename) size=\(size) milliseconds=\(layoutMilliseconds)")
                print("preview-message: \(definition.filename) size=\(size) canvas=\(canvas) placement=\(layout.messagePlacement) region=\(layout.messageRegion) cat=\(cat) foreground=\(displayed.foregroundRegions)")
                XCTAssertEqual(layout.messagePlacement, .onImage,
                    "\(definition.filename) at \(size) should keep its complete short quote in clear image space")
                if layout.messagePlacement == .onImage {
                    let text = layout.messageTextLayout(message: event.mood.quote, profile: profile, containerSize: canvas.size)
                    XCTAssertTrue(text.fits, "\(definition.filename): complete quote must fit")
                    XCTAssertEqual(text.lines.map(\.text).joined(), event.mood.quote)
                    let protectedCat = CGRect(x: cat.minX * canvas.width, y: cat.minY * canvas.height,
                        width: cat.width * canvas.width, height: cat.height * canvas.height)
                    let messageFrame = layout.messageFrame(profile: profile, containerSize: canvas.size)
                    XCTAssertTrue(CGRect(origin: .zero, size: canvas.size).contains(messageFrame),
                        "\(definition.filename): outer text and wash frame must stay inside actual image")
                    XCTAssertFalse(messageFrame.intersects(protectedCat),
                        "\(definition.filename): entire text and wash frame must avoid known cat")
                    XCTAssertFalse(text.frame.intersects(protectedCat), "\(definition.filename): text must avoid known cat")
                    try PostcardPawRasterAssertions.assertClearance(message: event.mood.quote, layout: layout,
                        profile: profile, canvasSize: canvas.size, minimumGap: profile == .detail ? 4 : 2)
                }
                if let directory = ProcessInfo.processInfo.environment["TRAVEL_CAT_MESSAGE_RENDER_DIR"] {
                    let renderer = ImageRenderer(content: PostcardArtworkFrame(height: size.height, profile: profile,
                        caption: layout.messagePlacement == .belowImage ? event.mood.quote : nil) {
                        ZStack(alignment: .topLeading) {
                            Color.blue.opacity(0.12)
                            PostcardRenderedImage(image: image, geometry: geometry)
                            PreviewBlackCatOverlay(descriptor: descriptor, containerSize: size, profile: profile)
                            if layout.messagePlacement == .onImage {
                                PostcardArtworkView(event: event, rootURL: nil, height: size.height, profile: profile)
                                    .overlay(metadata: .init(event: event), layout: layout, containerSize: canvas.size)
                                    .offset(x: canvas.minX, y: canvas.minY)
                            }
                        }.frame(width: size.width, height: size.height).clipped()
                    }.frame(width: size.width).background(Color(nsColor: .windowBackgroundColor))
                        .environment(\.colorScheme, .dark))
                    let raster = try XCTUnwrap(renderer.cgImage)
                    let bytes = try XCTUnwrap(NSBitmapImageRep(cgImage: raster).representation(using: .png, properties: [:]))
                    let filename = "\(url.deletingPathExtension().lastPathComponent)-\(Int(size.width))x\(Int(size.height)).png"
                    try bytes.write(to: URL(fileURLWithPath: directory).appendingPathComponent(filename), options: .atomic)
                }
            }
        }
    }
}
