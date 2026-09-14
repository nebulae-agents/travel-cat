import CoreGraphics
import XCTest
import TravelCore
@testable import TravelUI

final class PostcardImageGeometryTests: XCTestCase {
    func testActualWideCardAnchorsBottomSubjectInsideCanvas() {
        let subject = CGRect(x: 0.62, y: 0.72, width: 0.13, height: 0.21)
        let geometry = PostcardImageGeometry(
            imageSize: CGSize(width: 1536, height: 1024),
            containerSize: CGSize(width: 696, height: 230),
            analysis: analysis(foreground: [subject])
        )

        XCTAssertEqual(geometry.contentMode, .subjectPreservingFill)
        XCTAssertEqual(geometry.imageFrame.minX, 0, accuracy: 0.001)
        XCTAssertEqual(geometry.imageFrame.width, 696, accuracy: 0.001)
        XCTAssertEqual(geometry.imageFrame.height, 464, accuracy: 0.001)
        XCTAssertEqual(geometry.imageFrame.minY, -208.48, accuracy: 0.01)
        XCTAssertEqual(geometry.visibleCanvas, CGRect(x: 0, y: 0, width: 696, height: 230))
        XCTAssertLessThanOrEqual(geometry.displayRect(forImageNormalized: subject).maxY, 1)
    }

    func testSubjectsAtEachImageEdgeRemainVisible() {
        let cases = [
            CGRect(x: 0.35, y: 0, width: 0.3, height: 0.1),
            CGRect(x: 0.35, y: 0.9, width: 0.3, height: 0.1),
            CGRect(x: 0, y: 0.35, width: 0.1, height: 0.3),
            CGRect(x: 0.9, y: 0.35, width: 0.1, height: 0.3),
        ]
        for subject in cases {
            let geometry = PostcardImageGeometry(
                imageSize: CGSize(width: 400, height: 400),
                containerSize: CGSize(width: 300, height: 180),
                analysis: analysis(protected: [subject])
            )
            let displayed = geometry.displayRect(forImageNormalized: subject)
            XCTAssertEqual(geometry.contentMode, .subjectPreservingFill)
            XCTAssertGreaterThanOrEqual(displayed.minX, -0.0001)
            XCTAssertGreaterThanOrEqual(displayed.minY, -0.0001)
            XCTAssertLessThanOrEqual(displayed.maxX, 1.0001)
            XCTAssertLessThanOrEqual(displayed.maxY, 1.0001)
        }
    }

    func testNarrowTallImageAnchorsBottomSubjectInsideCanvas() {
        let subject = CGRect(x: 0.3, y: 0.88, width: 0.4, height: 0.12)
        let geometry = PostcardImageGeometry(
            imageSize: CGSize(width: 100, height: 400),
            containerSize: CGSize(width: 180, height: 300),
            analysis: analysis(protected: [subject])
        )

        XCTAssertEqual(geometry.contentMode, .subjectPreservingFill)
        XCTAssertEqual(geometry.imageFrame.width, 180, accuracy: 0.001)
        XCTAssertEqual(geometry.imageFrame.height, 720, accuracy: 0.001)
        XCTAssertLessThanOrEqual(geometry.displayRect(forImageNormalized: subject).maxY, 1.0001)
    }

    func testNarrowTallContainerPreservesSubjectsAtLeftAndRightEdges() {
        for subject in [
            CGRect(x: 0, y: 0.35, width: 0.04, height: 0.3),
            CGRect(x: 0.96, y: 0.35, width: 0.04, height: 0.3),
        ] {
            let geometry = PostcardImageGeometry(
                imageSize: CGSize(width: 400, height: 100),
                containerSize: CGSize(width: 100, height: 300),
                analysis: analysis(protected: [subject])
            )
            let displayed = geometry.displayRect(forImageNormalized: subject)
            XCTAssertEqual(geometry.contentMode, .subjectPreservingFill)
            XCTAssertFalse(displayed.isEmpty)
            XCTAssertGreaterThanOrEqual(displayed.minX, -0.0001)
            XCTAssertLessThanOrEqual(displayed.maxX, 1.0001)
            assertEqual(
                geometry.imageRect(forDisplayNormalized: displayed),
                subject,
                accuracy: 0.0001
            )
        }
    }

