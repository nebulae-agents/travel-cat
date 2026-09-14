import AppKit
import CoreGraphics
import SwiftUI
import XCTest
import TravelCore
@testable import TravelUI

@MainActor
final class PostcardPawTextClearanceTests: XCTestCase {
    private let typography = PostcardMoodTypographyResolver().resolve(
        mood: Mood(level: 0, label: "平静", quote: "今天适合慢一点。")
    )

    func testSharedLayoutPreservesCharactersExplicitBreaksAndRenderedInkClearance() throws {
        let frame = CGRect(x: 10, y: 10, width: 96, height: 70)
        let layout = PostcardMessageLineLayout.resolve(
            message: "今天适合慢一点。",
            frame: frame,
            fontSize: 18,
            typography: typography,
            lineLimit: 3
        )
        let placement = PostcardPawLayout.resolve(
            textLayout: layout,
            signatureBounds: frame,
            profile: .detail
        )

        XCTAssertEqual(layout.lines.map(\.text).joined(), "今天适合慢一点。")
        XCTAssertEqual(layout.lines.count, 2)
        XCTAssertTrue(layout.fits)
        XCTAssertNotEqual(placement.mode, .omitted)

        let textMask = try mask(
            PostcardMessageTextView(layout: layout, color: .black),
            size: CGSize(width: 130, height: 100)
        )
        let pawMask = try mask(
            PostcardPawSignatureView(signature: PostcardPawSignature(
                placement: placement,
                style: PostcardPawSignatureStyle(
                    handwriting: typography,
                    ink: PostcardInkResolver.unknownStyle
                )
            )),
            size: CGSize(width: 130, height: 100)
        )
        let textPixels = try inkPixels(textMask)
        let pawPixels = try inkPixels(pawMask)
        XCTAssertFalse(textPixels.isEmpty)
        XCTAssertFalse(pawPixels.isEmpty)
        XCTAssertTrue(textPixels.isDisjoint(with: pawPixels), "actual text and paw ink must not collide")
        XCTAssertGreaterThanOrEqual(pixelDistance(textPixels, pawPixels, width: textMask.width), 4)
    }

    func testSharedLayoutCoversHandwritingFamiliesAndPlacementModes() throws {
        let cases: [(Mood, PostcardOverlayProfile)] = [
            (Mood(level: -2, label: "想家", quote: "风，慢慢吹。"), .detail),
            (Mood(level: 1, label: "好奇", quote: "看看风景。"), .compact),
            (Mood(level: 4, label: "坚定", quote: "继续往前走！"), .detail),
        ]
        for (mood, profile) in cases {
            let style = PostcardMoodTypographyResolver().resolve(mood: mood)
            let layout = PostcardMessageLineLayout.resolve(
                message: mood.quote,
                frame: CGRect(x: 0, y: 0, width: 180, height: 80),
                fontSize: profile == .detail ? 18 : 12,
                typography: style,
                lineLimit: 3
            )
            XCTAssertEqual(layout.lines.map(\.text).joined(), mood.quote)
            XCTAssertEqual(layout.font.fontName, style.fontPostScriptName)
            try PostcardPawRasterAssertions.assertLinesUnclipped(
                textLayout: layout,
                shadowOpacity: PostcardInkResolver.unknownStyle.shadowOpacity,
                shadowRadius: PostcardInkResolver.unknownStyle.shadowRadius
            )
        }

        let inline = placement(message: "看海。", width: 220, height: 80)
        let signature = placement(message: "WWWWWWWWWWW", width: 175, height: 104)
        let omitted = placement(message: "看海。", width: 80, height: 24, protected: [CGRect(x: 0, y: 0, width: 80, height: 24)])
        XCTAssertEqual(inline.mode, .inline)
        XCTAssertEqual(signature.mode, .signatureLine)
        XCTAssertEqual(omitted.mode, .omitted)
    }

    func testTooNarrowFrameRetainsWholeMessageAndReportsOverflow() {
        let layout = PostcardMessageLineLayout.resolve(
            message: "旅",
            frame: CGRect(x: 0, y: 0, width: 1, height: 80),
            fontSize: 18,
            typography: typography,
            lineLimit: 3
        )

        XCTAssertEqual(layout.lines.map(\.text).joined(), "旅")
        XCTAssertGreaterThan(layout.lines[0].width, layout.frame.width)
        XCTAssertFalse(layout.fits)
        XCTAssertEqual(PostcardPawLayout.resolve(textLayout: layout, profile: .detail).mode, .omitted)
    }

    func testExplicitNewlinesAndPunctuationArePreservedVerbatim() {
        let layout = PostcardMessageLineLayout.resolve(
            message: "第一行，\r\n第二行！",
            frame: CGRect(x: 0, y: 0, width: 180, height: 80),
            fontSize: 18,
            typography: typography,
            lineLimit: 3
        )
        XCTAssertEqual(layout.message, "第一行，\n第二行！")
        XCTAssertEqual(layout.lines.map(\.text), ["第一行，", "第二行！"])
    }

