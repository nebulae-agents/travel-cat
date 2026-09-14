import CoreGraphics
import XCTest
import TravelCore
@testable import TravelUI

final class PostcardMessagePlacementSearchTests: XCTestCase {
    private let compactCanvas = CGSize(width: 180, height: 120)

    func testSearchUsesFourLineHoleOutsidePresetHeights() {
        let message = "沿着长长的石板路慢慢走过安静屋檐也把今天的风景完整寄回家里。"
        let analysis = PostcardVisualAnalysis(
            salientRegions: [],
            samples: .uniform(luminance: 0.82, red: 0.82, green: 0.82, blue: 0.82),
            foregroundRegions: [
                CGRect(x: 0.64, y: 0, width: 0.36, height: 1),
                CGRect(x: 0, y: 0.66, width: 0.64, height: 0.34),
            ]
        )

        let layout = resolve(message: message, analysis: analysis)

        XCTAssertEqual(layout.messagePlacement, .onImage)
        XCTAssertNotNil(layout.normalizedMessageRect)
        XCTAssertEqual(layout.messageLineLimit, 4)
        XCTAssertGreaterThanOrEqual(layout.messageFontSize, 12)
        XCTAssertTrue(CGRect(origin: .zero, size: compactCanvas).contains(
            layout.messageFrame(profile: .compact, containerSize: compactCanvas)
        ))
        for subject in analysis.foregroundRegions {
            XCTAssertFalse(layout.resolvedNormalizedMessageRect(profile: .compact).intersects(subject))
        }
    }

    func testFullMessageLongerThanLegacySummaryLimitIsMeasuredAndRendered() {
        let message = "这是一封超过旧有三十二字符限制但必须一字不漏参与排版和绘制的完整旅行寄语。"
        let metadata = PostcardArtworkMetadata(event: event(message: message))
        let analysis = PostcardVisualAnalysis(
            salientRegions: [],
            samples: .uniform(luminance: 0.88, red: 0.88, green: 0.88, blue: 0.88),
            foregroundRegions: [CGRect(x: 0.72, y: 0.62, width: 0.26, height: 0.36)]
        )

        let layout = PostcardArtworkLayoutResolver.resolve(
            metadata: metadata,
            analysis: analysis,
            profile: .detail,
            containerSize: CGSize(width: 900, height: 450)
        )
        let textLayout = layout.messageTextLayout(
            message: metadata.visualMessage,
            profile: .detail,
            containerSize: CGSize(width: 900, height: 450)
        )

        XCTAssertEqual(metadata.visualMessage, message)
        XCTAssertEqual(textLayout.lines.map(\.text).joined(), message)
        XCTAssertTrue(textLayout.fits)
    }

    func testMessageWinsWhenLocationAndPawCompeteForOnlyClearSpace() {
        let message = "石板路绕过屋檐以后晚风正好把灯影和问候一起送回家。"
        let analysis = PostcardVisualAnalysis(
            salientRegions: [],
            samples: .uniform(luminance: 0.78, red: 0.78, green: 0.78, blue: 0.78),
            foregroundRegions: [
                CGRect(x: 0.65, y: 0, width: 0.35, height: 1),
                CGRect(x: 0, y: 0.66, width: 0.65, height: 0.34),
            ]
        )

        let layout = resolve(message: message, analysis: analysis)
        let messageRect = layout.resolvedNormalizedMessageRect(profile: .compact)

        XCTAssertEqual(layout.messagePlacement, .onImage)
        XCTAssertTrue(!layout.showsLocationLabel || !layout.locationSafetyRect.intersects(messageRect))
        XCTAssertTrue(
            layout.pawSignature.placement.mode == .omitted
                || layout.messageFrame(profile: .compact, containerSize: compactCanvas)
                    .contains(layout.pawSignature.placement.pawFrame)
        )
    }

    func testCompletelyOccupiedCanvasFallsBackWithSubjectConflictReason() {
        let analysis = PostcardVisualAnalysis(
            salientRegions: [],
            samples: .uniform(luminance: 0.5, red: 0.5, green: 0.5, blue: 0.5),
            foregroundRegions: [CGRect(x: 0, y: 0, width: 1, height: 1)]
        )

        let layout = resolve(message: "再小的角落也不能盖住猫。", analysis: analysis)

        XCTAssertEqual(layout.messagePlacement, .belowImage)
        XCTAssertEqual(layout.fallbackReason, .subjectConflict)
    }

