import AppKit
import ImageIO
import SwiftUI
import XCTest
import TravelCore
@testable import TravelUI

@MainActor
final class PostcardCanvasRegressionTests: XCTestCase {
    func testSquareArtworkDoesNotPaintWideSideGutters() throws {
        let view = PostcardArtworkFrame(height: 230, profile: .detail, caption: nil,
            imageSize: CGSize(width: 1024, height: 1024)) { Color.red }
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: 456, height: nil)
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(image.width, 230)
        XCTAssertEqual(image.height, 230)
    }

    func testNarrowProposalShrinksBothDimensionsWithoutStretching() throws {
        let view = PostcardArtworkFrame(height: 230, profile: .detail, caption: nil,
            imageSize: CGSize(width: 1600, height: 800)) { Color.red }
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: 200, height: nil)
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(image.width, 200)
        XCTAssertEqual(image.height, 100)
    }

    func testShortWideStripAboveCatKeepsMessageOnImage() {
        let analysis = PostcardVisualAnalysis(salientRegions: [],
            samples: .uniform(luminance: 0.6, red: 0.6, green: 0.6, blue: 0.6),
            foregroundRegions: [CGRect(x: 0, y: 0.29, width: 1, height: 0.71)])
        let layout = PostcardArtworkLayoutResolver.resolve(metadata: .init(event: event),
            analysis: analysis, profile: .detail, containerSize: CGSize(width: 230, height: 230))
        XCTAssertEqual(layout.messagePlacement, .onImage)
        XCTAssertLessThan(layout.messageFrame(profile: .detail,
            containerSize: CGSize(width: 230, height: 230)).maxY, 0.29 * 230)
    }

    func testProvidedSquarePostcardKeepsMessageOnImage() throws {
        let event = self.event
        guard let path = ProcessInfo.processInfo.environment["TRAVEL_CAT_CANVAS_FIXTURE"] else {
            throw XCTSkip("Optional user-owned reference; never copied into source")
        }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let analysis = try PostcardVisualAnalyzer.analyze(image)
        let layout = PostcardArtworkLayoutResolver.resolve(metadata: .init(event: event),
            analysis: analysis, profile: .detail, containerSize: CGSize(width: 230, height: 230))
        XCTAssertEqual(layout.messagePlacement, .onImage)
        let size = CGSize(width: 230, height: 230)
        let message = layout.messageTextLayout(message: event.mood.quote, profile: .detail, containerSize: size)
        XCTAssertTrue(message.fits)
        XCTAssertEqual(message.lines.map(\.text).joined(), event.mood.quote)
        let normalized = layout.resolvedNormalizedMessageRect(profile: .detail)
        XCTAssertFalse(analysis.foregroundRegions.contains(where: normalized.intersects))
        if let output = ProcessInfo.processInfo.environment["TRAVEL_CAT_CANVAS_RENDER"] {
            let geometry = PostcardImageGeometry(imageSize: CGSize(width: image.width, height: image.height),
                containerSize: size, analysis: analysis)
            let renderer = ImageRenderer(content:
                PostcardArtworkFrame(height: 230, profile: .detail, caption: nil,
                    imageSize: CGSize(width: image.width, height: image.height)) {
                    ZStack(alignment: .topLeading) {
                        PostcardRenderedImage(image: image, geometry: geometry)
                        PostcardArtworkView(event: event, rootURL: nil, height: 230, profile: .detail)
                            .overlay(metadata: .init(event: event), layout: layout, containerSize: size)
                    }
                }
                .frame(width: 456, alignment: .center)
                .padding(12)
                .background(Color(nsColor: .textBackgroundColor))
                .environment(\.colorScheme, .dark))
            renderer.scale = 2
            let raster = try XCTUnwrap(renderer.cgImage)
            let bytes = try XCTUnwrap(NSBitmapImageRep(cgImage: raster).representation(using: .png, properties: [:]))
            try bytes.write(to: URL(fileURLWithPath: output))
        }
    }

    private var event: TripEvent {
        TripEvent(id: UUID(), tripID: UUID(), previousEventID: nil,
            occurredAt: Date(timeIntervalSince1970: 0), phase: .postcardReady,
            location: Location(country: "示例国家", city: "示例城市", place: "河边栈桥"),
            transport: nil, summary: "测试明信片", mood: Mood(level: 1, label: "兴奋",
                quote: ProcessInfo.processInfo.environment["TRAVEL_CAT_CANVAS_MESSAGE"] ?? "晚风把远方的风景送到窗前。"),
            continuityReferences: [], openHook: nil, consumedItemID: nil,
            postcardStatus: .ready, postcardRelativePath: "postcards/fixture.png")
    }
}
