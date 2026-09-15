import XCTest
import CoreGraphics
import ImageIO
import TravelCore
import TravelStorage
@testable import TravelUI

final class PostcardHandwritingVerifierTests: XCTestCase {
    func testBinaryInkDownsamplingEdgesAreNotStrokeInteriors() throws {
        let base = try image(width: 1152, height: 768, gray: 1)
        let ink = try png(width: 1200, height: 700,
            rect: CGRect(x: 103, y: 83, width: 997, height: 499), gray: 0, alpha: 1)
        let line = PostcardHandwritingVerifier.Observation(text: "中文！", confidence: 1,
            bounds: CGRect(x: 0.1, y: 0.15, width: 0.8, height: 0.6))
        XCTAssertNoThrow(try PostcardHandwritingVerifier.verify(event: event, base: base,
            inkData: ink, analysis: analysis(), observations: [line]))
    }

    func testOpaqueSourceStrokesWithoutCompactReadableCoresAreRejected() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1200, height: 700,
            bitsPerComponent: 8, bytesPerRow: 1200 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for x in stride(from: 100, to: 1100, by: 10) {
            context.fill(CGRect(x: x, y: 100, width: 1, height: 500))
        }
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let line = PostcardHandwritingVerifier.Observation(text: "中文！", confidence: 1,
            bounds: CGRect(x: 0.1, y: 0.15, width: 0.8, height: 0.6))
        XCTAssertThrowsError(try PostcardHandwritingVerifier.verify(event: event,
            base: image(width: 1152, height: 768, gray: 1), inkData: bytes as Data,
            analysis: analysis(), observations: [line])) {
            XCTAssertEqual($0 as? PostcardHandwritingVerifier.Rejection, .insufficientContrast)
        }
    }

    func testEstimatedHorizontalOverhangKeepsBytesViewportAndContrastGate() throws {
        let base = try image(width: 1152, height: 768, gray: 1)
        let ink = try png(width: 120, height: 70, rect: CGRect(x: 10, y: 8, width: 100, height: 50), gray: 0, alpha: 1)
        let raster = try PostcardPresentationStore.inspectHandwriting(ink)
        let line = PostcardHandwritingVerifier.Observation(text: "中文！", confidence: 1,
            bounds: CGRect(x: 0.05, y: 0.15, width: 0.9, height: 0.6))
        let verified = try PostcardHandwritingVerifier.verify(event: event, base: base, inkData: ink, analysis: analysis(), observations: [line])
        XCTAssertEqual(verified.pngData, ink)
        XCTAssertEqual(verified.viewport, raster.paddedViewport)
        let pale = try png(width: 120, height: 70, rect: CGRect(x: 10, y: 8, width: 100, height: 50), gray: 0.8, alpha: 1)
        XCTAssertThrowsError(try PostcardHandwritingVerifier.verify(event: event, base: base, inkData: pale, analysis: analysis(), observations: [line])) {
            XCTAssertEqual($0 as? PostcardHandwritingVerifier.Rejection, .insufficientContrast)
        }
    }

    func testEstimatedBoundsNeedMajorityOverlapOnEachAxis() throws {
        let base = try image(width: 1152, height: 768, gray: 1)
        let ink = try png(width: 120, height: 70, rect: CGRect(x: 30, y: 20, width: 60, height: 30), gray: 0, alpha: 1)
        let viewport = try PostcardPresentationStore.inspectHandwriting(ink).paddedViewport
        let bounds = [
            CGRect(x: 0, y: 0, width: 0.1, height: 0.1), // disjoint
            CGRect(x: 0, y: viewport.y, width: viewport.x, height: 0.4), // touch only
            CGRect(x: 0, y: viewport.y, width: viewport.x * 2, height: 0.4), // exactly half width
            CGRect(x: 0, y: viewport.y, width: viewport.x * 1.9, height: 0.4), // minority width
            CGRect(x: viewport.x, y: 0, width: 0.4, height: viewport.y * 2), // exactly half height
            CGRect(x: viewport.x, y: 0, width: 0.4, height: viewport.y * 1.9), // minority height
            CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.000001)
        ]
        for box in bounds {
            let line = PostcardHandwritingVerifier.Observation(text: "中文！", confidence: 1, bounds: box)
            XCTAssertThrowsError(try PostcardHandwritingVerifier.verify(event: event, base: base, inkData: ink, analysis: analysis(), observations: [line]), "\(box)") {
                XCTAssertEqual($0 as? PostcardHandwritingVerifier.Rejection, .unreadableText)
            }
        }
    }

    func testVerticalOverhangCannotCountInvisibleHeightTowardReadability() throws {
        let base = try image(width: 1152, height: 768, gray: 1)
        let ink = try png(width: 120, height: 70, rect: CGRect(x: 10, y: 8, width: 100, height: 50), gray: 0, alpha: 1)
        let viewport = try PostcardPresentationStore.inspectHandwriting(ink).paddedViewport
        let safe = try PostcardHandwritingVerifier.select(event: event, base: base, analysis: analysis()).safeArea
        let scale = min(safe.width * 1152 / (viewport.width * 120), safe.height * 768 / (viewport.height * 70))
        let pointsPerNormalizedHeight = 70 * scale * Double(TripAlbumLayout.readableCompactArtworkWidth) / 1152
        let visibleHeight = 11.0 / pointsPerNormalizedHeight
        let box = CGRect(x: 0.1, y: viewport.y - visibleHeight / 2, width: 0.8, height: visibleHeight * 1.5)
        XCTAssertGreaterThanOrEqual(box.height * pointsPerNormalizedHeight, 12)
        XCTAssertGreaterThanOrEqual(box.minY, 0)
        let line = PostcardHandwritingVerifier.Observation(text: "中文！", confidence: 1, bounds: box)
        XCTAssertThrowsError(try PostcardHandwritingVerifier.verify(event: event, base: base, inkData: ink, analysis: analysis(), observations: [line])) {
            XCTAssertEqual($0 as? PostcardHandwritingVerifier.Rejection, .unreadableText)
        }
    }

    func testRawOCRBoundsRejectNonpositiveNonfiniteAndOutsideImage() throws {
        let invalid = [
            CGRect(x: 0.1, y: 0.2, width: 0, height: 0.4),
            CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0),
            CGRect(x: 0.8, y: 0.2, width: -0.4, height: 0.4),
            CGRect(x: 0.1, y: 0.8, width: 0.4, height: -0.4),
            CGRect(x: CGFloat.nan, y: 0.2, width: 0.4, height: 0.4),
            CGRect(x: 0.1, y: CGFloat.infinity, width: 0.4, height: 0.4),
            CGRect(x: 0.1, y: 0.2, width: CGFloat.nan, height: 0.4),
            CGRect(x: 0.1, y: 0.2, width: 0.4, height: CGFloat.infinity),
            CGRect(x: -0.1, y: 0.2, width: 0.4, height: 0.4),
            CGRect(x: 0.8, y: 0.2, width: 0.4, height: 0.4)
        ]
        for box in invalid {
            XCTAssertThrowsError(try PostcardHandwritingVerifier.validateText("中文！", observations: [.init(text: "中文！", confidence: 1, bounds: box)]), "\(box)") {
                XCTAssertEqual($0 as? PostcardHandwritingVerifier.Rejection, .invalidText)
            }
        }
        XCTAssertThrowsError(try PostcardHandwritingVerifier.validateText("中文！", observations: [.init(text: "中文！", confidence: 0.5, bounds: CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.4))])) {
            XCTAssertEqual($0 as? PostcardHandwritingVerifier.Rejection, .invalidText)
        }
    }

    func testLineOrderAndReadabilityRejectWrongOrTinyLines() throws {
        let top = PostcardHandwritingVerifier.Observation(text: "中", confidence: 1, bounds: CGRect(x: 0.1, y: 0.1, width: 0.6, height: 0.2))
        let bottom = PostcardHandwritingVerifier.Observation(text: "文！", confidence: 1, bounds: CGRect(x: 0.1, y: 0.5, width: 0.6, height: 0.2))
        XCTAssertNoThrow(try PostcardHandwritingVerifier.validateText("中文！", observations: [bottom, top]))
        XCTAssertThrowsError(try PostcardHandwritingVerifier.validateText("文！中", observations: [bottom, top]))
        let tiny = PostcardHandwritingVerifier.Observation(text: "中文！", confidence: 1, bounds: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.01))
        let data = try png(width: 120, height: 70, rect: CGRect(x: 10, y: 8, width: 100, height: 50), gray: 0, alpha: 1)
        XCTAssertThrowsError(try PostcardHandwritingVerifier.verify(event: event, base: image(width: 1152, height: 768, gray: 1), inkData: data, analysis: analysis(), observations: [tiny])) { XCTAssertEqual($0 as? PostcardHandwritingVerifier.Rejection, .unreadableText) }
    }

    func testContrastUsesTopLeftActualSceneAndTranslucentComposite() throws {
        let white = try image(width: 1152, height: 768, gray: 1)
        let safe = try PostcardHandwritingVerifier.select(event: event, base: white, analysis: analysis()).safeArea
        let context = try XCTUnwrap(CGContext(data: nil, width: 1152, height: 768, bitsPerComponent: 8, bytesPerRow: 1152 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(white, in: CGRect(x: 0, y: 0, width: 1152, height: 768))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: safe.x * 1152, y: (1 - safe.y - safe.height) * 768, width: safe.width * 1152, height: safe.height * 768))
        let blackBehindInk = try XCTUnwrap(context.makeImage())
        let line = PostcardHandwritingVerifier.Observation(text: "中文！", confidence: 1, bounds: CGRect(x: 0.1, y: 0.15, width: 0.8, height: 0.6))
        for alpha: CGFloat in [1, 0.85] {
            let data = try png(width: 120, height: 70, rect: CGRect(x: 10, y: 8, width: 100, height: 50), gray: 0, alpha: alpha)
            XCTAssertNoThrow(try PostcardHandwritingVerifier.verify(event: event, base: white, inkData: data, analysis: analysis(), observations: [line]))
            XCTAssertThrowsError(try PostcardHandwritingVerifier.verify(event: event, base: blackBehindInk, inkData: data, analysis: analysis(), observations: [line])) { XCTAssertEqual($0 as? PostcardHandwritingVerifier.Rejection, .insufficientContrast) }
        }
        for (gray, alpha): (CGFloat, CGFloat) in [(0, 0.79), (0.5, 0.85)] {
            let data = try png(width: 120, height: 70, rect: CGRect(x: 10, y: 8, width: 100, height: 50), gray: gray, alpha: alpha)
            XCTAssertThrowsError(try PostcardHandwritingVerifier.verify(event: event, base: white, inkData: data, analysis: analysis(), observations: [line])) { XCTAssertEqual($0 as? PostcardHandwritingVerifier.Rejection, .insufficientContrast) }
        }
    }

    func testNativeScenePixelCannotDisappearInCompactAverage() throws {
        let white = try image(width: 1152, height: 768, gray: 1)
        let safe = try PostcardHandwritingVerifier.select(event: event, base: white, analysis: analysis()).safeArea
        let context = try XCTUnwrap(CGContext(data: nil, width: 1152, height: 768, bitsPerComponent: 8, bytesPerRow: 1152 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(white, in: CGRect(x: 0, y: 0, width: 1152, height: 768))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: floor((safe.x + safe.width / 2) * 1152), y: floor((1 - safe.y - safe.height / 2) * 768), width: 1, height: 1))
        let data = try png(width: 120, height: 70, rect: CGRect(x: 10, y: 8, width: 100, height: 50), gray: 0, alpha: 1)
        let line = PostcardHandwritingVerifier.Observation(text: "中文！", confidence: 1, bounds: CGRect(x: 0.1, y: 0.15, width: 0.8, height: 0.6))
        XCTAssertThrowsError(try PostcardHandwritingVerifier.verify(event: event, base: XCTUnwrap(context.makeImage()), inkData: data, analysis: analysis(), observations: [line])) { XCTAssertEqual($0 as? PostcardHandwritingVerifier.Rejection, .insufficientContrast) }
    }

    func testOpaqueDotCannotHideFaintStrokeInteriors() throws {
        try assertOpaqueDotCannotHideFaintStroke(height: 50)
    }

    func testOpaqueDotCannotHideThinFaintStroke() throws {
        try assertOpaqueDotCannotHideFaintStroke(height: 1)
    }

    func testOpaqueBlockCannotHideFaintSourceComponentLostInReduction() throws {
        for alpha: CGFloat in [0.2, 0.79] {
            try assertOpaqueBlockCannotHideReducedComponent(alpha: alpha)
        }
    }

    private func assertOpaqueBlockCannotHideReducedComponent(alpha: CGFloat) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1200, height: 700,
            bitsPerComponent: 8, bytesPerRow: 1200 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0, alpha: alpha))
        context.fill(CGRect(x: 100, y: 100, width: 1000, height: 3))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 100, y: 150, width: 100, height: 450))
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let line = PostcardHandwritingVerifier.Observation(text: "中文！", confidence: 1,
            bounds: CGRect(x: 0.1, y: 0.15, width: 0.8, height: 0.6))
        XCTAssertThrowsError(try PostcardHandwritingVerifier.verify(event: event,
            base: image(width: 1152, height: 768, gray: 1), inkData: bytes as Data,
            analysis: analysis(), observations: [line])) {
            XCTAssertEqual($0 as? PostcardHandwritingVerifier.Rejection, .insufficientContrast)
        }
    }

    func testSinglePixelFaintFringeNextToOpacityCoreRemainsAccepted() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1200, height: 700,
            bitsPerComponent: 8, bytesPerRow: 1200 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0, alpha: 0.2))
        context.fill(CGRect(x: 100, y: 100, width: 1000, height: 500))
        context.setFillColor(CGColor(gray: 0, alpha: 0.85))
        context.fill(CGRect(x: 101, y: 101, width: 998, height: 498))
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let line = PostcardHandwritingVerifier.Observation(text: "中文！", confidence: 1,
            bounds: CGRect(x: 0.1, y: 0.15, width: 0.8, height: 0.6))
        XCTAssertNoThrow(try PostcardHandwritingVerifier.verify(event: event,
            base: image(width: 1152, height: 768, gray: 1), inkData: bytes as Data,
            analysis: analysis(), observations: [line]))
    }

    private func assertOpaqueDotCannotHideFaintStroke(height: CGFloat) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 120, height: 70, bitsPerComponent: 8, bytesPerRow: 120 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0, alpha: 0.2))
        context.fill(CGRect(x: 10, y: 12, width: 100, height: height))
        // Separate marks maintain a readable-size bounding box even for a thin stroke.
        context.fill(CGRect(x: 10, y: 61, width: 100, height: 1))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 12, y: 14, width: 5, height: 5))
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let line = PostcardHandwritingVerifier.Observation(text: "中文！", confidence: 1, bounds: CGRect(x: 0.1, y: 0.15, width: 0.8, height: 0.6))
        XCTAssertThrowsError(try PostcardHandwritingVerifier.verify(event: event, base: image(width: 1152, height: 768, gray: 1), inkData: bytes as Data, analysis: analysis(), observations: [line])) {
            XCTAssertEqual($0 as? PostcardHandwritingVerifier.Rejection, .insufficientContrast)
        }
    }

    func testRealVisionRejectsNonTextInkWithoutInjectedOCR() throws {
        let data = try png(width: 120, height: 70, rect: CGRect(x: 10, y: 8, width: 100, height: 50), gray: 0, alpha: 1)
        XCTAssertThrowsError(try PostcardHandwritingVerifier.verify(event: event, base: image(width: 1152, height: 768, gray: 1), inkData: data, analysis: analysis()))
    }

    func testAlreadyCancelledInspectionStops() async {
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try PostcardPresentationStore.inspectHandwriting(Data())
        }
        do { _ = try await operation.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testOCRRequiresExactWhitespaceOnlyUTF8AndConfidence() throws {
        let bounds = CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.4)
        func line(_ text: String, _ confidence: Float = 1, alternative: String? = nil) -> PostcardHandwritingVerifier.Observation {
            .init(text: text, confidence: confidence, bounds: bounds,
                  alternatives: alternative.map { [.init(text: $0, confidence: 0.95)] } ?? [])
        }
        XCTAssertNoThrow(try PostcardHandwritingVerifier.validateText("中 文！", observations: [line("中文！")]))
        for observations in [[], [line("中文")], [line("中文！", 0.89)], [line("中文！", alternative: "中文?")]] {
            XCTAssertThrowsError(try PostcardHandwritingVerifier.validateText("中文！", observations: observations))
        }
        XCTAssertThrowsError(try PostcardHandwritingVerifier.validateText("caf\u{e9}", observations: [line("cafe\u{301}")]))
    }

    func testRasterTopLeftBoundsIncludeEveryTranslucentPixel() throws {
        let data = try png(width: 80, height: 40, rect: CGRect(x: 7, y: 4, width: 40, height: 20), gray: 0, alpha: 0.85)
        let raster = try PostcardPresentationStore.inspectHandwriting(data)
        XCTAssertEqual(raster.inkBounds, CGRect(x: 7, y: 4, width: 40, height: 20))
        XCTAssertEqual(raster.paddedViewport, .init(x: 5.0 / 80, y: 2.0 / 40, width: 44.0 / 80, height: 24.0 / 40))
    }

    func testMissingOrFullForegroundRejectsSelection() throws {
        let base = try image(width: 1152, height: 768, gray: 1)
        XCTAssertThrowsError(try PostcardHandwritingVerifier.select(event: event, base: base, analysis: analysis(regions: [])))
        XCTAssertThrowsError(try PostcardHandwritingVerifier.select(event: event, base: base, analysis: analysis(regions: [CGRect(x: 0, y: 0, width: 1, height: 1)])))
    }

    func testGeometryRecheckRejectsLocationAndForegroundPadding() throws {
        let frame = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        let original = PostcardArtworkLayoutResolver.resolve(metadata: .init(event: event), analysis: analysis(), profile: .detail, containerSize: CGSize(width: 1152, height: 768))
        let layout = PostcardOverlayLayout(locationRegion: original.locationRegion, locationSafetyRect: frame, showsLocationLabel: true, messageRegion: original.messageRegion, messageFontSize: original.messageFontSize, inkStyle: original.inkStyle, accent: original.accent)
        XCTAssertThrowsError(try PostcardHandwritingVerifier.checkGeometry(frame, layout: layout, analysis: analysis()))
        let near = analysis(regions: [CGRect(x: 0.305, y: 0.1, width: 0.2, height: 0.2)])
        XCTAssertThrowsError(try PostcardHandwritingVerifier.checkGeometry(frame, layout: original, analysis: near))
    }

    func testUniformPlacementExactBytesAndBareContrast() throws {
        let base = try image(width: 1152, height: 768, gray: 1)
        let ink = try png(width: 120, height: 70, rect: CGRect(x: 10, y: 8, width: 100, height: 50), gray: 0, alpha: 1)
        let observations = [PostcardHandwritingVerifier.Observation(text: "中文！", confidence: 1, bounds: CGRect(x: 10.0 / 120, y: 8.0 / 70, width: 100.0 / 120, height: 50.0 / 70))]
        let value = try PostcardHandwritingVerifier.verify(event: event, base: base, inkData: ink, analysis: analysis(), observations: observations)
        XCTAssertEqual(value.pngData, ink)
        XCTAssertTrue(value.placement.isValid)
        XCTAssertEqual(value.placement.width * 1152 / (value.placement.height * 768), 104.0 / 54, accuracy: 0.001)
        let pale = try png(width: 120, height: 70, rect: CGRect(x: 10, y: 8, width: 100, height: 50), gray: 0.8, alpha: 1)
        XCTAssertThrowsError(try PostcardHandwritingVerifier.verify(event: event, base: base, inkData: pale, analysis: analysis(), observations: observations))
    }

    private var event: TripEvent {
        TripEvent(id: UUID(), tripID: UUID(), previousEventID: nil, occurredAt: Date(), phase: .postcardReady, location: nil, transport: nil, summary: "", mood: Mood(level: 4, label: "calm", quote: "中文！"), continuityReferences: [], openHook: nil, consumedItemID: nil, postcardStatus: .ready, postcardRelativePath: nil)
    }
    private func analysis(regions: [CGRect] = [CGRect(x: 0.42, y: 0.35, width: 0.2, height: 0.4)]) -> PostcardVisualAnalysis {
        .init(salientRegions: [], samples: .init(columns: 1, rows: 1, values: [.init(luminance: 1, red: 1, green: 1, blue: 1)]), foregroundRegions: regions)
    }
    private func image(width: Int, height: Int, gray: CGFloat) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: gray, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }
    private func png(width: Int, height: Int, rect: CGRect, gray: CGFloat, alpha: CGFloat) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: gray, alpha: alpha))
        context.fill(CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height))
        let bytes = NSMutableData(); let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination)); return bytes as Data
    }
}