    func testUnknownAnalysisFallsBackWithoutSearching() {
        let layout = resolve(message: "未知主体时保持保守。", analysis: nil)

        XCTAssertEqual(layout.messagePlacement, .belowImage)
        XCTAssertEqual(layout.fallbackReason, .unknownAnalysis)
        XCTAssertNil(layout.normalizedMessageRect)
    }

    func testFullCanvasCannotFitAnUnabridgedVeryLongMessage() {
        let analysis = PostcardVisualAnalysis(
            salientRegions: [],
            samples: .uniform(luminance: 0.7, red: 0.7, green: 0.7, blue: 0.7),
            foregroundRegions: [CGRect(x: 0.9, y: 0.9, width: 0.08, height: 0.08)]
        )
        let message = String(repeating: "完整寄语不能删减。", count: 30)

        let layout = resolve(message: message, analysis: analysis)

        XCTAssertEqual(layout.messagePlacement, .belowImage)
        XCTAssertEqual(layout.fallbackReason, .textDoesNotFit)
        XCTAssertEqual(PostcardArtworkMetadata(event: event(message: message)).visualMessage, message)
    }

    func testSearchIsDeterministicAndCandidateCountIsBounded() {
        let request = PostcardMessagePlacementSearch.Request(
            message: "有限搜索每次都应得到完全相同的结果。",
            analysis: PostcardVisualAnalysis(
                salientRegions: [],
                samples: .uniform(luminance: 0.7, red: 0.7, green: 0.7, blue: 0.7),
                protectedRegions: [CGRect(x: 0.7, y: 0.35, width: 0.3, height: 0.65)]
            ),
            profile: .compact,
            containerSize: compactCanvas,
            handwriting: .sereneSystemFallback
        )

        let first = PostcardMessagePlacementSearch.search(request)
        let second = PostcardMessagePlacementSearch.search(request)

        XCTAssertEqual(first, second)
        XCTAssertNotNil(first.placement)
        XCTAssertLessThanOrEqual(first.evaluatedCandidateCount, 400)
    }

    func testUniformSaliencyDensityDoesNotPenalizeTheLargerReadableFrame() throws {
        let message = "石板路绕过屋檐晚风把灯影和问候一起送回家。"
        let samples = PostcardSampleGrid.uniform(
            luminance: 0.7,
            red: 0.7,
            green: 0.7,
            blue: 0.7
        )
        let clear = PostcardMessagePlacementSearch.search(.init(
            message: message,
            analysis: PostcardVisualAnalysis(salientRegions: [], samples: samples),
            profile: .compact,
            containerSize: compactCanvas,
            handwriting: .sereneSystemFallback
        ))
        let uniformlySalient = PostcardMessagePlacementSearch.search(.init(
            message: message,
            analysis: PostcardVisualAnalysis(
                salientRegions: [
                    .init(rect: CGRect(x: 0, y: 0, width: 1, height: 1), weight: 0.8)
                ],
                samples: samples
            ),
            profile: .compact,
            containerSize: compactCanvas,
            handwriting: .sereneSystemFallback
        ))

        let clearPlacement = try XCTUnwrap(clear.placement)
        let salientPlacement = try XCTUnwrap(uniformlySalient.placement)
        XCTAssertEqual(salientPlacement.fontSize, clearPlacement.fontSize)
        XCTAssertEqual(salientPlacement.normalizedRect, clearPlacement.normalizedRect)
        XCTAssertLessThanOrEqual(uniformlySalient.typographyEvaluationCount, 126)
    }

    private func resolve(message: String, analysis: PostcardVisualAnalysis?) -> PostcardOverlayLayout {
        PostcardArtworkLayoutResolver.resolve(
            metadata: PostcardArtworkMetadata(event: event(message: message)),
            analysis: analysis,
            profile: .compact,
            containerSize: compactCanvas
        )
    }

    private func event(message: String) -> TripEvent {
        TripEvent(
            id: UUID(), tripID: UUID(), previousEventID: nil,
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000), phase: .postcardReady,
            location: Location(country: "Japan", city: "Kyoto", place: "Yasaka Lane"),
            transport: nil, summary: "夜游京都",
            mood: Mood(level: 2, label: "惬意", quote: message),
            continuityReferences: [], openHook: nil, consumedItemID: nil,
            postcardStatus: .ready, postcardRelativePath: "postcards/card.png"
        )
    }
}
