import XCTest
@testable import TravelUI

final class PostcardInkStyleTests: XCTestCase {
    func testSemanticInkTypesAreSendable() {
        func requireSendable<T: Sendable>(_: T.Type) {}
        requireSendable(PostcardInkResolver.self)
        requireSendable(PostcardInkStyle.self)
        requireSendable(PostcardInkColor.self)
    }

    func testSceneFamiliesProduceDistinctRestrainedInk() {
        let lake = resolve(.init(luminance: 0.62, red: 0.20, green: 0.55, blue: 0.82), range: 0.45...0.78)
        let shrine = resolve(.init(luminance: 0.55, red: 0.85, green: 0.31, blue: 0.12), range: 0.30...0.74)
        let forest = resolve(.init(luminance: 0.68, red: 0.24, green: 0.63, blue: 0.30), range: 0.50...0.82)
        let gray = resolve(.init(luminance: 0.72, red: 0.68, green: 0.69, blue: 0.70), range: 0.61...0.79)

        XCTAssertEqual(lake.sceneFamily, .lakeBlue)
        XCTAssertEqual(shrine.sceneFamily, .warmEarth)
        XCTAssertEqual(forest.sceneFamily, .forestGreen)
        XCTAssertEqual(gray.sceneFamily, .neutral)
        XCTAssertNotEqual(lake.foreground, shrine.foreground)
        XCTAssertNotEqual(shrine.foreground, forest.foreground)
        XCTAssertNotEqual(forest.foreground, gray.foreground)
        for style in [lake, shrine, forest, gray] {
            XCTAssertLessThanOrEqual(saturation(style.foreground), 0.78)
            XCTAssertGreaterThanOrEqual(style.minimumContrastRatio, 4.5 - 0.000_001)
        }
    }

    func testPawOpacityUsesStrengthenedSemanticRangeAcrossSceneAndUnknownStyles() {
        let lake = resolve(.init(luminance: 0.62, red: 0.20, green: 0.55, blue: 0.82), range: 0.45...0.78)
        let shrine = resolve(.init(luminance: 0.55, red: 0.85, green: 0.31, blue: 0.12), range: 0.30...0.74)
        let forest = resolve(.init(luminance: 0.68, red: 0.24, green: 0.63, blue: 0.30), range: 0.50...0.82)
        let gray = resolve(.init(luminance: 0.72, red: 0.68, green: 0.69, blue: 0.70), range: 0.61...0.79)
        let sceneOpacities = [lake, shrine, forest, gray].map(\.pawOpacity)

        XCTAssertTrue(sceneOpacities.allSatisfy { (0.68...0.82).contains($0) })
        XCTAssertGreaterThan(Set(sceneOpacities).count, 1)
        XCTAssertTrue((0.68...0.82).contains(PostcardInkResolver.unknownStyle.pawOpacity))
    }

    func testPawOpacityInitializerClampsEverySemanticPathToTheSameBounds() {
        func style(pawOpacity: Double) -> PostcardInkStyle {
            PostcardInkStyle(
                foreground: .init(red: 0.2, green: 0.3, blue: 0.4),
                wash: .init(red: 0.9, green: 0.8, blue: 0.7),
                washOpacity: 0.2,
                shadow: .init(red: 0.1, green: 0.1, blue: 0.1),
                shadowOpacity: 0.2,
                shadowRadius: 2,
                pawOpacity: pawOpacity,
                sceneFamily: .neutral,
                minimumContrastRatio: 4.5
            )
        }

        XCTAssertEqual(style(pawOpacity: -1).pawOpacity, 0.68, accuracy: 0.000_001)
        XCTAssertEqual(style(pawOpacity: 1).pawOpacity, 0.82, accuracy: 0.000_001)
        XCTAssertEqual(style(pawOpacity: .nan).pawOpacity, 0.74, accuracy: 0.000_001)
    }

    func testGreenSceneChoosesDarkForestInkOnLightAndIvoryOnDark() {
        let sample = PostcardPixelSample(luminance: 0.5, red: 0.18, green: 0.58, blue: 0.28)
        let light = resolve(sample, range: 0.60...0.82)
        let dark = resolve(sample, range: 0.03...0.13)

        XCTAssertEqual(light.sceneFamily, .forestGreen)
        XCTAssertFalse(light.usesLightText)
        XCTAssertTrue(dark.usesLightText)
        XCTAssertGreaterThan(dark.foreground.red, dark.foreground.green)
        XCTAssertGreaterThan(dark.foreground.green, dark.foreground.blue)
    }