    @MainActor
    func testPreviewProtectionMapsFromContainerIntoFitCanvas() {
        let canvas = CGRect(x: 0, y: 52.5, width: 300, height: 75)
        let previewFrame = CGRect(x: 240, y: 100, width: 40, height: 40)

        let mapped = PostcardArtworkView.normalizedPreviewProtection(
            previewFrame, visibleCanvas: canvas
        )

        assertEqual(
            mapped,
            CGRect(x: 0.8, y: 47.5 / 75, width: 40.0 / 300, height: 27.5 / 75),
            accuracy: 0.0001
        )
    }

    @MainActor
    func testPreviewProtectionOutsideFitCanvasIsEmpty() {
        XCTAssertEqual(
            PostcardArtworkView.normalizedPreviewProtection(
                CGRect(x: 20, y: 5, width: 30, height: 20),
                visibleCanvas: CGRect(x: 0, y: 52.5, width: 300, height: 75)
            ),
            .zero
        )
    }

    func testInfeasibleProtectedUnionFallsBackToFit() {
        let geometry = PostcardImageGeometry(
            imageSize: CGSize(width: 400, height: 100),
            containerSize: CGSize(width: 100, height: 100),
            analysis: analysis(protected: [
                CGRect(x: 0, y: 0.2, width: 0.15, height: 0.6),
                CGRect(x: 0.85, y: 0.2, width: 0.15, height: 0.6),
            ])
        )

        XCTAssertEqual(geometry.contentMode, .fit)
        XCTAssertEqual(geometry.imageFrame, CGRect(x: 0, y: 37.5, width: 100, height: 25))
        XCTAssertEqual(geometry.visibleCanvas, geometry.imageFrame)
    }

    func testUnknownAndInvalidAnalysisUseFit() {
        let unknown = PostcardImageGeometry(
            imageSize: CGSize(width: 400, height: 200),
            containerSize: CGSize(width: 100, height: 100),
            analysis: nil
        )
        let invalid = PostcardImageGeometry(
            imageSize: CGSize(width: 400, height: 200),
            containerSize: CGSize(width: 100, height: 100),
            analysis: PostcardVisualAnalysis(salientRegions: [], samples: .init(columns: 0, rows: 0, values: []))
        )

        XCTAssertEqual(unknown.contentMode, .fit)
        XCTAssertEqual(invalid.contentMode, .fit)
        XCTAssertEqual(unknown.imageFrame, CGRect(x: 0, y: 25, width: 100, height: 50))
    }

    func testNonfiniteDimensionsProduceEmptyFitGeometry() {
        let geometry = PostcardImageGeometry(
            imageSize: CGSize(width: CGFloat.infinity, height: 200),
            containerSize: CGSize(width: 100, height: 100),
            analysis: analysis(foreground: [CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)])
        )

