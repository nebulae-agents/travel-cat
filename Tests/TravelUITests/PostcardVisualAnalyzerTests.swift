import CoreGraphics
import Foundation
import XCTest
@testable import TravelUI

final class PostcardVisualAnalyzerTests: XCTestCase {
    func testDarkForegroundHeuristicDetectsConnectedSubjectAndExpandsItsBounds() throws {
        var luminance = [Double](repeating: 0.72, count: 12 * 8)
        for row in 4..<8 {
            for column in 0..<4 {
                luminance[row * 12 + column] = 0.06
            }
        }

        let region = try XCTUnwrap(PostcardVisualAnalyzer.darkForegroundRegions(
            in: sampleGrid(luminance: luminance)
        ).first)

        XCTAssertEqual(region.rect, CGRect(x: 0, y: 3.0 / 8.0, width: 5.0 / 12.0, height: 5.0 / 8.0))
        XCTAssertEqual(region.weight, 0.78)
    }

    func testDarkForegroundHeuristicIgnoresUniformNightScene() {
        let grid = sampleGrid(luminance: [Double](repeating: 0.05, count: 12 * 8))

        XCTAssertTrue(PostcardVisualAnalyzer.darkForegroundRegions(in: grid).isEmpty)
    }

    func testDarkForegroundHeuristicIgnoresTinyIsolatedShadows() {
        var luminance = [Double](repeating: 0.72, count: 12 * 8)
        luminance[72] = 0.04
        luminance[73] = 0.04

        XCTAssertTrue(PostcardVisualAnalyzer.darkForegroundRegions(
            in: sampleGrid(luminance: luminance)
        ).isEmpty)
    }

    func testChromaticLandmarkHeuristicDetectsConnectedWarmStructure() throws {
        var values = [PostcardPixelSample](
            repeating: PostcardPixelSample(luminance: 0.7, red: 0.7, green: 0.7, blue: 0.7),
            count: 12 * 8
        )
        for row in 0..<4 {
            for column in 8..<12 {
                values[row * 12 + column] = PostcardPixelSample(
                    luminance: 0.3,
                    red: 0.9,
                    green: 0.25,
                    blue: 0.12
                )
            }
        }
        let grid = PostcardSampleGrid(columns: 12, rows: 8, values: values)

        let region = try XCTUnwrap(PostcardVisualAnalyzer.chromaticLandmarkRegions(in: grid).first)
        XCTAssertGreaterThanOrEqual(region.weight, 0.7)
        XCTAssertGreaterThan(region.rect.minX, 0.5)
        XCTAssertLessThan(region.rect.minY, 0.2)
    }

    func testChromaticLandmarkHeuristicDetectsDesaturatedOrangeStructure() throws {
        var values = [PostcardPixelSample](
            repeating: .init(luminance: 0.65, red: 0.62, green: 0.74, blue: 0.88),
            count: 12 * 8
        )
        for row in 0..<3 {
            for column in 7..<11 {
                values[row * 12 + column] = .init(
                    luminance: 0.28,
                    red: 0.65,
                    green: 0.55,
                    blue: 0.53
                )
            }
        }

        let regions = PostcardVisualAnalyzer.chromaticLandmarkRegions(
            in: PostcardSampleGrid(columns: 12, rows: 8, values: values)
        )

        XCTAssertFalse(regions.isEmpty)
        XCTAssertGreaterThan(regions[0].rect.minX, 0.4)
    }

    func testAnalyzerProducesNormalizedBoundedDeterministicAnalysis() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Fixtures/Postcards/accepted-first.webp"))
        let image = try PostcardImageDecoder.decodeThumbnail(data: data)