    func testMixedBackgroundAddsLocalizedTreatmentAndGuaranteesBothEndpoints() {
        let range = 0.04...0.92
        let style = resolve(
            .init(luminance: 0.52, red: 0.32, green: 0.46, blue: 0.68),
            range: range,
            variance: 0.18
        )

        XCTAssertGreaterThan(style.washOpacity, 0)
        XCTAssertGreaterThan(style.shadowOpacity, 0)
        XCTAssertGreaterThan(style.shadowRadius, 0)
        assertContrast(style, against: range)
    }

    func testContrastUsesActualSRGBAlphaCompositeInsteadOfLuminanceInterpolation() {
        let background = PostcardPixelSample(
            luminance: PostcardTextContrast.relativeLuminance(red: 0.45, green: 0.40, blue: 0.65),
            red: 0.45,
            green: 0.40,
            blue: 0.65
        )
        let style = PostcardInkResolver.resolve(
            sample: background,
            backgroundSamples: [background],
            colorVariance: 0.002,
            isUnknown: false
        )

        let composited = alphaComposite(
            background: background,
            wash: style.wash,
            opacity: style.washOpacity
        )
        XCTAssertGreaterThanOrEqual(
            PostcardTextContrast.contrastRatio(
                foregroundLuminance: style.foreground.relativeLuminance,
                backgroundLuminance: composited.relativeLuminance
            ),
            4.5 - 0.000_001
        )
        XCTAssertGreaterThanOrEqual(style.minimumContrastRatio, 4.5 - 0.000_001)
    }

    func testEightBitRendererQuantizationKeepsKnownWorstProbeAboveContrastFloor() {
        let backgrounds = [
            PostcardPixelSample(luminance: 0, red: 0.45, green: 0.40, blue: 0.65),
            PostcardPixelSample(luminance: 0, red: 0.375, green: 0.375, blue: 0.65625),
        ]
        let style = PostcardInkResolver.resolve(
            sample: backgrounds[0],
            backgroundSamples: backgrounds,
            colorVariance: 0.08,
            isUnknown: false
        )

        for background in backgrounds {
            XCTAssertGreaterThanOrEqual(
                rendererQuantizedContrast(style: style, background: background),
                4.5,
                "background \(background)"
            )
            XCTAssertGreaterThanOrEqual(
                conservativeQuantizedContrast(style: style, background: background),
                4.5,
                "platform rounding bounds for \(background)"
            )
        }
    }

    func testThirtyThreeCubedColorGridSurvivesEightBitRendererQuantization() {
        let backgrounds = (0...32).flatMap { red in
            (0...32).flatMap { green in
                (0...32).map { blue in
                    PostcardPixelSample(
                        luminance: 0,
                        red: Double(red) / 32,
                        green: Double(green) / 32,
                        blue: Double(blue) / 32
                    )
                }
            }
        }
        let style = PostcardInkResolver.resolve(
            sample: .init(luminance: 0.5, red: 0.4, green: 0.5, blue: 0.6),
            backgroundSamples: backgrounds,
            colorVariance: 1,
            isUnknown: false
        )
        let minimum = backgrounds.lazy.map {
            self.rendererQuantizedContrast(style: style, background: $0)
        }.min() ?? 0
        let conservativeMinimum = backgrounds.lazy.map {
            self.conservativeQuantizedContrast(style: style, background: $0)
        }.min() ?? 0

        XCTAssertGreaterThanOrEqual(minimum, 4.5)
        XCTAssertGreaterThanOrEqual(conservativeMinimum, 4.5)
        XCTAssertGreaterThanOrEqual(style.minimumContrastRatio, 4.5)
    }