        XCTAssertEqual(geometry.contentMode, .fit)
        XCTAssertEqual(geometry.imageFrame, .zero)
        XCTAssertEqual(geometry.visibleCanvas, .zero)
    }

    func testAnimalAloneCannotEstablishCoverageButCredibleAnimalJoinsForegroundAnchor() {
        let animal = PostcardSalientRegion(
            rect: CGRect(x: 0.65, y: 0.75, width: 0.2, height: 0.2),
            weight: 0.9,
            source: .animal
        )
        let animalOnly = PostcardVisualAnalysis(salientRegions: [animal], samples: samples)
        let anchored = PostcardVisualAnalysis(
            salientRegions: [animal], samples: samples,
            foregroundRegions: [CGRect(x: 0.6, y: 0.7, width: 0.1, height: 0.1)]
        )

        XCTAssertEqual(PostcardImageGeometry(
            imageSize: CGSize(width: 400, height: 400), containerSize: CGSize(width: 300, height: 180),
            analysis: animalOnly).contentMode, .fit)
        let anchoredGeometry = PostcardImageGeometry(
            imageSize: CGSize(width: 400, height: 400), containerSize: CGSize(width: 300, height: 180),
            analysis: anchored)
        XCTAssertEqual(anchoredGeometry.contentMode, .subjectPreservingFill)
        let displayedAnimal = anchoredGeometry.displayRect(forImageNormalized: animal.rect)
        XCTAssertLessThanOrEqual(displayedAnimal.maxY, 1)
        let protectedAnimal = anchoredGeometry.displayAnalysis(anchored).protectedRegions
            .first { $0.intersects(displayedAnimal) }
        XCTAssertNotNil(protectedAnimal)
        assertEqual(protectedAnimal ?? .zero, displayedAnimal, accuracy: 0.0001)
    }

    func testImageAndDisplayTransformsRoundTripInFillAndFit() {
        let source = CGRect(x: 0.35, y: 0.4, width: 0.12, height: 0.1)
        let geometries = [
            PostcardImageGeometry(
                imageSize: CGSize(width: 600, height: 400), containerSize: CGSize(width: 300, height: 160),
                analysis: analysis(foreground: [source])),
            PostcardImageGeometry(
                imageSize: CGSize(width: 600, height: 400), containerSize: CGSize(width: 300, height: 160),
                analysis: nil),
        ]
        for geometry in geometries {
            let displayed = geometry.displayRect(forImageNormalized: source)
            let roundTrip = geometry.imageRect(forDisplayNormalized: displayed)
            assertEqual(roundTrip, source, accuracy: 0.0001)
        }
    }

    func testFitCanvasStillPlacesShortQuoteOnImageWhenPictureHasSafeSpace() {
        let raw = analysis(protected: [
            CGRect(x: 0, y: 0.4, width: 0.05, height: 0.2),
            CGRect(x: 0.95, y: 0.4, width: 0.05, height: 0.2),
        ])
        let geometry = PostcardImageGeometry(
            imageSize: CGSize(width: 400, height: 100),
            containerSize: CGSize(width: 300, height: 180),
            analysis: raw
        )
        let layout = PostcardArtworkLayoutResolver.resolve(
            metadata: PostcardArtworkMetadata(event: postcardEvent(quote: "风正好。")),
            analysis: geometry.displayAnalysis(raw),
            profile: .detail,
            containerSize: geometry.visibleCanvas.size
        )

        XCTAssertEqual(geometry.contentMode, .fit)
        XCTAssertEqual(layout.messagePlacement, .onImage)
    }

    func testFitCanvasFallsBackBelowImageWhenPictureIsOccupied() {
        let raw = analysis(foreground: [
            CGRect(x: 0, y: 0, width: 0.5, height: 1),
            CGRect(x: 0.5, y: 0, width: 0.5, height: 1),
        ])
        let geometry = PostcardImageGeometry(
            imageSize: CGSize(width: 400, height: 100),
            containerSize: CGSize(width: 300, height: 180),
            analysis: raw
        )
        let layout = PostcardArtworkLayoutResolver.resolve(
            metadata: PostcardArtworkMetadata(event: postcardEvent(quote: "风正好。")),
            analysis: geometry.displayAnalysis(raw),
            profile: .detail,
            containerSize: geometry.visibleCanvas.size
        )

        XCTAssertEqual(geometry.contentMode, .fit)
        XCTAssertEqual(layout.messagePlacement, .belowImage)
    }

    private let samples = PostcardSampleGrid.uniform(luminance: 0.5, red: 0.5, green: 0.5, blue: 0.5)

    private func analysis(
        protected: [CGRect] = [],
        foreground: [CGRect] = []
    ) -> PostcardVisualAnalysis {
        PostcardVisualAnalysis(
            salientRegions: [], samples: samples,
            protectedRegions: protected, foregroundRegions: foreground
        )
    }

    private func postcardEvent(quote: String) -> TripEvent {
        TripEvent(
            id: UUID(), tripID: UUID(), previousEventID: nil,
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000), phase: .postcardReady,
            location: Location(country: "中国", city: "杭州", place: "河坊街"),
            transport: nil, summary: "夜游", mood: Mood(level: 2, label: "惬意", quote: quote),
            continuityReferences: [], openHook: nil, consumedItemID: nil,
            postcardStatus: .ready, postcardRelativePath: "postcards/card.png"
        )
    }

    private func assertEqual(_ lhs: CGRect, _ rhs: CGRect, accuracy: CGFloat) {
        XCTAssertEqual(lhs.minX, rhs.minX, accuracy: accuracy)
        XCTAssertEqual(lhs.minY, rhs.minY, accuracy: accuracy)
        XCTAssertEqual(lhs.width, rhs.width, accuracy: accuracy)
        XCTAssertEqual(lhs.height, rhs.height, accuracy: accuracy)
    }
}