        let first = try PostcardVisualAnalyzer.analyze(image)
        let second = try PostcardVisualAnalyzer.analyze(image)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.samples.columns, 12)
        XCTAssertEqual(first.samples.rows, 8)
        XCTAssertEqual(first.samples.values.count, 96)
        XCTAssertTrue(first.samples.values.allSatisfy { sample in
            sample.luminance.isFinite
                && sample.red.isFinite
                && sample.green.isFinite
                && sample.blue.isFinite
                && (0...1).contains(sample.luminance)
                && (0...1).contains(sample.red)
                && (0...1).contains(sample.green)
                && (0...1).contains(sample.blue)
        })
        XCTAssertTrue(first.salientRegions.allSatisfy { region in
            region.weight.isFinite
                && (0...1).contains(region.weight)
                && region.rect.minX >= 0
                && region.rect.maxX <= 1
                && region.rect.minY >= 0
                && region.rect.maxY <= 1
                && !region.rect.isEmpty
        })
    }

    func testAnalyzerSamplesTopToBottomInDisplayCoordinates() throws {
        let image = try makeImageWithLightTopAndDarkBottom()

        let analysis = try PostcardVisualAnalyzer.analyze(image)
        let top = analysis.samples.values.prefix(PostcardVisualAnalyzer.sampleColumns)
        let bottom = analysis.samples.values.suffix(PostcardVisualAnalyzer.sampleColumns)
        let topAverage = top.reduce(0) { $0 + $1.luminance } / Double(top.count)
        let bottomAverage = bottom.reduce(0) { $0 + $1.luminance } / Double(bottom.count)

        XCTAssertGreaterThan(topAverage, 0.9)
        XCTAssertLessThan(bottomAverage, 0.1)
        XCTAssertGreaterThan(topAverage, bottomAverage)
    }

    func testAnalyzerRetainsFourCandidateSpecificWorstWitnessesInsideEachAveragedCell() throws {
        let image = try makeImageWithGrayAndWhiteInsideEveryAnalysisCell()

        let analysis = try PostcardVisualAnalyzer.analyze(image)

        for sample in analysis.samples.values {
            let witnesses = sample.locationContrastWitnesses
            XCTAssertEqual(witnesses.allBackgrounds.count, 4)
            for dark in [witnesses.compactDarkBackground, witnesses.detailDarkBackground] {
                XCTAssertEqual(dark.red, 128.0 / 255.0, accuracy: 0.004)
                XCTAssertEqual(dark.green, 128.0 / 255.0, accuracy: 0.004)
                XCTAssertEqual(dark.blue, 128.0 / 255.0, accuracy: 0.004)
            }
            XCTAssertEqual(
                witnesses.compactLightBackground,
                PostcardColorSample(red: 1, green: 1, blue: 1)
            )
            XCTAssertEqual(
                witnesses.detailLightBackground,
                PostcardColorSample(red: 1, green: 1, blue: 1)
            )
            assertSendable(witnesses)
        }
    }

    func testTransparentPixelsCarryFailClosedLocationWitnesses() throws {
        let image = try makeTransparentImage()
        let analysis = try PostcardVisualAnalyzer.analyze(image)

        for profile in [PostcardOverlayProfile.compact, .detail] {
            XCTAssertNil(PostcardLocationInkResolver.resolve(
                backgroundSamples: analysis.samples.values,
                profile: profile
            ))
        }
    }

    func testAnalyzerPreservesSaturatedSourceChromaThroughCompactAndDetailCrops() throws {
        let image = try makeImageWithBlackWhiteAndRedInsideEveryAnalysisCell()
        let analysis = try PostcardVisualAnalyzer.analyze(image)

        XCTAssertTrue(analysis.samples.values.allSatisfy {
            $0.locationContrastWitnesses.maximumSourceChroma > 0.99
        })

        for (profile, size) in [
            (PostcardOverlayProfile.compact, CGSize(width: 322, height: 120)),
            (.detail, CGSize(width: 520, height: 230)),
        ] {
            let displayed = PostcardAspectFillTransform(
                imageSize: CGSize(width: image.width, height: image.height),
                containerSize: size
            ).displayAnalysis(analysis)

            for region in PostcardOverlayLayout.locationRegions {
                let rect = PostcardOverlayGeometry.rect(for: region, profile: profile)
                let witnesses = try XCTUnwrap(displayed.samples.locationContrastWitnesses(in: rect))
                XCTAssertGreaterThan(witnesses.maximumSourceChroma, 0.99)
                XCTAssertNil(PostcardLocationInkResolver.resolve(
                    backgroundWitnesses: witnesses,
                    profile: profile
                ))
            }
        }
    }

    func testMalformedRGBAStorageThrowsTypedError() {
        XCTAssertThrowsError(try PostcardVisualAnalyzer.samples(fromRGBABytes: [UInt8](repeating: 0, count: 95))) { error in
            XCTAssertEqual(error as? PostcardVisualAnalyzerError, .malformedBitmapStorage)
        }
    }

    func testRGBAByteOrderAndPremultipliedAlphaProduceExactSRGBSamples() throws {
        var bytes = [UInt8](repeating: 0, count: 12 * 8 * 4)
        bytes.replaceSubrange(0..<8, with: [64, 32, 16, 128, 255, 128, 64, 0])

        let samples = try PostcardVisualAnalyzer.samples(fromRGBABytes: bytes).values
        let first = samples[0]

        XCTAssertEqual(first.red, 0.5, accuracy: 0.004)
        XCTAssertEqual(first.green, 0.25, accuracy: 0.004)
        XCTAssertEqual(first.blue, 0.125, accuracy: 0.004)
        XCTAssertEqual(
            first.luminance,
            PostcardTextContrast.relativeLuminance(
                red: first.red,
                green: first.green,
                blue: first.blue
            ),
            accuracy: 0.000_001
        )
        XCTAssertEqual(samples[1], PostcardPixelSample(luminance: 0, red: 0, green: 0, blue: 0))
    }

    func testAnalyzerHonorsPreexistingCancellation() async throws {
        let image = try makeImageWithLightTopAndDarkBottom()
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try PostcardVisualAnalyzer.analyze(image)
        }

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testVisionRectangleConvertsFromBottomLeftAndClampsConfidence() throws {
        let region = try XCTUnwrap(PostcardVisualAnalyzer.salientRegion(
            fromVisionRect: CGRect(x: -0.2, y: 0.25, width: 0.6, height: 0.5),
            confidence: .infinity
        ))

        XCTAssertEqual(region.rect.minX, 0, accuracy: 0.000_001)
        XCTAssertEqual(region.rect.minY, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(region.rect.width, 0.4, accuracy: 0.000_001)
        XCTAssertEqual(region.rect.height, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(region.weight, 0)
        XCTAssertNil(PostcardVisualAnalyzer.salientRegion(
            fromVisionRect: CGRect(x: 1.2, y: 0, width: 0.2, height: 0.2),
            confidence: 0.8
        ))
    }

    func testAspectFillFiltersRealLakeAndMiyajimaLowConfidenceVisionPanoramasAfterCrop() {
        let scenes: [(animal: PostcardSalientRegion, cat: PostcardSalientRegion)] = [
            (
                .init(
                    rect: CGRect(x: 0.120178, y: 0.180052, width: 0.793885, height: 0.600703),
                    weight: 0.553223,
                    source: .animal
                ),
                .init(
                    rect: CGRect(x: 0.583333, y: 0.625, width: 0.416667, height: 0.208333),
                    weight: 0.78,
                    source: .heuristic
                )
            ),
            (
                .init(
                    rect: CGRect(x: 0.171997, y: 0.093013, width: 0.707398, height: 0.677507),
                    weight: 0.557129,
                    source: .animal
                ),
                .init(
                    rect: CGRect(x: 0.666667, y: 0, width: 0.25, height: 0.625),
                    weight: 0.74,
                    source: .heuristic
                )
            ),
        ]

        for scene in scenes {
            XCTAssertLessThan(scene.animal.rect.width * scene.animal.rect.height, 0.55)
            let displayed = PostcardAspectFillTransform(
                imageSize: CGSize(width: 1536, height: 1024),
                containerSize: CGSize(width: 520, height: 230)
            ).displayAnalysis(PostcardVisualAnalysis(
                salientRegions: [scene.animal, scene.cat],
                samples: .uniform(luminance: 0.5, red: 0.5, green: 0.5, blue: 0.5)
            ))
            XCTAssertFalse(displayed.salientRegions.contains { $0.source == .animal })
            XCTAssertTrue(displayed.salientRegions.contains { $0.source == .heuristic })
        }
    }

    func testDisplaySanitizerAlwaysFiltersLowConfidenceAttentionPanoramaButKeepsAnimalWithoutSubstitute() {
        let regions = [
            PostcardSalientRegion(
                rect: CGRect(x: 0, y: 0, width: 0.70, height: 0.80),
                weight: 0.60,
                source: .attention
            ),
            PostcardSalientRegion(
                rect: CGRect(x: 0.10, y: 0.10, width: 0.70, height: 0.80),
                weight: 0.60,
                source: .animal
            ),
        ]
        let displayed = identityDisplayAnalysis(regions)

        XCTAssertFalse(displayed.salientRegions.contains { $0.source == .attention })
        XCTAssertTrue(displayed.salientRegions.contains { $0.source == .animal })
    }

    func testAnimalPanoramaFiltersOnlyWithOverlappingLocalizedHeuristicSubstitute() {
        let animal = PostcardSalientRegion(
            rect: CGRect(x: 0.10, y: 0.10, width: 0.70, height: 0.80),
            weight: 0.60,
            source: .animal
        )
        let substitute = PostcardSalientRegion(
            rect: CGRect(x: 0.20, y: 0.25, width: 0.35, height: 0.40),
            weight: 0.78,
            source: .heuristic
        )
        let displayed = identityDisplayAnalysis([animal, substitute])

        XCTAssertFalse(displayed.salientRegions.contains { $0.source == .animal })
        XCTAssertTrue(displayed.salientRegions.contains { $0.source == .heuristic })
    }

    func testAnimalPanoramaIgnoresNonoverlappingAndIneligibleHeuristicSubstitutes() {
        let animal = PostcardSalientRegion(
            rect: CGRect(x: 0.05, y: 0.05, width: 0.70, height: 0.80),
            weight: 0.60,
            source: .animal
        )
        let nonoverlapping = PostcardSalientRegion(
            rect: CGRect(x: 0.80, y: 0.75, width: 0.15, height: 0.20),
            weight: 0.78,
            source: .heuristic
        )
        let lowWeight = PostcardSalientRegion(
            rect: CGRect(x: 0.15, y: 0.20, width: 0.25, height: 0.30),
            weight: 0.69,
            source: .heuristic
        )
        let panoramic = PostcardSalientRegion(
            rect: CGRect(x: 0.10, y: 0.10, width: 0.70, height: 0.80),
            weight: 0.78,
            source: .heuristic
        )

        for candidate in [nonoverlapping, lowWeight, panoramic] {
            let displayed = identityDisplayAnalysis([animal, candidate])
            XCTAssertTrue(displayed.salientRegions.contains { $0.source == .animal })
            XCTAssertTrue(displayed.salientRegions.contains { $0.source == .heuristic })
        }
    }

    func testDisplaySanitizerKeepsBoundaryHighConfidenceLocalAndHeuristicRegions() {
        let cases: [(PostcardSalientRegion, Bool)] = [
            (.init(rect: CGRect(x: 0, y: 0, width: 0.55, height: 1), weight: 0.55, source: .attention), true),
            (.init(rect: CGRect(x: 0, y: 0, width: 0.70, height: 0.80), weight: 0.78, source: .animal), true),
            (.init(rect: CGRect(x: 0.2, y: 0.2, width: 0.40, height: 0.40), weight: 0.60, source: .animal), true),
            (.init(rect: CGRect(x: 0, y: 0, width: 0.90, height: 1), weight: 0.40, source: .heuristic), true),
            (.init(rect: CGRect(x: 0, y: 0, width: 0.70, height: 0.80), weight: 0.60, source: .attention), false),
        ]

        for (region, shouldRemain) in cases {
            let displayed = identityDisplayAnalysis([region])
            XCTAssertEqual(displayed.salientRegions.count, shouldRemain ? 1 : 0, "\(region)")
        }
    }

    func testSaliencySourceRemainsInternalAndDoesNotAffectPublicEquality() throws {
        let attention = PostcardSalientRegion(
            rect: CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4),
            weight: 0.6,
            source: .attention
        )
        let animal = PostcardSalientRegion(
            rect: attention.rect,
            weight: attention.weight,
            source: .animal
        )
        XCTAssertEqual(attention, animal)

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/TravelUI/PostcardOverlayLayout.swift"))
        XCTAssertFalse(source.contains("public let source"))
    }

    private func identityDisplayAnalysis(
        _ regions: [PostcardSalientRegion]
    ) -> PostcardVisualAnalysis {
        PostcardAspectFillTransform(
            imageSize: CGSize(width: 100, height: 100),
            containerSize: CGSize(width: 100, height: 100)
        ).displayAnalysis(PostcardVisualAnalysis(
            salientRegions: regions,
            samples: .uniform(luminance: 0.5, red: 0.5, green: 0.5, blue: 0.5)
        ))
    }

    private func makeImageWithLightTopAndDarkBottom() throws -> CGImage {
        let width = PostcardVisualAnalyzer.sampleColumns
        let height = PostcardVisualAnalyzer.sampleRows
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            let component: UInt8 = row < height / 2 ? 255 : 0
            for column in 0..<width {
                let offset = (row * width + column) * 4
                bytes[offset] = component
                bytes[offset + 1] = component
                bytes[offset + 2] = component
                bytes[offset + 3] = 255
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )
        return try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }

    private func makeImageWithGrayAndWhiteInsideEveryAnalysisCell() throws -> CGImage {
        let width = PostcardVisualAnalyzer.sampleColumns * 2
        let height = PostcardVisualAnalyzer.sampleRows
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for row in 0..<height {
            for column in stride(from: 0, to: width, by: 2) {
                let offset = (row * width + column) * 4
                bytes[offset] = 128
                bytes[offset + 1] = 128
                bytes[offset + 2] = 128
                bytes[offset + 3] = 255
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )
        return try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }

    private func makeTransparentImage() throws -> CGImage {
        let width = PostcardVisualAnalyzer.sampleColumns
        let height = PostcardVisualAnalyzer.sampleRows
        let bytes = [UInt8](repeating: 0, count: width * height * 4)
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )
        return try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }

    private func makeImageWithBlackWhiteAndRedInsideEveryAnalysisCell() throws -> CGImage {
        let width = PostcardVisualAnalyzer.sampleColumns * 3
        let height = PostcardVisualAnalyzer.sampleRows
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for row in 0..<height {
            for cell in 0..<PostcardVisualAnalyzer.sampleColumns {
                for channel in 0..<3 {
                    let offset = (row * width + cell * 3 + channel) * 4
                    switch channel {
                    case 0:
                        bytes[offset] = 0
                        bytes[offset + 1] = 0
                        bytes[offset + 2] = 0
                    case 1:
                        bytes[offset] = 255
                        bytes[offset + 1] = 255
                        bytes[offset + 2] = 255
                    default:
                        bytes[offset] = 255
                        bytes[offset + 1] = 0
                        bytes[offset + 2] = 0
                    }
                    bytes[offset + 3] = 255
                }
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )
        return try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }

    private func sampleGrid(luminance: [Double]) -> PostcardSampleGrid {
        PostcardSampleGrid(
            columns: 12,
            rows: 8,
            values: luminance.map {
                PostcardPixelSample(luminance: $0, red: $0, green: $0, blue: $0)
            }
        )
    }

    private func assertSendable<T: Sendable>(_: T) {}
}