    func testEachColorIndependentlySurvivesEightBitRendererQuantization() {
        var worstRendered: (ratio: Double, background: PostcardPixelSample, style: PostcardInkStyle)?
        var worstConservative: (ratio: Double, background: PostcardPixelSample, style: PostcardInkStyle)?
        var worstReported: (ratio: Double, background: PostcardPixelSample, style: PostcardInkStyle)?

        for red in 0...32 {
            for green in 0...32 {
                for blue in 0...32 {
                    let background = PostcardPixelSample(
                        luminance: 0,
                        red: Double(red) / 32,
                        green: Double(green) / 32,
                        blue: Double(blue) / 32
                    )
                    let style = PostcardInkResolver.resolve(
                        sample: background,
                        backgroundSamples: [background],
                        colorVariance: 0,
                        isUnknown: false
                    )
                    let rendered = rendererQuantizedContrast(style: style, background: background)
                    let conservative = conservativeQuantizedContrast(style: style, background: background)

                    if worstRendered == nil || rendered < worstRendered!.ratio {
                        worstRendered = (rendered, background, style)
                    }
                    if worstConservative == nil || conservative < worstConservative!.ratio {
                        worstConservative = (conservative, background, style)
                    }
                    if worstReported == nil || style.minimumContrastRatio < worstReported!.ratio {
                        worstReported = (style.minimumContrastRatio, background, style)
                    }
                }
            }
        }

        XCTAssertGreaterThanOrEqual(
            worstRendered?.ratio ?? 0,
            4.5,
            "renderer worst case: \(String(describing: worstRendered))"
        )
        XCTAssertGreaterThanOrEqual(
            worstConservative?.ratio ?? 0,
            4.5,
            "platform rounding worst case: \(String(describing: worstConservative))"
        )
        XCTAssertGreaterThanOrEqual(
            worstReported?.ratio ?? 0,
            4.5,
            "reported worst case: \(String(describing: worstReported))"
        )
    }

    func testHueClassificationIsStableAcrossYellowAndCyanQuantizationBoundaries() {
        let yellowSamples = [
            PostcardPixelSample(luminance: 0.7, red: 0.800, green: 0.799, blue: 0.200),
            PostcardPixelSample(luminance: 0.7, red: 0.799, green: 0.800, blue: 0.200),
            PostcardPixelSample(luminance: 0.7, red: 204.0 / 255.0, green: 203.0 / 255.0, blue: 51.0 / 255.0),
            PostcardPixelSample(luminance: 0.7, red: 203.0 / 255.0, green: 204.0 / 255.0, blue: 51.0 / 255.0),
        ]
        let cyanSamples = [
            PostcardPixelSample(luminance: 0.6, red: 0.200, green: 0.800, blue: 0.799),
            PostcardPixelSample(luminance: 0.6, red: 0.200, green: 0.799, blue: 0.800),
            PostcardPixelSample(luminance: 0.6, red: 51.0 / 255.0, green: 204.0 / 255.0, blue: 203.0 / 255.0),
            PostcardPixelSample(luminance: 0.6, red: 51.0 / 255.0, green: 203.0 / 255.0, blue: 204.0 / 255.0),
        ]

        XCTAssertTrue(yellowSamples.allSatisfy { resolveWithSamples($0).sceneFamily == .warmEarth })
        XCTAssertTrue(cyanSamples.allSatisfy { resolveWithSamples($0).sceneFamily == .lakeBlue })
    }

    func testCleanBackgroundHasNoObviousRectangularWash() {
        let style = resolve(
            .init(luminance: 0.76, red: 0.68, green: 0.76, blue: 0.84),
            range: 0.72...0.80,
            variance: 0.002
        )

        XCTAssertLessThanOrEqual(style.washOpacity, 0.08)
        XCTAssertLessThanOrEqual(style.shadowOpacity, 0.18)
    }

    func testCleanMidDarkBackgroundUsesRestrainedWashForEverySceneFamily() {
        let samples: [(PostcardPixelSample, PostcardSceneInkFamily)] = [
            (.init(luminance: 0.25, red: 0.12, green: 0.40, blue: 0.72), .lakeBlue),
            (.init(luminance: 0.25, red: 0.76, green: 0.28, blue: 0.10), .warmEarth),
            (.init(luminance: 0.25, red: 0.12, green: 0.58, blue: 0.22), .forestGreen),
            (.init(luminance: 0.25, red: 0.30, green: 0.31, blue: 0.32), .neutral),
        ]

        for (sample, family) in samples {
            let style = resolve(sample, range: 0.25...0.25, variance: 0.002)

            XCTAssertEqual(style.sceneFamily, family)
            XCTAssertLessThanOrEqual(style.washOpacity, 0.08, "family \(family)")
            assertContrast(style, against: 0.25...0.25)
        }
    }

    func testUnknownAnalysisKeepsGuaranteedNeutralFallback() {
        let style = PostcardInkResolver.resolve(
            sample: .init(luminance: .nan, red: .nan, green: .infinity, blue: -.infinity),
            backgroundSamples: [],
            colorVariance: .nan,
            isUnknown: true
        )

        XCTAssertEqual(style.sceneFamily, .neutral)
        XCTAssertEqual(style.foreground, .init(red: 1, green: 1, blue: 1))
        XCTAssertEqual(style.wash, .init(red: 0, green: 0, blue: 0))
        XCTAssertEqual(style.washOpacity, 0.82, accuracy: 0.000_001)
        assertContrast(style, against: 0...1)
    }