    func testBroadAttentionDoesNotHideRiverPawWhenExplicitCatAndLocationAreClear() {
        let canvas = CGSize(width: 345, height: 230)
        let cat = CGRect(x: 0.58, y: 0.36, width: 0.28, height: 0.62)
        let broadAttention = PostcardSalientRegion(
            rect: CGRect(x: 0.147, y: 0.229, width: 0.777, height: 0.700),
            weight: 0.584
        )
        let analysis = PostcardVisualAnalysis(
            salientRegions: [broadAttention],
            samples: .uniform(luminance: 0.5, red: 0.5, green: 0.5, blue: 0.5),
            protectedRegions: [cat],
            foregroundRegions: [cat]
        )
        let location = CGRect(x: 250, y: 204, width: 75, height: 20)
        let obstacles = PostcardOverlaySolver.pawProtectedFrames(
            locationRect: CGRect(x: location.minX / canvas.width, y: location.minY / canvas.height,
                                 width: location.width / canvas.width, height: location.height / canvas.height),
            analysis: analysis,
            containerSize: canvas
        )
        let frame = CGRect(x: 27.25, y: 161.8, width: 124.9, height: 46.7)
        let textLayout = PostcardMessageLineLayout.resolve(
            message: "今天适合慢一点。",
            frame: frame,
            fontSize: 18.5,
            typography: typography,
            lineLimit: 2
        )
        let placement = PostcardPawLayout.resolve(
            textLayout: textLayout,
            signatureBounds: frame,
            profile: .detail,
            protectedFrames: obstacles
        )

        XCTAssertEqual(placement.mode, .inline)
        XCTAssertTrue(obstacles.contains { abs($0.minX - location.minX) < 0.001
            && abs($0.minY - location.minY) < 0.001 })
        XCTAssertFalse(obstacles.contains { $0.intersects(placement.pawFrame) })
        XCTAssertFalse(placement.pawFrame.intersects(location))
    }

    /// Negative control for the reported defect: the former independent
    /// semibold SwiftUI wrapping collides with a paw placed from regular CT widths.
    func testLegacyIndependentRendererReproducesActualQuoteCollision() throws {
        let quote = "今天适合慢一点。"
        var reproducedAtWidth: CGFloat?
        for width in stride(from: CGFloat(58), through: 150, by: 0.5) {
            let frame = CGRect(x: 10, y: 10, width: width, height: 70)
            let placement = PostcardPawLayout.resolve(
                message: quote, messageFrame: frame, fontSize: 18,
                typography: typography, profile: .detail, lineLimit: 3
            )
            guard placement.mode != .omitted else { continue }
            let legacy = Text(quote).font(Font(typographyFont(size: 18))).fontWeight(.semibold)
                .lineSpacing(PostcardOverlayTypography.renderedLineHeight(fontSize: 18, handwriting: typography)
                    - typographyFont(size: 18).ascender + typographyFont(size: 18).descender
                    - typographyFont(size: 18).leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: frame.width, height: frame.height, alignment: .topLeading)
                .position(x: frame.midX, y: frame.midY)
            let textPixels = try inkPixels(try mask(legacy, size: CGSize(width: 180, height: 100)))
            let pawPixels = try inkPixels(try pawMask(placement, size: CGSize(width: 180, height: 100)))
            if !textPixels.isDisjoint(with: pawPixels) { reproducedAtWidth = width; break }
        }
        print("paw-legacy-negative-control: collisionWidth=\(String(describing: reproducedAtWidth)) canvas=180x100 quote=\(quote)")
        XCTAssertNotNil(reproducedAtWidth)
    }

    private func placement(
        message: String,
        width: CGFloat,
        height: CGFloat,
        protected: [CGRect] = []
    ) -> PostcardPawPlacement {
        let frame = CGRect(x: 0, y: 0, width: width, height: height)
        let layout = PostcardMessageLineLayout.resolve(
            message: message,
            frame: frame,
            fontSize: 18,
            typography: typography,
            lineLimit: 3
        )
        return PostcardPawLayout.resolve(
            textLayout: layout,
            signatureBounds: frame,
            profile: .detail,
            protectedFrames: protected
        )
    }

    private func mask<V: View>(_ view: V, size: CGSize) throws -> CGImage {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height, alignment: .topLeading))
        renderer.scale = 1
        return try XCTUnwrap(renderer.cgImage)
    }

    private func pawMask(_ placement: PostcardPawPlacement, size: CGSize) throws -> CGImage {
        try mask(PostcardPawSignatureView(signature: PostcardPawSignature(
            placement: placement,
            style: PostcardPawSignatureStyle(handwriting: typography, ink: PostcardInkResolver.unknownStyle)
        )), size: size)
    }

    private func typographyFont(size: CGFloat) -> NSFont {
        PostcardOverlayTypography.measurementFont(fontSize: size, handwriting: typography)!
    }

    private func inkPixels(_ image: CGImage) throws -> Set<Int> {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(
                data: storage.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        var result = Set<Int>()
        for y in 0..<image.height {
            for x in 0..<image.width {
                let alpha = bytes[(y * image.width + x) * 4 + 3]
                if alpha > 24 { result.insert(y * image.width + x) }
            }
        }
        return result
    }

    private func pixelDistance(_ lhs: Set<Int>, _ rhs: Set<Int>, width: Int) -> CGFloat {
        guard !lhs.isEmpty, !rhs.isEmpty else { return .greatestFiniteMagnitude }
        var best = CGFloat.greatestFiniteMagnitude
        for a in lhs {
            let ax = a % width, ay = a / width
            for b in rhs {
                let dx = CGFloat(ax - b % width), dy = CGFloat(ay - b / width)
                best = min(best, hypot(dx, dy))
            }
        }
        return best
    }
}
