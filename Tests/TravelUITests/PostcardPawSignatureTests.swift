import CoreGraphics
import XCTest
import TravelCore
@testable import TravelUI

final class PostcardPawSignatureTests: XCTestCase {
    private let serene = PostcardMoodTypographyResolver().resolve(
        mood: Mood(level: 0, label: "平静", quote: "慢一点。")
    )

    func testMessageAndPawSourceAndDesignUseOneLeadingGeometryContract() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/TravelUI/PostcardPawSignature.swift"))
        let design = try String(contentsOf: root.appendingPathComponent(
            "docs/postcard-layout.md"
        ))

        XCTAssertFalse(source.contains("PostcardPawTextAlignment"))
        XCTAssertFalse(source.contains("alignment == .leading"))
        XCTAssertFalse(source.contains("alignment == .trailing"))
        XCTAssertTrue(design.contains("Every message block is leading-aligned regardless of region"))
        XCTAssertFalse(design.contains("A trailing message uses"))
    }

    func testPawGeometryUsesOnePadFourToesAndDeterministicVectorTexture() {
        XCTAssertEqual(PostcardPawGeometry.pad.count, 1)
        XCTAssertEqual(PostcardPawGeometry.toes.count, 4)
        XCTAssertGreaterThanOrEqual(PostcardPawGeometry.textureSpots.count, 4)

        let first = PostcardPawGeometry.path(in: CGRect(x: 0, y: 0, width: 40, height: 40))
        let second = PostcardPawGeometry.path(in: CGRect(x: 0, y: 0, width: 40, height: 40))

        XCTAssertEqual(first, second)
        XCTAssertFalse(first.isEmpty)
        XCTAssertTrue(CGRect(x: 0, y: 0, width: 40, height: 40).contains(first.boundingBoxOfPath))
    }

    func testShortMessagePlacesPawInlineAfterMeasuredText() {
        let placement = PostcardPawLayout.resolve(
            message: "风很轻。",
            messageFrame: CGRect(x: 10, y: 10, width: 300, height: 90),
            fontSize: 22,
            typography: serene,
            profile: .detail
        )

        XCTAssertEqual(placement.mode, .inline)
        XCTAssertTrue(placement.messageFits)
        XCTAssertFalse(placement.pawFrame.intersects(placement.textFrame))
        XCTAssertGreaterThan(placement.pawFrame.minX, placement.textFrame.maxX)
    }

    func testMessageWithoutTrailingRoomMovesPawToSignatureLine() {
        let placement = PostcardPawLayout.resolve(
            message: "WWWWWWWWWWW",
            messageFrame: CGRect(x: 4, y: 4, width: 175, height: 104),
            fontSize: 18,
            typography: serene,
            profile: .detail
        )

        XCTAssertEqual(placement.mode, .signatureLine)
        XCTAssertTrue(placement.messageFits)
        XCTAssertEqual(placement.pawFrame.width, 18 * 0.78 * 1.20, accuracy: 0.000_001)
        XCTAssertFalse(placement.pawFrame.intersects(placement.textFrame))
        XCTAssertGreaterThanOrEqual(placement.pawFrame.minY, placement.textFrame.maxY)
    }

    func testLegalCompactMessageIsNeverTruncatedForPaw() {
        let placement = PostcardPawLayout.resolve(
            message: String(repeating: "旅", count: 80),
            messageFrame: CGRect(x: 4, y: 4, width: 506, height: 36),
            fontSize: 12,
            typography: serene,
            profile: .compact
        )

        XCTAssertTrue(placement.messageFits)
        XCTAssertNotEqual(placement.mode, .signatureLine)
        if placement.mode == .inline {
            XCTAssertFalse(placement.pawFrame.intersects(placement.textFrame))
        } else {
            XCTAssertEqual(placement.mode, .omitted)
            XCTAssertEqual(placement.pawFrame, .zero)
        }
    }

    func testExplicitLineBreaksKeepEveryMessageLineWhenPawCannotAddALine() {
        let placement = PostcardPawLayout.resolve(
            message: "第一行写满风景\n第二行写满心情",
            messageFrame: CGRect(x: 4, y: 4, width: 180, height: 36),
            fontSize: 12,
            typography: serene,
            profile: .compact
        )

        XCTAssertTrue(placement.messageFits)
        XCTAssertEqual(placement.measuredLineCount, 2)
        XCTAssertNotEqual(placement.mode, .signatureLine)
    }

    func testInlineDecisionUsesActualLastLineInsteadOfWidestPriorLine() {
        let placement = PostcardPawLayout.resolve(
            message: "这一行写得很长很长很长很长\n短句。",
            messageFrame: CGRect(x: 0, y: 0, width: 260, height: 80),
            fontSize: 16,
            typography: serene,
            profile: .detail
        )

        XCTAssertEqual(placement.measuredLineCount, 2)
        XCTAssertEqual(placement.mode, .inline)
        XCTAssertGreaterThan(placement.pawFrame.minY, placement.textFrame.minY)
    }

    func testPawSizesStayWithinCompactAndDetailBounds() {
        let compact = PostcardPawLayout.resolve(
            message: "看海。",
            messageFrame: CGRect(x: 0, y: 0, width: 200, height: 60),
            fontSize: 12,
            typography: serene,
            profile: .compact
        )
        let detail = PostcardPawLayout.resolve(
            message: "看海。",
            messageFrame: CGRect(x: 0, y: 0, width: 300, height: 100),
            fontSize: 30,
            typography: serene,
            profile: .detail
        )

        XCTAssertTrue((7...14.4).contains(compact.pawFrame.width))
        XCTAssertTrue((10...24).contains(detail.pawFrame.width))
    }

    func testRoomyPawUsesExactlyOnePointTwoTimesThePreviousNominalSize() {
        let compact = PostcardPawLayout.resolve(
            message: "看海。",
            messageFrame: CGRect(x: 0, y: 0, width: 300, height: 60),
            fontSize: 12,
            typography: serene,
            profile: .compact
        )
        let detail = PostcardPawLayout.resolve(
            message: "看海。",
            messageFrame: CGRect(x: 0, y: 0, width: 500, height: 100),
            fontSize: 30,
            typography: serene,
            profile: .detail
        )

        XCTAssertEqual(compact.mode, .inline)
        XCTAssertEqual(compact.pawFrame.width, 12 * 0.78 * 1.20, accuracy: 0.000_001)
        XCTAssertEqual(detail.mode, .inline)
        XCTAssertEqual(detail.pawFrame.width, 20 * 1.20, accuracy: 0.000_001)
    }

    func testPawImpressionFollowsMoodWhileOpacityComesFromSemanticInk() {
        let reflective = PostcardMoodTypographyResolver().resolve(
            mood: Mood(level: -2, label: "想家", quote: "有点想念。")
        )
        let bold = PostcardMoodTypographyResolver().resolve(
            mood: Mood(level: 5, label: "惊喜", quote: "看这里！")
        )
        let ink = PostcardInkResolver.unknownStyle

        XCTAssertEqual(PostcardPawSignatureStyle(handwriting: reflective, ink: ink).impression, .light)
        XCTAssertEqual(PostcardPawSignatureStyle(handwriting: bold, ink: ink).impression, .firm)
        XCTAssertEqual(PostcardPawSignatureStyle(handwriting: reflective, ink: ink).opacity, ink.pawOpacity)
        XCTAssertTrue((0.68...0.82).contains(PostcardPawSignatureStyle(handwriting: bold, ink: ink).opacity))
        XCTAssertTrue(PostcardPawSignatureStyle.isAccessibilityHidden)
        XCTAssertNotEqual(
            PostcardPawGeometry.components(for: .light),
            PostcardPawGeometry.components(for: .firm)
        )
        XCTAssertNotEqual(
            PostcardPawGeometry.path(in: CGRect(x: 0, y: 0, width: 40, height: 40), impression: .lively),
            PostcardPawGeometry.path(in: CGRect(x: 0, y: 0, width: 40, height: 40), impression: .balanced)
        )
        XCTAssertGreaterThan(
            PostcardPawSignatureStyle(handwriting: reflective, ink: ink).textureStrength,
            PostcardPawSignatureStyle(handwriting: bold, ink: ink).textureStrength
        )
    }

    func testInlineShrinksPawBeforeUsingSignatureLine() {
        let placement = PostcardPawLayout.resolve(
            message: "WWWWWWWW",
            messageFrame: CGRect(x: 0, y: 0, width: 124, height: 60),
            fontSize: 16,
            typography: serene,
            profile: .compact
        )

        XCTAssertEqual(placement.mode, .inline)
        XCTAssertGreaterThanOrEqual(placement.pawFrame.width, 7)
        XCTAssertLessThan(placement.pawFrame.width, 12)
    }

    func testEnlargedInlineTierFallsBackToCompletePreviousSafeTierAroundProtectedContent() {
        let frame = CGRect(x: 0, y: 0, width: 300, height: 60)
        let enlarged = PostcardPawLayout.resolve(
            message: "看海。",
            messageFrame: frame,
            fontSize: 16,
            typography: serene,
            profile: .compact
        )
        let enlargedOnlyFringe = CGRect(
            x: enlarged.pawFrame.minX + 12.000_1,
            y: frame.minY,
            width: enlarged.pawFrame.width - 12,
            height: frame.height
        )
        let fallback = PostcardPawLayout.resolve(
            message: "看海。",
            messageFrame: frame,
            fontSize: 16,
            typography: serene,
            profile: .compact,
            protectedFrames: [enlargedOnlyFringe]
        )

        XCTAssertEqual(enlarged.pawFrame.width, 14.4, accuracy: 0.000_001)
        XCTAssertEqual(fallback.mode, .inline)
        XCTAssertEqual(fallback.pawFrame.width, 12, accuracy: 0.000_001)
        XCTAssertFalse(fallback.pawFrame.intersects(enlargedOnlyFringe))
        XCTAssertTrue(frame.contains(fallback.pawFrame))
        XCTAssertTrue(fallback.messageFits)
    }

    func testProtectedContentCanForceSignatureFallbackThenSafeOmission() {
        let frame = CGRect(x: 0, y: 0, width: 300, height: 80)
        let placement = PostcardPawLayout.resolve(
            message: "看海。",
            messageFrame: frame,
            fontSize: 16,
            typography: serene,
            profile: .compact,
            protectedFrames: [frame]
        )

        XCTAssertEqual(placement.mode, .omitted)
        XCTAssertEqual(placement.pawFrame, .zero)
        XCTAssertTrue(placement.messageFits)
    }

    func testLakeCompactInlineScansPastCatIntoTheSafeGapAfterText() {
        let messageFrame = CGRect(x: 158.56, y: 52, width: 146.56, height: 30.4)
        let cat = CGRect(x: 0, y: 6.33, width: 214.67, height: 113.67)
        let pier = CGRect(x: 187.83, y: 86.83, width: 134.17, height: 33.17)
        let placement = PostcardPawLayout.resolve(
            message: "湖光和晨风一起把旧码头点亮了。",
            messageFrame: messageFrame,
            fontSize: 12.48,
            typography: PostcardMoodTypographyResolver().resolve(
                mood: Mood(level: 2, label: "欣喜", quote: "湖光和晨风一起把旧码头点亮了。")
            ),
            profile: .compact,
            protectedFrames: [cat, pier]
        )

        XCTAssertEqual(placement.mode, .inline)
        XCTAssertGreaterThan(placement.pawFrame.minX, cat.maxX)
        XCTAssertTrue(messageFrame.contains(placement.pawFrame))
        XCTAssertFalse(placement.pawFrame.intersects(cat))
        XCTAssertFalse(placement.pawFrame.intersects(pier))
    }

    func testMiyajimaDetailSignatureScansTheSafeCorridorBelowText() {
        let messageFrame = CGRect(x: 285.6, y: 102, width: 198.4, height: 46.7)
        let signatureBounds = CGRect(x: 275.6, y: 102, width: 218.4, height: 94.5)
        let cat = CGRect(x: 0, y: 0, width: 303.34, height: 230)
        let torii = CGRect(x: 346.66, y: 0, width: 130.01, height: 158.34)
        let location = CGRect(x: 416.2, y: 200.5, width: 84.99, height: 20)
        let placement = PostcardPawLayout.resolve(
            message: "我追上了潮汐写出的金色路线。",
            messageFrame: messageFrame,
            signatureBounds: signatureBounds,
            fontSize: 19.3,
            typography: PostcardMoodTypographyResolver().resolve(
                mood: Mood(level: 2, label: "兴奋", quote: "我追上了潮汐写出的金色路线。")
            ),
            profile: .detail,
            protectedFrames: [cat, torii, location]
        )

        XCTAssertEqual(placement.mode, .signatureLine)
        XCTAssertGreaterThan(placement.pawFrame.minX, cat.maxX)
        XCTAssertLessThan(placement.pawFrame.maxX, torii.minX)
        XCTAssertGreaterThanOrEqual(placement.pawFrame.minY, placement.textBlockFrame.maxY)
        XCTAssertTrue(signatureBounds.contains(placement.pawFrame))
        XCTAssertFalse([cat, torii, location].contains { $0.intersects(placement.pawFrame) })
    }

    func testSingleAndDoubleLineTextBlocksUseTopOriginSharedWithPaw() {
        let frame = CGRect(x: 20, y: 30, width: 280, height: 100)
        let single = PostcardPawLayout.resolve(
            message: "一行。",
            messageFrame: frame,
            fontSize: 18,
            typography: serene,
            profile: .detail
        )
        let double = PostcardPawLayout.resolve(
            message: "第一行\n第二行",
            messageFrame: frame,
            fontSize: 18,
            typography: serene,
            profile: .detail
        )

        XCTAssertEqual(single.textFrame.minY, frame.minY, accuracy: 0.001)
        XCTAssertEqual(double.textBlockFrame.minY, frame.minY, accuracy: 0.001)
        XCTAssertEqual(
            double.textBlockFrame.height,
            2 * PostcardOverlayTypography.renderedLineHeight(fontSize: 18, handwriting: serene),
            accuracy: 0.001
        )
        XCTAssertGreaterThanOrEqual(single.pawFrame.minY, frame.minY)
        XCTAssertGreaterThanOrEqual(double.pawFrame.minY, frame.minY)
    }

    func testCompactThreeLineQuoteKeepsMessageFitAndPawOutOfProtectedSubject() {
        let protectedSubject = CGRect(x: 108, y: 42, width: 52, height: 28)
        let placement = PostcardPawLayout.resolve(
            message: "第一行写风景\n第二行写心情\n第三行落款",
            messageFrame: CGRect(x: 8, y: 8, width: 168, height: 70),
            fontSize: 14,
            typography: serene,
            profile: .compact,
            lineLimit: 3,
            protectedFrames: [protectedSubject]
        )

        XCTAssertTrue(placement.messageFits)
        XCTAssertNotEqual(placement.mode, .omitted)
        XCTAssertFalse(placement.pawFrame.intersects(protectedSubject))
    }

    func testSolverAcceptsHandwritingAndUsesItForImpression() {
        let bold = PostcardMoodTypographyResolver().resolve(
            mood: Mood(level: 4, label: "坚定", quote: "继续走。")
        )
        let layout = PostcardOverlaySolver.unknownFallback(
            message: "继续走。",
            profile: .detail,
            containerSize: CGSize(width: 520, height: 230),
            handwriting: bold
        )

        XCTAssertEqual(layout.pawSignature.style.impression, .firm)
    }
}