    func testInputsAreClampedAndResolutionIsDeterministic() {
        let sample = PostcardPixelSample(luminance: .nan, red: -10, green: .infinity, blue: 9)
        let first = PostcardInkResolver.resolve(
            sample: sample,
            backgroundSamples: [sample],
            colorVariance: .infinity,
            isUnknown: false
        )
        let second = PostcardInkResolver.resolve(
            sample: sample,
            backgroundSamples: [sample],
            colorVariance: .infinity,
            isUnknown: false
        )

        XCTAssertEqual(first, second)
        for component in [first.foreground.red, first.foreground.green, first.foreground.blue,
                          first.wash.red, first.wash.green, first.wash.blue] {
            XCTAssertTrue(component.isFinite)
            XCTAssertTrue((0...1).contains(component))
        }
        XCTAssertTrue((0...0.82).contains(first.washOpacity))
    }

    func testLocationInkUsesProfileOpacityAndSemanticForegroundShadow() throws {
        let background = PostcardPixelSample(luminance: 0.92, red: 0.96, green: 0.94, blue: 0.90)
        let detail = try XCTUnwrap(PostcardLocationInkResolver.resolve(
            backgroundSamples: [background],
            profile: .detail
        ))
        let compact = try XCTUnwrap(PostcardLocationInkResolver.resolve(
            backgroundSamples: [background],
            profile: .compact
        ))

        XCTAssertEqual(detail.opacity, 0.78, accuracy: 0.000_001)
        XCTAssertEqual(compact.opacity, 0.74, accuracy: 0.000_001)
        XCTAssertNotEqual(detail.foreground, detail.shadow)
        XCTAssertGreaterThan(detail.shadowOpacity, 0)
        XCTAssertLessThanOrEqual(detail.shadowOpacity, 0.45)
    }

    func testLocationInkEightBitForegroundContrastOrDualToneEdgeFallback() throws {
        let readable = [
            PostcardPixelSample(luminance: 0.90, red: 0.95, green: 0.93, blue: 0.88),
            PostcardPixelSample(luminance: 0.84, red: 0.88, green: 0.86, blue: 0.82),
        ]
        let style = try XCTUnwrap(PostcardLocationInkResolver.resolve(
            backgroundSamples: readable,
            profile: .detail
        ))

        for background in readable {
            XCTAssertGreaterThanOrEqual(
                locationRendererQuantizedContrast(style: style, background: background),
                4.5
            )
        }

        let impossible = [
            PostcardPixelSample(luminance: 0, red: 0, green: 0, blue: 0),
            PostcardPixelSample(luminance: 1, red: 1, green: 1, blue: 1),
        ]
        let edgeFallback = try XCTUnwrap(PostcardLocationInkResolver.resolve(
            backgroundSamples: impossible,
            profile: .compact
        ))
        XCTAssertTrue(edgeFallback.usesContrastEdgeFallback)
        XCTAssertLessThan(edgeFallback.minimumContrastRatio, 4.5)
        XCTAssertGreaterThanOrEqual(edgeFallback.shadowOpacity, 0.55)
    }

    func testLocationInkPixelSampleEntryPointHonorsConservativeWitnesses() {
        let average = (128.0 / 255.0 + 1) / 2
        let mixed = PostcardPixelSample(
            luminance: PostcardTextContrast.relativeLuminance(
                red: average,
                green: average,
                blue: average
            ),
            red: average,
            green: average,
            blue: average,
            locationContrastWitnesses: PostcardLocationContrastWitnesses(backgroundSamples: [
                PostcardColorSample(red: 128.0 / 255.0, green: 128.0 / 255.0, blue: 128.0 / 255.0),
                PostcardColorSample(red: 1, green: 1, blue: 1),
            ])
        )

        let style = PostcardLocationInkResolver.resolve(
            backgroundSamples: [mixed],
            profile: .compact
        )
        XCTAssertEqual(style?.usesContrastEdgeFallback, true)
    }

    func testLocationEdgeFallbackDistinguishesNaturalHighChromaFromFullySaturatedHazard() {
        let black = PostcardColorSample(red: 0, green: 0, blue: 0)
        let white = PostcardColorSample(red: 1, green: 1, blue: 1)
        let naturalHighChroma = PostcardColorSample(red: 252.0 / 255.0, green: 0, blue: 0)
        let fullySaturatedRed = PostcardColorSample(red: 1, green: 0, blue: 0)
        let nearSaturatedMagenta = PostcardColorSample(
            red: 248.0 / 255.0,
            green: 0,
            blue: 216.0 / 255.0
        )
        let nearSaturatedPink = PostcardColorSample(
            red: 252.0 / 255.0,
            green: 0,
            blue: 144.0 / 255.0
        )

        for profile in [PostcardOverlayProfile.compact, .detail] {
            XCTAssertNotNil(PostcardLocationInkResolver.resolve(
                backgroundSamples: [black, white, naturalHighChroma],
                profile: profile
            ))
            XCTAssertNil(PostcardLocationInkResolver.resolve(
                backgroundSamples: [black, white, fullySaturatedRed],
                profile: profile
            ))
            XCTAssertNil(PostcardLocationInkResolver.resolve(
                backgroundSamples: [black, white, nearSaturatedMagenta],
                profile: profile
            ))
            XCTAssertNil(PostcardLocationInkResolver.resolve(
                backgroundSamples: [black, white, nearSaturatedPink],
                profile: profile
            ))
        }
    }

    func testSolverResolvesInkForNormalEmptyInvalidAndUnknownPaths() {
        let scene = PostcardSampleGrid.uniform(luminance: 0.72, red: 0.18, green: 0.50, blue: 0.82)
        let normal = PostcardOverlaySolver.solve(
            analysis: .init(salientRegions: [.init(rect: .init(x: 0.55, y: 0.3, width: 0.4, height: 0.6), weight: 1)], samples: scene),
            messageLength: 12,
            profile: .detail
        )
        let empty = PostcardOverlaySolver.solve(
            analysis: .init(salientRegions: [], samples: scene),
            messageLength: 12,
            profile: .detail
        )
        let invalid = PostcardOverlaySolver.solve(
            analysis: .init(salientRegions: [], samples: .init(columns: 2, rows: 2, values: [])),
            messageLength: 12,
            profile: .detail
        )
        let unknown = PostcardOverlaySolver.unknownFallback(messageLength: 12, profile: .detail)

        XCTAssertEqual(normal.inkStyle.sceneFamily, .lakeBlue)
        XCTAssertEqual(empty.inkStyle.sceneFamily, .lakeBlue)
        XCTAssertEqual(invalid.inkStyle, unknown.inkStyle)
        XCTAssertEqual(unknown.inkStyle.sceneFamily, .neutral)
    }

    func testLayoutCompatibilityAccessorsAlwaysProjectSemanticInk() {
        let analyses = [
            PostcardVisualAnalysis(
                salientRegions: [],
                samples: .uniform(luminance: 0.25, red: 0.12, green: 0.40, blue: 0.72)
            ),
            PostcardVisualAnalysis(
                salientRegions: [.init(rect: .init(x: 0.55, y: 0.3, width: 0.4, height: 0.6), weight: 1)],
                samples: .uniform(luminance: 0.75, red: 0.76, green: 0.28, blue: 0.10)
            ),
        ]
        let layouts = analyses.map {
            PostcardOverlaySolver.solve(analysis: $0, messageLength: 12, profile: .detail)
        } + [PostcardOverlaySolver.unknownFallback(messageLength: 12, profile: .detail)]

        for layout in layouts {
            XCTAssertEqual(layout.usesLightText, layout.inkStyle.usesLightText)
            XCTAssertEqual(layout.washOpacity, layout.inkStyle.washOpacity, accuracy: 0.000_001)
        }
    }

    private func resolve(
        _ sample: PostcardPixelSample,
        range: ClosedRange<Double>,
        variance: Double = 0.01
    ) -> PostcardInkStyle {
        PostcardInkResolver.resolve(
            sample: sample,
            backgroundSamples: [
                grayscaleSample(relativeLuminance: range.lowerBound),
                grayscaleSample(relativeLuminance: range.upperBound),
            ],
            colorVariance: variance,
            isUnknown: false
        )
    }

    private func resolveWithSamples(_ sample: PostcardPixelSample) -> PostcardInkStyle {
        PostcardInkResolver.resolve(
            sample: sample,
            backgroundSamples: [sample],
            colorVariance: 0.002,
            isUnknown: false
        )
    }

    private func alphaComposite(
        background: PostcardPixelSample,
        wash: PostcardInkColor,
        opacity: Double
    ) -> PostcardInkColor {
        PostcardInkColor(
            red: background.red * (1 - opacity) + wash.red * opacity,
            green: background.green * (1 - opacity) + wash.green * opacity,
            blue: background.blue * (1 - opacity) + wash.blue * opacity
        )
    }

    private func rendererQuantizedContrast(
        style: PostcardInkStyle,
        background: PostcardPixelSample
    ) -> Double {
        let foreground = PostcardInkColor(
            red: quantizeRound(style.foreground.red),
            green: quantizeRound(style.foreground.green),
            blue: quantizeRound(style.foreground.blue)
        )
        let composited = alphaComposite(
            background: background,
            wash: style.wash,
            opacity: style.washOpacity
        )
        let rendered = PostcardInkColor(
            red: quantizeRound(composited.red),
            green: quantizeRound(composited.green),
            blue: quantizeRound(composited.blue)
        )
        return PostcardTextContrast.contrastRatio(
            foregroundLuminance: foreground.relativeLuminance,
            backgroundLuminance: rendered.relativeLuminance
        )
    }

    private func locationRendererQuantizedContrast(
        style: PostcardLocationInkStyle,
        background: PostcardPixelSample
    ) -> Double {
        let renderedForeground = PostcardInkColor(
            red: quantizeRound(style.foreground.red * style.opacity + background.red * (1 - style.opacity)),
            green: quantizeRound(style.foreground.green * style.opacity + background.green * (1 - style.opacity)),
            blue: quantizeRound(style.foreground.blue * style.opacity + background.blue * (1 - style.opacity))
        )
        let renderedBackground = PostcardInkColor(
            red: quantizeRound(background.red),
            green: quantizeRound(background.green),
            blue: quantizeRound(background.blue)
        )
        return PostcardTextContrast.contrastRatio(
            foregroundLuminance: renderedForeground.relativeLuminance,
            backgroundLuminance: renderedBackground.relativeLuminance
        )
    }

    private func conservativeQuantizedContrast(
        style: PostcardInkStyle,
        background: PostcardPixelSample
    ) -> Double {
        let foregrounds = quantizedVariants(style.foreground)
        let composited = alphaComposite(
            background: background,
            wash: style.wash,
            opacity: style.washOpacity
        )
        let backgrounds = quantizedVariants(composited)
        return foregrounds.flatMap { foreground in
            backgrounds.map { rendered in
                PostcardTextContrast.contrastRatio(
                    foregroundLuminance: foreground.relativeLuminance,
                    backgroundLuminance: rendered.relativeLuminance
                )
            }
        }.min() ?? 0
    }

    private func quantizedVariants(_ color: PostcardInkColor) -> [PostcardInkColor] {
        let reds = quantizationBounds(color.red)
        let greens = quantizationBounds(color.green)
        let blues = quantizationBounds(color.blue)
        return reds.flatMap { red in
            greens.flatMap { green in
                blues.map { blue in PostcardInkColor(red: red, green: green, blue: blue) }
            }
        }
    }

    private func quantizationBounds(_ component: Double) -> [Double] {
        let scaled = component * 255
        return [floor(scaled) / 255, ceil(scaled) / 255]
    }

    private func quantizeRound(_ component: Double) -> Double {
        (component * 255).rounded() / 255
    }

    private func assertContrast(
        _ style: PostcardInkStyle,
        against range: ClosedRange<Double>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for endpoint in [range.lowerBound, range.upperBound] {
            let background = grayscaleSample(relativeLuminance: endpoint)
            let effective = alphaComposite(
                background: background,
                wash: style.wash,
                opacity: style.washOpacity
            )
            XCTAssertGreaterThanOrEqual(
                PostcardTextContrast.contrastRatio(
                    foregroundLuminance: style.foreground.relativeLuminance,
                    backgroundLuminance: effective.relativeLuminance
                ),
                4.5 - 0.000_001,
                file: file,
                line: line
            )
        }
    }

    private func saturation(_ color: PostcardInkColor) -> Double {
        let maximum = max(color.red, color.green, color.blue)
        let minimum = min(color.red, color.green, color.blue)
        return maximum == 0 ? 0 : (maximum - minimum) / maximum
    }

    private func grayscaleSample(relativeLuminance: Double) -> PostcardPixelSample {
        let luminance = min(max(relativeLuminance.isFinite ? relativeLuminance : 0, 0), 1)
        let component = luminance <= 0.003_130_8
            ? luminance * 12.92
            : 1.055 * pow(luminance, 1 / 2.4) - 0.055
        return PostcardPixelSample(
            luminance: luminance,
            red: component,
            green: component,
            blue: component
        )
    }
}
