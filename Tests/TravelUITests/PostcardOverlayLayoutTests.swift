import AppKit
import CoreGraphics
import SwiftUI
import XCTest
import TravelCore
@testable import TravelUI

final class PostcardOverlayLayoutTests: XCTestCase {
    func testProtectingAddsMaximumWeightRegionWithoutChangingSamples() {
        let original = PostcardVisualAnalysis(
            salientRegions: [],
            samples: .uniform(luminance: 0.7, red: 0.7, green: 0.7, blue: 0.7)
        )
        let catRect = CGRect(x: 0.08, y: 0.58, width: 0.18, height: 0.30)

        let protected = original.protecting(catRect)

        XCTAssertEqual(
            protected.salientRegions.last,
            PostcardSalientRegion(rect: catRect, weight: 1)
        )
        XCTAssertEqual(protected.samples, original.samples)
    }

    func testAllPreviewLayoutsKeepLocationMessageAndPawClearOfTheCat() {
        for (profile, size) in [
            (PostcardOverlayProfile.detail, CGSize(width: 360, height: 230)),
            (.compact, CGSize(width: 218, height: 120)),
        ] {
            for definition in TravelAlbumPreviewCatalog.definitions {
                let catFrame = definition.catPlacement.frame(
                    in: size,
                    sourceAspectRatio: PreviewBlackCatPlacement.authorizedSourceAspectRatio
                )
                let catRect = normalized(catFrame, in: size)
                let analysis = PostcardVisualAnalysis(
                    salientRegions: [
                        PostcardSalientRegion(
                            rect: CGRect(x: 0.36, y: 0.16, width: 0.28, height: 0.36),
                            weight: 0.78
                        ),
                    ],
                    samples: .uniform(luminance: 0.72, red: 0.68, green: 0.71, blue: 0.74)
                ).protecting(catRect)
                let event = postcardEvent(location: definition.location, mood: definition.mood)
                let layout = PostcardArtworkLayoutResolver.resolve(
                    metadata: PostcardArtworkMetadata(event: event),
                    analysis: analysis,
                    profile: profile,
                    containerSize: size
                )
                let messageRect = PostcardOverlayGeometry.rect(
                    for: layout.messageRegion,
                    profile: profile
                )
                let pawRect = normalized(layout.pawSignature.placement.pawFrame, in: size)

                if layout.messagePlacement == .belowImage {
                    XCTAssertFalse(layout.showsLocationLabel)
                    XCTAssertEqual(layout.pawSignature.placement.mode, .omitted)
                    continue
                }
                XCTAssertTrue(layout.showsLocationLabel, "missing location: \(profile) \(definition.filename)")
                XCTAssertFalse(
                    layout.locationSafetyRect.intersects(catRect),
                    "location: \(profile) \(definition.filename)"
                )
                XCTAssertFalse(
                    messageRect.intersects(catRect),
                    "message: \(profile) \(definition.filename) region=\(layout.messageRegion) font=\(layout.messageFontSize) cat=\(catRect) message=\(messageRect)"
                )
                XCTAssertFalse(
                    pawRect.intersects(catRect),
                    "paw: \(profile) \(definition.filename)"
                )
            }
        }
    }

    func testActualPreviewScenesKeepLocationVisibleAndClearOfTheCat() throws {
        for (profile, size) in [
            (PostcardOverlayProfile.detail, CGSize(width: 520, height: 230)),
            (.compact, CGSize(width: 322, height: 120)),
        ] {
            for definition in TravelAlbumPreviewCatalog.definitions {
                let assetURL = try XCTUnwrap(
                    TravelAlbumPreviewCatalog.resourceURL(
                        for: definition,
                        in: TravelUIResources.bundle
                    )
                )
                let image = try PostcardImageDecoder.decodeThumbnail(
                    data: Data(contentsOf: assetURL)
                )
                let sceneAnalysis = try PostcardVisualAnalyzer.analyze(image)
                let displayed = PostcardAspectFillTransform(
                    imageSize: CGSize(width: image.width, height: image.height),
                    containerSize: size
                ).displayAnalysis(sceneAnalysis)
                let catFrame = definition.catPlacement.frame(
                    in: size,
                    sourceAspectRatio: PreviewBlackCatPlacement.authorizedSourceAspectRatio
                )
                let catRect = normalized(catFrame, in: size)
                let event = postcardEvent(location: definition.location, mood: definition.mood)
                let layout = PostcardArtworkLayoutResolver.resolve(
                    metadata: PostcardArtworkMetadata(event: event),
                    analysis: displayed.protecting(catRect),
                    profile: profile,
                    containerSize: size
                )
                let messageRect = PostcardOverlayGeometry.rect(
                    for: layout.messageRegion,
                    profile: profile
                )
                let pawRect = normalized(layout.pawSignature.placement.pawFrame, in: size)

                XCTAssertTrue(
                    layout.showsLocationLabel,
                    "missing location: \(profile) \(definition.filename)"
                )
                XCTAssertFalse(
                    layout.locationSafetyRect.intersects(catRect),
                    "location overlaps cat: \(profile) \(definition.filename)"
                )
                XCTAssertFalse(
                    messageRect.intersects(catRect),
                    "message overlaps cat: \(profile) \(definition.filename)"
                )
                XCTAssertFalse(
                    pawRect.intersects(catRect),
                    "paw overlaps cat: \(profile) \(definition.filename)"
                )
            }
        }
    }

    func testRenderedTypographyIsTheSameCoreTextFaceSizeAndLineGeometryUsedBySolver() {
        let styles = [
            PostcardHandwritingStyle(
                family: .playful,
                fontPostScriptName: "Helvetica-Bold",
                fontWeight: 0.4,
                sizeScale: 1.06,
                lineSpacing: 1.12,
                pawOpacity: 0.68
            ),
            PostcardHandwritingStyle(
                family: .reflective,
                fontPostScriptName: "missing-postscript-face",
                fontWeight: -0.10,
                sizeScale: 0.95,
                lineSpacing: 1.24,
                pawOpacity: 0.56
            ),
            .sereneSystemFallback,
        ]
        let messages = [
            "沿着河岸走了很久，风把云推到了远山后面。",
            "Long roads, small paws,\nand one quiet sunset.",
            "沿着河岸走了很久，\n风把云推到了远山后面。",
        ]

        for (style, message) in zip(styles, messages) {
            let layout = PostcardOverlaySolver.unknownFallback(
                message: message,
                profile: .detail,
                containerSize: CGSize(width: 520, height: 230),
                handwriting: style
            )
            let measured = PostcardOverlayTypography.measurementFont(
                fontSize: layout.messageFontSize,
                handwriting: style
            )!

            XCTAssertEqual(layout.handwritingStyle, style)
            XCTAssertEqual(layout.messageFont.fontName, measured.fontName)
            XCTAssertEqual(layout.messageFont.pointSize, measured.pointSize)
            XCTAssertEqual(layout.messageFont.fontDescriptor, measured.fontDescriptor)
            XCTAssertEqual(
                layout.messageLineHeight,
                layout.messageFontSize * CGFloat(style.lineSpacing),
                accuracy: 0.001
            )
            XCTAssertEqual(
                layout.messageFont.ascender - layout.messageFont.descender
                    + layout.messageFont.leading + layout.messageLineSpacing,
                layout.messageLineHeight,
                accuracy: 0.001
            )
            XCTAssertTrue(layout.pawSignature.placement.messageFits)
            XCTAssertEqual(
                layout.pawSignature.placement.textBlockFrame.height,
                CGFloat(layout.pawSignature.placement.measuredLineCount) * layout.messageLineHeight,
                accuracy: 0.001
            )
            if message.contains("\n") {
                XCTAssertGreaterThanOrEqual(layout.pawSignature.placement.measuredLineCount, 2)
            }
        }
    }
    func testSolverStoresSemanticPawPlacementWithoutCoveringLocation() {
        let size = CGSize(width: 520, height: 230)
        let analysis = PostcardVisualAnalysis(
            salientRegions: [.init(rect: CGRect(x: 0.45, y: 0.35, width: 0.2, height: 0.2), weight: 0.8)],
            samples: .uniform(luminance: 0.78, red: 0.32, green: 0.62, blue: 0.82)
        )
        let layout = PostcardOverlaySolver.solve(
            analysis: analysis,
            message: "风很轻。",
            profile: .detail,
            containerSize: size
        )
        let locationFrame = PostcardOverlayPresentation.frame(
            for: layout.locationRegion,
            profile: .detail,
            containerSize: size
        )

        XCTAssertNotEqual(layout.pawSignature.placement.mode, .omitted)
        XCTAssertTrue(layout.pawSignature.placement.messageFits)
        XCTAssertFalse(layout.pawSignature.placement.pawFrame.intersects(locationFrame))
        XCTAssertEqual(layout.pawSignature.style.color, layout.inkStyle.foreground)
        XCTAssertEqual(layout.pawSignature.style.opacity, layout.inkStyle.pawOpacity)
    }

    func testSolverRightRegionUsesRenderedLeadingInlinePawAfterText() {
        let size = CGSize(width: 520, height: 500)
        let analysis = PostcardVisualAnalysis(
            salientRegions: [.init(rect: CGRect(x: 0, y: 0, width: 0.58, height: 1), weight: 1)],
            samples: .uniform(luminance: 0.82, red: 0.74, green: 0.78, blue: 0.84)
        )
        let layout = PostcardOverlaySolver.solve(
            analysis: analysis,
            message: "风很轻。",
            profile: .detail,
            containerSize: size
        )
        let messageFrame = PostcardOverlayPresentation.frame(
            for: layout.messageRegion,
            profile: .detail,
            containerSize: size
        ).insetBy(dx: 10, dy: 10)

        XCTAssertTrue([.middleTrailing, .bottomTrailing, .wideMiddleTrailing, .wideBottomTrailing]
            .contains(layout.messageRegion))
        XCTAssertEqual(layout.pawSignature.placement.mode, .inline)
        XCTAssertGreaterThan(
            layout.pawSignature.placement.pawFrame.minX,
            layout.pawSignature.placement.textFrame.maxX
        )
        XCTAssertTrue(messageFrame.contains(layout.pawSignature.placement.pawFrame))
    }

    func testLegalMaximumFallbackKeepsFullTextFitWhenPawCannotFit() {
        let size = CGSize(width: 676, height: 120)
        let message = String(repeating: "旅", count: 80)
        let layout = PostcardOverlaySolver.unknownFallback(
            message: message,
            profile: .compact,
            containerSize: size
        )

        XCTAssertTrue(layout.pawSignature.placement.messageFits)
        XCTAssertLessThanOrEqual(layout.pawSignature.placement.measuredLineCount, 2)
        XCTAssertFalse(layout.pawSignature.placement.mode == .signatureLine)
        XCTAssertGreaterThanOrEqual(layout.messageFontSize, 12)
    }

    func testVisualMessagePreservesCompleteQuotesAfterWhitespaceNormalization() {
        for count in [0, 1, 31, 32, 33, 80] {
            let quote = String(repeating: "旅", count: count)
            XCTAssertEqual(PostcardVisualMessage.resolve(quote), quote)
        }
        let explicitLines = String(repeating: "旅", count: 15)
            + "\n" + String(repeating: "途", count: 16)
        XCTAssertEqual(
            PostcardVisualMessage.resolve(explicitLines),
            String(repeating: "旅", count: 15) + " " + String(repeating: "途", count: 16)
        )
    }

    func testVisualMessageNormalizesUnicodeNewlinesAndWhitespaceWithoutTruncation() {
        XCTAssertEqual(
            PostcardVisualMessage.resolve("旅旅\n途途\n猫猫"),
            "旅旅 途途 猫猫"
        )
        XCTAssertEqual(
            PostcardVisualMessage.resolve("  \t旅\u{00A0}\u{2003}途\r\n\r猫\u{000B}\u{000C}梦\u{0085}\u{2028}\u{2029} 路  "),
            "旅 途 猫 梦 路"
        )
        XCTAssertEqual(
            PostcardVisualMessage.resolve("旅\u{200B}途\u{FEFF}猫"),
            "旅\u{200B}途\u{FEFF}猫"
        )

        let normalized32 = String(repeating: "旅", count: 30) + "\t \r\n" + "途"
        XCTAssertEqual(
            PostcardVisualMessage.resolve(normalized32),
            String(repeating: "旅", count: 30) + " 途"
        )
        XCTAssertEqual(PostcardVisualMessage.resolve(normalized32).unicodeScalars.count, 32)

        let normalized33 = String(repeating: "旅", count: 31) + "\n\t" + "途"
        XCTAssertEqual(
            PostcardVisualMessage.resolve(normalized33),
            String(repeating: "旅", count: 31) + " 途"
        )
    }

    func testVisualMessagePreservesEmojiAndCombiningMarksDeterministically() {
        let quote = String(repeating: "🐈‍⬛e\u{301}", count: 7)
        XCTAssertGreaterThan(quote.unicodeScalars.count, 32)
        let first = PostcardVisualMessage.resolve(quote)
        let second = PostcardVisualMessage.resolve(quote)
        XCTAssertEqual(first, quote)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.unicodeScalars.count, quote.unicodeScalars.count)
    }

    func testPromotedBundledFacesKeepCompleteVisualMessageOrUseCaptionFallback() {
        let cases: [(Mood, String)] = [
            (Mood(level: 0, label: "平静", quote: ""), "LXGWWenKaiLite-Medium"),
            (Mood(level: 1, label: "好奇", quote: ""), "LXGWWenKaiLite-Medium"),
            (Mood(level: -1, label: "思念", quote: ""), "LXGWWenKaiLite-Regular"),
            (Mood(level: 2, label: "坚定", quote: ""), "LXGWWenKaiLite-Medium"),
        ]
        let quotes = [
            String(repeating: "旅", count: 80),
            String(repeating: "旅", count: 15) + "\n" + String(repeating: "途", count: 16),
        ]
        let profiles: [(PostcardOverlayProfile, CGSize, CGFloat)] = [
            (.detail, CGSize(width: 520, height: 230), 17),
            (.compact, CGSize(width: 322, height: 120), 12),
        ]
        let analysis = PostcardVisualAnalysis(
            salientRegions: [],
            samples: .uniform(luminance: 0.72, red: 0.20, green: 0.54, blue: 0.82)
        )

        for (baseMood, expectedFace) in cases {
            for quote in quotes {
                let mood = Mood(level: baseMood.level, label: baseMood.label, quote: quote)
                let metadata = PostcardArtworkMetadata(event: postcardEvent(location: nil, mood: mood))
                for (profile, size, minimumSize) in profiles {
                    let layout = PostcardArtworkLayoutResolver.resolve(
                        metadata: metadata,
                        analysis: analysis,
                        profile: profile,
                        containerSize: size
                    )
                    XCTAssertEqual(metadata.fullMessage, quote)
                    XCTAssertEqual(
                        metadata.visualMessage,
                        PostcardVisualMessage.resolve(quote)
                    )
                    XCTAssertFalse(metadata.visualMessage.contains("\n"))
                    XCTAssertFalse(metadata.visualMessage.contains("\r"))
                    XCTAssertEqual(layout.messageFont.fontName, expectedFace)
                    XCTAssertEqual(layout.messagePlacement, .belowImage)
                    XCTAssertEqual(layout.fallbackReason, .noReliableForeground)
                    XCTAssertGreaterThanOrEqual(layout.messageFontSize, minimumSize, "\(baseMood.label) \(profile)")
                    XCTAssertEqual(layout.pawSignature.placement.mode, .omitted)
                }
            }
        }
    }

    func testSolverPrefersWideRegionWhenRegularCanOnlyUseSignatureButWideCanStayInline() {
        let size = CGSize(width: 520, height: 230)
        let analysis = PostcardVisualAnalysis(
            salientRegions: [.init(rect: CGRect(x: 0.80, y: 0.02, width: 0.12, height: 0.12), weight: 0.7)],
            samples: .uniform(luminance: 0.76, red: 0.28, green: 0.58, blue: 0.82)
        )
        let message = "WWWWWWW"
        let layout = PostcardOverlaySolver.solve(
            analysis: analysis,
            message: message,
            profile: .detail,
            containerSize: size
        )

        XCTAssertTrue(
            [.wideMiddleLeading, .wideBottomLeading, .wideMiddleTrailing, .wideBottomTrailing].contains(layout.messageRegion),
            "region=\(layout.messageRegion) paw=\(layout.pawSignature.placement.mode) size=\(layout.messageFontSize)"
        )
        XCTAssertEqual(layout.pawSignature.placement.mode, .inline)
        XCTAssertTrue(layout.pawSignature.placement.messageFits)
    }

    func testSafeWideRegionBeatsUnsafeRegularAndKeepsPawClearOfText() {
        let size = CGSize(width: 520, height: 230)
        let protected = [
            PostcardSalientRegion(rect: CGRect(x: 0.05, y: 0.40, width: 0.055, height: 0.29), weight: 1),
            PostcardSalientRegion(rect: CGRect(x: 0.53, y: 0.40, width: 0.055, height: 0.29), weight: 1),
            PostcardSalientRegion(rect: CGRect(x: 0.05, y: 0.66, width: 0.055, height: 0.29), weight: 1),
            PostcardSalientRegion(rect: CGRect(x: 0.53, y: 0.66, width: 0.055, height: 0.29), weight: 1),
        ]
        let analysis = PostcardVisualAnalysis(
            salientRegions: protected,
            samples: .uniform(luminance: 0.72, red: 0.25, green: 0.58, blue: 0.80)
        )
        let layout = PostcardOverlaySolver.solve(
            analysis: analysis,
            message: "WWWWWW",
            profile: .detail,
            containerSize: size
        )
        let messageRect = PostcardOverlayGeometry.rect(for: layout.messageRegion, profile: .detail)

        XCTAssertTrue(
            [.wideMiddleLeading, .wideMiddleTrailing, .wideBottomLeading, .wideBottomTrailing]
                .contains(layout.messageRegion)
        )
        XCTAssertNotEqual(layout.pawSignature.placement.mode, .omitted)
        XCTAssertFalse(layout.pawSignature.placement.pawFrame.intersects(layout.pawSignature.placement.textFrame))
        for region in protected {
            let overlap = messageRect.intersection(region.rect)
            XCTAssertLessThan(
                overlap.isNull ? 0 : overlap.width * overlap.height / (messageRect.width * messageRect.height),
                0.12
            )
        }
    }

    func testSolverProtectsActualEnlargedPawFrameAndFallsBackInsideCanvas() {
        let size = CGSize(width: 520, height: 230)
        let message = "看海。"
        let leadingRegions: [PostcardOverlayRegion] = [
            .scenicTopLeading,
            .middleLeading,
            .bottomLeading,
            .wideMiddleLeading,
            .wideBottomLeading,
        ]
        let pawFringes = leadingRegions.compactMap { region -> PostcardSalientRegion? in
            let fit = PostcardOverlayTypography.fit(
                message: message,
                region: region,
                profile: .detail,
                containerSize: size,
                handwriting: .sereneSystemFallback
            )
            let messageFrame = PostcardOverlayPresentation.frame(
                for: region,
                profile: .detail,
                containerSize: size
            ).insetBy(dx: 10, dy: 10)
            let placement = PostcardPawLayout.resolve(
                message: message,
                messageFrame: messageFrame,
                fontSize: fit.fontSize,
                typography: .sereneSystemFallback,
                profile: .detail
            )
            guard placement.mode == .inline else { return nil }
            let previousNominal = min(max(fit.fontSize * 0.78, 10), 20)
            let fringe = CGRect(
                x: (placement.pawFrame.minX + previousNominal + 0.001) / size.width,
                y: placement.pawFrame.minY / size.height,
                width: max(placement.pawFrame.width - previousNominal - 0.001, 0) / size.width,
                height: placement.pawFrame.height / size.height
            )
            return PostcardSalientRegion(rect: fringe, weight: 1)
        }
        let analysis = PostcardVisualAnalysis(
            salientRegions: pawFringes + [
                .init(rect: CGRect(x: 0.58, y: 0, width: 0.42, height: 1), weight: 1),
            ],
            samples: .uniform(luminance: 0.76, red: 0.24, green: 0.56, blue: 0.80)
        )
        let layout = PostcardOverlaySolver.solve(
            analysis: analysis,
            message: message,
            profile: .detail,
            containerSize: size
        )
        let paw = layout.pawSignature.placement.pawFrame
        let canvas = PostcardOverlayPresentation.canvasFrame(containerSize: size)
        let protectedFrames = analysis.salientRegions.map {
            CGRect(
                x: $0.rect.minX * size.width,
                y: $0.rect.minY * size.height,
                width: $0.rect.width * size.width,
                height: $0.rect.height * size.height
            )
        }
        let location = CGRect(
            x: layout.locationSafetyRect.minX * size.width,
            y: layout.locationSafetyRect.minY * size.height,
            width: layout.locationSafetyRect.width * size.width,
            height: layout.locationSafetyRect.height * size.height
        )

        XCTAssertEqual(pawFringes.count, leadingRegions.count)
        XCTAssertNotEqual(layout.pawSignature.placement.mode, .omitted)
        XCTAssertTrue(canvas.contains(paw))
        XCTAssertFalse(paw.intersects(layout.pawSignature.placement.textFrame))
        XCTAssertFalse(layout.showsLocationLabel && paw.intersects(location))
        XCTAssertTrue(protectedFrames.allSatisfy { !paw.intersects($0) })
    }

    func testLongMessageFallbacksChooseWideReadableRegionAtProductionCompactSize() {
        let message = String(repeating: "旅", count: 80)
        let size = CGSize(width: 676, height: 120)
        let invalid = PostcardVisualAnalysis(
            salientRegions: [.init(rect: .zero, weight: 1)],
            samples: PostcardSampleGrid(columns: 2, rows: 2, values: [])
        )
        let empty = PostcardVisualAnalysis(
            salientRegions: [],
            samples: .uniform(luminance: 0.4, red: 0.4, green: 0.4, blue: 0.4)
        )
        let layouts = [
            PostcardOverlaySolver.unknownFallback(message: message, profile: .compact, containerSize: size),
            PostcardOverlaySolver.fallback(message: message, profile: .compact, containerSize: size),
            PostcardOverlaySolver.solve(analysis: invalid, message: message, profile: .compact, containerSize: size),
            PostcardOverlaySolver.solve(analysis: empty, message: message, profile: .compact, containerSize: size),
        ]

        for layout in layouts {
            XCTAssertTrue([.wideBottomLeading, .wideBottomTrailing].contains(layout.messageRegion))
            let fit = PostcardOverlayTypography.fit(
                message: message,
                region: layout.messageRegion,
                profile: .compact,
                containerSize: size
            )
            XCTAssertTrue(fit.fitsVertically)
            XCTAssertLessThanOrEqual(fit.requiredLineCount, 2)
            XCTAssertGreaterThanOrEqual(layout.messageFontSize, 12)
        }
    }

    func testMessageLengthFallbackAPIStillUsesCompatibleConservativeText() {
        let layout = PostcardOverlaySolver.unknownFallback(
            messageLength: 80,
            profile: .compact,
            containerSize: CGSize(width: 676, height: 120)
        )
        XCTAssertTrue([.wideBottomLeading, .wideBottomTrailing].contains(layout.messageRegion))
    }

    func testCoreTextTypographyMeasuresActualMessagesAndExplicitLineBreaks() {
        let serene = PostcardMoodTypographyResolver().resolve(
            mood: Mood(level: 0, label: "平静", quote: "慢慢走。")
        )
        let traits = PostcardOverlayTypography.measurementFontTraits(
            fontSize: 12,
            handwriting: serene
        )
        XCTAssertFalse(traits.contains(.italic))

        let ordinary = PostcardOverlayTypography.fit(
            message: "湖光和晨风一起把旧码头点亮了。",
            region: .middleTrailing,
            profile: .compact,
            containerSize: CGSize(width: 322, height: 120)
        )
        XCTAssertLessThanOrEqual(ordinary.requiredLineCount, 2)
        XCTAssertTrue(ordinary.fitsVertically)
        XCTAssertGreaterThanOrEqual(ordinary.fontSize, 12)

        let explicitLines = PostcardOverlayTypography.fit(
            message: "第一行\n第二行",
            region: .middleTrailing,
            profile: .compact,
            containerSize: CGSize(width: 322, height: 120)
        )
        XCTAssertEqual(explicitLines.requiredLineCount, 2)

        let legalMaximum = PostcardOverlayTypography.fit(
            message: String(repeating: "旅", count: 80),
            region: .wideBottomTrailing,
            profile: .compact,
            containerSize: CGSize(width: 676, height: 120)
        )
        XCTAssertLessThanOrEqual(legalMaximum.requiredLineCount, 2)
        XCTAssertTrue(legalMaximum.fitsVertically)
        XCTAssertGreaterThanOrEqual(legalMaximum.fontSize, 12)
    }

    func testLocationTypographyMeasuresActualLabelWithRenderedFont() {
        let traits = PostcardOverlayTypography.locationMeasurementFontTraits(
            fontSize: 11
        )
        XCTAssertFalse(traits.contains(.bold))

        let fit = PostcardOverlayTypography.locationFit(
            label: "Japan · Hatsukaichi · Itsukushima Shrine O-Torii",
            region: .topTrailing,
            profile: .compact,
            containerSize: CGSize(width: 322, height: 120)
        )

        XCTAssertLessThanOrEqual(fit.requiredLineCount, 2)
        XCTAssertTrue(fit.fitsVertically)
        XCTAssertGreaterThanOrEqual(fit.minimumScaleFactor * 11, 9)
    }

    @MainActor
    func testRenderedShortChineseLocationLabelsFitTheirFinalProductionFrames() {
        for (profile, size) in [
            (PostcardOverlayProfile.detail, CGSize(width: 520, height: 230)),
            (.compact, CGSize(width: 322, height: 120)),
        ] {
            for label in ["大津港旧栈桥", "宫岛大鸟居", "上高地河童桥"] {
                let content = PostcardLocationLabelContent(label: label, profile: profile)
                    .fixedSize(horizontal: true, vertical: true)
                let hostingView = NSHostingView(rootView: content)
                let idealSize = hostingView.fittingSize
                let finalFrame = PostcardOverlayTypography.locationRect(
                    label: label,
                    region: .topTrailing,
                    profile: profile,
                    containerSize: size
                )
                let finalWidth = finalFrame.width * size.width
                let finalHeight = finalFrame.height * size.height

                XCTAssertGreaterThanOrEqual(finalWidth, ceil(idealSize.width), "\(profile): \(label)")
                XCTAssertGreaterThanOrEqual(finalHeight, ceil(idealSize.height), "\(profile): \(label)")
            }
        }
    }

    func testLocationUsesOnlyRealCornerRegions() {
        XCTAssertEqual(
            Set(PostcardOverlayLayout.locationRegions),
            Set([
                PostcardOverlayRegion.topLeading,
                .topTrailing,
                .locationBottomLeading,
                .locationBottomTrailing,
            ])
        )
    }

    func testAllProtectedCornersOmitLocationLabel() {
        let analysis = PostcardVisualAnalysis(
            salientRegions: PostcardOverlayLayout.locationRegions.map {
                PostcardSalientRegion(
                    rect: PostcardOverlayGeometry.rect(for: $0, profile: .detail),
                    weight: 1
                )
            },
            samples: .uniform(luminance: 0.92, red: 0.96, green: 0.94, blue: 0.90)
        )

        let layout = PostcardOverlaySolver.solve(
            analysis: analysis,
            locationLabel: "宫岛大鸟居",
            message: "风把海面吹亮了。",
            profile: .detail,
            containerSize: CGSize(width: 520, height: 230)
        )

        XCTAssertFalse(layout.showsLocationLabel)
        XCTAssertEqual(layout.locationRect, .zero)
        XCTAssertNil(layout.locationInkStyle)
    }

    func testKnownUniformSceneShowsReadableLocationInCornerClearOfMessage() {
        let analysis = PostcardVisualAnalysis(
            salientRegions: [
                .init(rect: CGRect(x: 0.42, y: 0.34, width: 0.16, height: 0.18), weight: 0.9),
            ],
            samples: .uniform(luminance: 0.92, red: 0.96, green: 0.94, blue: 0.90)
        )

        let layout = PostcardOverlaySolver.solve(
            analysis: analysis,
            locationLabel: "宫岛大鸟居",
            message: "风把海面吹亮了。",
            profile: .detail,
            containerSize: CGSize(width: 520, height: 230)
        )
        let messageRect = PostcardOverlayGeometry.rect(for: layout.messageRegion, profile: .detail)

        XCTAssertTrue(layout.showsLocationLabel)
        XCTAssertTrue(PostcardOverlayLayout.locationRegions.contains(layout.locationRegion))
        XCTAssertFalse(layout.locationRect.intersects(messageRect))
        XCTAssertNotNil(layout.locationInkStyle)
        XCTAssertLessThan(
            layout.locationRect.width * layout.locationRect.height,
            PostcardOverlayGeometry.rect(for: layout.locationRegion, profile: .detail).width
                * PostcardOverlayGeometry.rect(for: layout.locationRegion, profile: .detail).height
        )
    }

    func testMixedCellWitnessesUseBackgroundFreeDualToneLocationEdge() {
        let gray = PostcardColorSample(red: 128.0 / 255.0, green: 128.0 / 255.0, blue: 128.0 / 255.0)
        let white = PostcardColorSample(red: 1, green: 1, blue: 1)
        let average = (128.0 / 255.0 + 1) / 2
        let mixedCell = PostcardPixelSample(
            luminance: PostcardTextContrast.relativeLuminance(
                red: average,
                green: average,
                blue: average
            ),
            red: average,
            green: average,
            blue: average,
            locationContrastWitnesses: PostcardLocationContrastWitnesses(
                backgroundSamples: [gray, white]
            )
        )
        let analysis = PostcardVisualAnalysis(
            salientRegions: [
                .init(rect: CGRect(x: 0.44, y: 0.38, width: 0.12, height: 0.16), weight: 0.9),
            ],
            samples: .init(columns: 1, rows: 1, values: [mixedCell])
        )

        let layout = PostcardOverlaySolver.solve(
            analysis: analysis,
            locationLabel: "宫岛大鸟居",
            message: "风把海面吹亮了。",
            profile: .compact,
            containerSize: CGSize(width: 322, height: 120)
        )

        XCTAssertTrue(layout.showsLocationLabel)
        XCTAssertEqual(layout.locationInkStyle?.usesContrastEdgeFallback, true)
    }

    func testHueCounterexamplesOmitAfterBitmapAnalysisCropAndSolve() throws {
        let cases: [(profile: PostcardOverlayProfile, size: CGSize, colors: [[UInt8]])] = [
            (
                .compact,
                CGSize(width: 322, height: 120),
                [[248, 0, 216], [224, 96, 88], [255, 255, 255]]
            ),
            (
                .detail,
                CGSize(width: 520, height: 230),
                [[252, 0, 144], [224, 4, 248], [255, 255, 255]]
            ),
        ]

        for testCase in cases {
            let image = try makeImageWithColorsInsideEveryAnalysisCell(testCase.colors)
            let analyzed = try PostcardVisualAnalyzer.analyze(image)
            let cropped = PostcardAspectFillTransform(
                imageSize: CGSize(width: image.width, height: image.height),
                containerSize: testCase.size
            ).displayAnalysis(PostcardVisualAnalysis(
                salientRegions: [],
                samples: analyzed.samples
            ))

            let layout = PostcardOverlaySolver.solve(
                analysis: cropped,
                locationLabel: "I",
                message: "风把海面吹亮了。",
                profile: testCase.profile,
                containerSize: testCase.size
            )

            XCTAssertFalse(layout.showsLocationLabel, "\(testCase.profile)")
        }
    }

    func testLocationCandidateThatOverlapsSelectedMessageIsRejected() {
        let analysis = PostcardVisualAnalysis(
            salientRegions: [
                .init(rect: CGRect(x: 0.44, y: 0.02, width: 0.12, height: 0.20), weight: 0.9),
            ],
            samples: .uniform(luminance: 0.08, red: 0.08, green: 0.08, blue: 0.08)
        )

        let layout = PostcardOverlaySolver.solve(
            analysis: analysis,
            locationLabel: "上高地河童桥",
            message: "风把湖面吹亮了。",
            profile: .compact,
            containerSize: CGSize(width: 322, height: 120)
        )
        let messageRect = PostcardOverlayGeometry.rect(for: layout.messageRegion, profile: .compact)

        XCTAssertTrue(layout.showsLocationLabel)
        XCTAssertFalse(layout.locationRect.intersects(messageRect))
    }

    func testUnknownAndMalformedAnalysisOmitVisualLocation() {
        let unknown = PostcardOverlaySolver.unknownFallback(
            message: "风把海面吹亮了。",
            profile: .detail,
            containerSize: CGSize(width: 520, height: 230)
        )
        let malformed = PostcardOverlaySolver.solve(
            analysis: .init(
                salientRegions: [],
                samples: .init(columns: 2, rows: 2, values: [])
            ),
            locationLabel: "宫岛大鸟居",
            message: "风把海面吹亮了。",
            profile: .detail,
            containerSize: CGSize(width: 520, height: 230)
        )

        XCTAssertFalse(unknown.showsLocationLabel)
        XCTAssertFalse(malformed.showsLocationLabel)
    }

    func testStructuredLandmarkBelowActualTopLabelKeepsClearTopCorner() {
        let bright = PostcardPixelSample(luminance: 0.9, red: 0.9, green: 0.9, blue: 0.9)
        let dark = PostcardPixelSample(luminance: 0.08, red: 0.12, green: 0.06, blue: 0.03)
        let values = (0..<96).map { index -> PostcardPixelSample in
            let row = index / 12
            let column = index % 12
            return row <= 2 && column >= 6 && (row + column).isMultiple(of: 2) ? dark : bright
        }
        let analysis = PostcardVisualAnalysis(
            salientRegions: [.init(rect: CGRect(x: 0.05, y: 0.22, width: 0.35, height: 0.7), weight: 1)],
            samples: PostcardSampleGrid(columns: 12, rows: 8, values: values)
        )

        let layout = PostcardOverlaySolver.solve(
            analysis: analysis,
            message: "我追上了潮汐写出的金色路线。",
            profile: .compact,
            containerSize: CGSize(width: 322, height: 120)
        )

        XCTAssertTrue(layout.showsLocationLabel)
        XCTAssertEqual(layout.locationRegion, .topLeading)
        XCTAssertFalse(layout.locationRect.intersects(analysis.salientRegions[0].rect))
    }

    func testLocationRejectsSmallButVisibleHighSaliencyOverlap() {
        let analysis = PostcardVisualAnalysis(
            salientRegions: [
                .init(rect: CGRect(x: 0.04, y: 0.05, width: 0.002, height: 0.15), weight: 1),
            ],
            samples: .uniform(luminance: 0.92, red: 0.96, green: 0.94, blue: 0.90)
        )

        let layout = PostcardOverlaySolver.solve(
            analysis: analysis,
            message: "湖光和晨风一起把旧码头点亮了。",
            profile: .compact,
            containerSize: CGSize(width: 322, height: 120)
        )

        XCTAssertTrue(layout.showsLocationLabel)
        XCTAssertEqual(layout.locationRegion, .topTrailing)
        XCTAssertFalse(layout.locationRect.intersects(analysis.salientRegions[0].rect))
    }

    func testLocationRejectsProtectedPixelsInsideShadowAndAntialiasBoundary() {
        let size = CGSize(width: 322, height: 120)
        let label = "I"
        let content = PostcardOverlayTypography.locationRect(
            label: label,
            region: .topLeading,
            profile: .compact,
            containerSize: size
        )
        let oneDisplayPoint = 1 / size.width
        let protectedFringe = CGRect(
            x: content.maxX + oneDisplayPoint * 0.25,
            y: content.minY,
            width: oneDisplayPoint,
            height: content.height
        )
        let analysis = PostcardVisualAnalysis(
            salientRegions: [.init(rect: protectedFringe, weight: 1)],
            samples: .uniform(luminance: 0.92, red: 0.96, green: 0.94, blue: 0.90)
        )

        let layout = PostcardOverlaySolver.solve(
            analysis: analysis,
            locationLabel: label,
            message: "风把湖面吹亮了。",
            profile: .compact,
            containerSize: size
        )

        XCTAssertTrue(layout.showsLocationLabel)
        XCTAssertNotEqual(layout.locationRegion, .topLeading)
        XCTAssertFalse(layout.locationSafetyRect.intersects(protectedFringe))
    }

    func testLocationSafetyBoundsContainShortGlyphsAndClipToCanvas() {
        for (profile, size) in [
            (PostcardOverlayProfile.detail, CGSize(width: 520, height: 230)),
            (.compact, CGSize(width: 322, height: 120)),
        ] {
            for label in ["I", "宫"] {
                let content = PostcardOverlayTypography.locationRect(
                    label: label,
                    region: .locationBottomTrailing,
                    profile: profile,
                    containerSize: size
                )
                let safety = PostcardOverlayTypography.locationSafetyRect(
                    label: label,
                    region: .locationBottomTrailing,
                    profile: profile,
                    containerSize: size
                )
                let horizontalOutset = PostcardOverlayTypography.locationSafetyOutset.width
                    / size.width

                XCTAssertTrue(safety.contains(content), "\(label) \(profile)")
                XCTAssertGreaterThanOrEqual(
                    safety.width,
                    content.width + horizontalOutset - 0.000_001,
                    "\(label) \(profile)"
                )
                XCTAssertTrue(CGRect(x: 0, y: 0, width: 1, height: 1).contains(safety))
            }
        }
    }

    func testAttentionSaliencyIsAlsoHardAvoidedForLocationStamp() {
        let analysis = PostcardVisualAnalysis(
            salientRegions: [.init(rect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1), weight: 0.55)],
            samples: .uniform(luminance: 0.92, red: 0.96, green: 0.94, blue: 0.90)
        )

        let layout = PostcardOverlaySolver.solve(
            analysis: analysis,
            message: "湖光和晨风一起把旧码头点亮了。",
            profile: .compact,
            containerSize: CGSize(width: 322, height: 120)
        )

        XCTAssertTrue(layout.showsLocationLabel)
        XCTAssertTrue([.topLeading, .locationBottomLeading].contains(layout.locationRegion))
        XCTAssertFalse(layout.locationRect.intersects(analysis.salientRegions[0].rect))
    }

    func testMiyajimaLikeSubjectsKeepMinimalLocationInClearSkyAboveSubject() {
        let analysis = PostcardVisualAnalysis(
            salientRegions: [
                .init(rect: CGRect(x: 0, y: 0.30, width: 0.42, height: 0.70), weight: 0.9),
                .init(rect: CGRect(x: 0.48, y: 0, width: 0.52, height: 0.58), weight: 0.85),
            ],
            samples: .uniform(luminance: 0.65, red: 0.62, green: 0.72, blue: 0.85)
        )

        let layout = PostcardOverlaySolver.solve(
            analysis: analysis,
            message: "我追上了潮汐写出的金色路线。",
            profile: .compact,
            containerSize: CGSize(width: 322, height: 120)
        )

        XCTAssertTrue(layout.showsLocationLabel)
        XCTAssertEqual(layout.locationRegion, .topLeading)
        XCTAssertFalse(layout.locationRect.intersects(analysis.salientRegions[0].rect))
        XCTAssertFalse(layout.locationRect.intersects(analysis.salientRegions[1].rect))
        XCTAssertFalse(
            layout.locationRect.intersects(
                PostcardOverlayGeometry.rect(for: layout.messageRegion, profile: .compact)
            )
        )
    }

    func testSolverHardRejectsHighSaliencyAndUsesWideCandidateForLongMessage() {
        let analysis = PostcardVisualAnalysis(
            salientRegions: [
                .init(rect: CGRect(x: 0, y: 0, width: 0.18, height: 0.72), weight: 1),
            ],
            samples: .uniform(luminance: 0.92, red: 0.96, green: 0.94, blue: 0.90)
        )
        let layout = PostcardOverlaySolver.solve(
            analysis: analysis,
            message: String(repeating: "旅", count: 80),
            profile: .compact,
            containerSize: CGSize(width: 676, height: 120)
        )

        XCTAssertTrue(layout.showsLocationLabel)
        XCTAssertEqual(layout.locationRegion, .topTrailing)
        XCTAssertEqual(layout.messageRegion, .wideMiddleTrailing)
        XCTAssertGreaterThanOrEqual(layout.messageFontSize, 12)
        for salient in analysis.salientRegions {
            let rect = PostcardOverlayGeometry.rect(for: layout.messageRegion, profile: .compact)
            XCTAssertLessThan(rect.intersection(salient.rect).width * rect.intersection(salient.rect).height, 0.001)
        }
    }

    func testLocationCanMoveToBottomWhenTopContainsCriticalLandmark() {
        let analysis = PostcardVisualAnalysis(
            salientRegions: [
                .init(rect: CGRect(x: 0, y: 0, width: 1, height: 0.35), weight: 1),
            ],
            samples: .uniform(luminance: 0.92, red: 0.96, green: 0.94, blue: 0.90)
        )

        let layout = PostcardOverlaySolver.solve(
            analysis: analysis,
            message: "潮汐写出的金色路线。",
            profile: .detail,
            containerSize: CGSize(width: 520, height: 230)
        )

        XCTAssertTrue(layout.showsLocationLabel)
        XCTAssertTrue([.locationBottomLeading, .locationBottomTrailing].contains(layout.locationRegion))
        XCTAssertFalse(
            layout.locationRect
                .intersects(PostcardOverlayGeometry.rect(for: layout.messageRegion, profile: .detail))
        )
    }

    func testOverlayPresentationUsesFullTopLeadingCanvasAndVisibleFrames() {
        for size in [CGSize(width: 520, height: 230), CGSize(width: 340, height: 100)] {
            XCTAssertEqual(
                PostcardOverlayPresentation.canvasFrame(containerSize: size),
                CGRect(origin: .zero, size: size)
            )
            for profile in [PostcardOverlayProfile.detail, .compact] {
                for region in PostcardOverlayRegion.allCases {
                    let frame = PostcardOverlayPresentation.frame(
                        for: region,
                        profile: profile,
                        containerSize: size
                    )
                    XCTAssertTrue(CGRect(origin: .zero, size: size).contains(frame))
                    XCTAssertGreaterThan(frame.width, 0)
                    XCTAssertGreaterThan(frame.height, 0)
                }
            }
        }
    }

    func testTypographyFitsRealChineseMessagesWithoutEllipsisAtRenderedSizes() {
        let messages = [
            "湖光和晨风一起把旧码头点亮了。",
            "我追上了潮汐写出的金色路线。",
            "桥、清水和山峰终于都在同一幅画里。",
        ]
        let configurations: [(PostcardOverlayProfile, CGSize, Int)] = [
            (.detail, CGSize(width: 520, height: 230), 3),
            (.compact, CGSize(width: 340, height: 100), 2),
        ]

        for message in messages {
            for (profile, size, lineLimit) in configurations {
                let fit = PostcardOverlayTypography.fit(
                    messageLength: message.count,
                    region: .bottomLeading,
                    profile: profile,
                    containerSize: size
                )
                XCTAssertLessThanOrEqual(fit.requiredLineCount, lineLimit)
                XCTAssertTrue(fit.fitsVertically)
                XCTAssertGreaterThanOrEqual(fit.fontSize, profile == .detail ? 17 : 6)
            }
        }
    }

    func testCompactLocationFitKeepsFullLongDestinationWithinTwoLines() {
        let label = "Japan · Hatsukaichi · Itsukushima Shrine O-Torii"
        let fit = PostcardOverlayTypography.locationFit(
            label: label,
            region: .topTrailing,
            profile: .compact,
            containerSize: CGSize(width: 322, height: 120)
        )

        XCTAssertLessThanOrEqual(fit.requiredLineCount, 2)
        XCTAssertTrue(fit.fitsVertically)
        XCTAssertGreaterThanOrEqual(fit.minimumScaleFactor, 0.4)
    }

    func testCompactBottomLocationCornerStaysOutOfTheLeftSubjectZone() {
        let trailing = PostcardOverlayGeometry.rect(for: .locationBottomTrailing, profile: .compact)

        XCTAssertGreaterThanOrEqual(trailing.minX, 0.48)
        XCTAssertLessThanOrEqual(trailing.width, 0.48)
    }

    func testContrastTreatmentGuaranteesMixedBackgroundEndpoints() {
        let treatment = PostcardTextContrast.treatment(backgroundLuminanceRange: 0...1)
        let wash = treatment.usesLightText ? 0.0 : 1.0
        for luminance in [0.0, 1.0] {
            let effective = luminance * (1 - treatment.washOpacity) + wash * treatment.washOpacity
            XCTAssertGreaterThanOrEqual(
                PostcardTextContrast.contrastRatio(
                    foregroundLuminance: treatment.foregroundLuminance,
                    backgroundLuminance: effective
                ),
                PostcardTextContrast.minimumContrastRatio - 0.000_001
            )
        }
    }

    func testLocationLabelHasTwoLineLimitAndCornerDoesNotOverlapMiddleMessages() {
        for profile in [PostcardOverlayProfile.detail, .compact] {
            XCTAssertEqual(PostcardOverlayGeometry.locationLineLimit(profile: profile), 2)
            let location = PostcardOverlayGeometry.rect(for: .topLeading, profile: profile)
            for region in [PostcardOverlayRegion.middleLeading, .middleTrailing, .bottomLeading, .bottomTrailing] {
                XCTAssertFalse(location.intersects(PostcardOverlayGeometry.rect(for: region, profile: profile)))
            }
        }
    }

    func testUnknownFallbackGuaranteesWorstCaseContrastWithFixedBlackWash() {
        for profile in [PostcardOverlayProfile.detail, .compact] {
            let layout = PostcardOverlaySolver.unknownFallback(
                messageLength: 12,
                profile: profile
            )

            XCTAssertEqual(layout.messageRegion, .bottomLeading)
            XCTAssertTrue(layout.inkStyle.usesLightText)
            XCTAssertGreaterThanOrEqual(layout.inkStyle.washOpacity, 0.80)
            XCTAssertEqual(layout.inkStyle.washOpacity, 0.82, accuracy: 0.000_001)
            for actualBackground in [0.0, 1.0] {
                let effectiveBackground = PostcardInkColor(
                    red: actualBackground * (1 - layout.inkStyle.washOpacity)
                        + layout.inkStyle.wash.red * layout.inkStyle.washOpacity,
                    green: actualBackground * (1 - layout.inkStyle.washOpacity)
                        + layout.inkStyle.wash.green * layout.inkStyle.washOpacity,
                    blue: actualBackground * (1 - layout.inkStyle.washOpacity)
                        + layout.inkStyle.wash.blue * layout.inkStyle.washOpacity
                ).relativeLuminance
                XCTAssertGreaterThanOrEqual(
                    PostcardTextContrast.contrastRatio(
                        foregroundLuminance: layout.inkStyle.foreground.relativeLuminance,
                        backgroundLuminance: effectiveBackground
                    ),
                    4.5
                )
            }
        }
    }

    func testPublicFallbackIsUnknownRatherThanFabricatedSample() {
        let layout = PostcardOverlaySolver.fallback(messageLength: 12, profile: .detail)

        XCTAssertEqual(layout, PostcardOverlaySolver.unknownFallback(messageLength: 12, profile: .detail))
    }

    func testEmptySaliencyUsesBottomFallbackWhilePreservingSceneSample() {
        let scene = PostcardPixelSample(luminance: 0.8, red: 0.7, green: 0.6, blue: 0.5)
        let analysis = PostcardVisualAnalysis(
            salientRegions: [],
            samples: .uniform(
                luminance: scene.luminance,
                red: scene.red,
                green: scene.green,
                blue: scene.blue
            )
        )

        let layout = PostcardOverlaySolver.solve(
            analysis: analysis,
            messageLength: 12,
            profile: .detail
        )

        XCTAssertEqual(layout.messageRegion, .bottomLeading)
        XCTAssertEqual(layout.accent, scene)
        XCTAssertEqual(layout.inkStyle.sceneFamily, .warmEarth)
        XCTAssertGreaterThanOrEqual(layout.inkStyle.minimumContrastRatio, 4.5)
    }

    func testNonemptySaliencyUsesAdaptiveSolverInsteadOfFallback() {
        let analysis = PostcardVisualAnalysis(
            salientRegions: [
                .init(rect: PostcardOverlayGeometry.rect(for: .bottomLeading, profile: .detail), weight: 1),
            ],
            samples: .uniform(luminance: 0.4, red: 0.3, green: 0.4, blue: 0.5)
        )

        let layout = PostcardOverlaySolver.solve(
            analysis: analysis,
            messageLength: 12,
            profile: .detail
        )

        XCTAssertNotEqual(layout.messageRegion, .bottomLeading)
    }

    func testContrastTreatmentGuaranteesNormalTextRatioAcrossSceneLuminances() {
        for background in [0.0, 0.02, 0.17, 0.5, 0.579, 0.58, 0.95, 1.0] {
            let treatment = PostcardTextContrast.treatment(backgroundLuminance: background)

            XCTAssertGreaterThanOrEqual(
                PostcardTextContrast.contrastRatio(
                    foregroundLuminance: treatment.foregroundLuminance,
                    backgroundLuminance: treatment.effectiveBackgroundLuminance
                ),
                4.5 - 0.000_001,
                "background \(background)"
            )
            XCTAssertGreaterThanOrEqual(treatment.washOpacity, 0)
            XCTAssertLessThanOrEqual(treatment.washOpacity, 0.72)
        }
    }

    func testContrastTreatmentDarkensMidgrayAndNearThresholdForLightText() {
        for background in [0.5, 0.579] {
            let treatment = PostcardTextContrast.treatment(backgroundLuminance: background)

            XCTAssertTrue(treatment.usesLightText)
            XCTAssertGreaterThan(treatment.washOpacity, 0)
            XCTAssertLessThan(treatment.effectiveBackgroundLuminance, background)
        }
    }

    func testContrastTreatmentUsesDarkTextAndLightWashDirectionForBrightScenes() {
        let treatment = PostcardTextContrast.treatment(backgroundLuminance: 0.95)

        XCTAssertFalse(treatment.usesLightText)
        XCTAssertEqual(treatment.foregroundLuminance, 0)
        XCTAssertGreaterThanOrEqual(treatment.effectiveBackgroundLuminance, 0.95)
    }

    func testContrastTreatmentUsesOpaqueWhiteForLightText() {
        let treatment = PostcardTextContrast.treatment(backgroundLuminance: 0.1)

        XCTAssertTrue(treatment.usesLightText)
        XCTAssertEqual(treatment.foregroundLuminance, 1)
    }

    func testRelativeLuminanceLinearizesSRGBComponents() {
        XCTAssertEqual(
            PostcardTextContrast.relativeLuminance(red: 0.5, green: 0.5, blue: 0.5),
            0.214_041,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            PostcardTextContrast.relativeLuminance(red: 1, green: 1, blue: 1),
            1,
            accuracy: 0.000_001
        )
    }

    func testGeometryDefinesEveryRenderedRegionForBothProfiles() {
        let expected: [(PostcardOverlayProfile, PostcardOverlayRegion, CGRect)] = [
            (.detail, .topLeading, CGRect(x: 0.04, y: 0.05, width: 0.40, height: 0.22)),
            (.detail, .topTrailing, CGRect(x: 0.56, y: 0.05, width: 0.40, height: 0.22)),
            (.detail, .middleLeading, CGRect(x: 0.05, y: 0.40, width: 0.42, height: 0.29)),
            (.detail, .middleTrailing, CGRect(x: 0.53, y: 0.40, width: 0.42, height: 0.29)),
            (.detail, .bottomLeading, CGRect(x: 0.05, y: 0.66, width: 0.42, height: 0.29)),
            (.detail, .bottomTrailing, CGRect(x: 0.53, y: 0.66, width: 0.42, height: 0.29)),
            (.detail, .wideTopLeading, CGRect(x: 0.04, y: 0.05, width: 0.76, height: 0.30)),
            (.detail, .wideMiddleLeading, CGRect(x: 0.04, y: 0.30, width: 0.76, height: 0.30)),
            (.detail, .wideMiddleTrailing, CGRect(x: 0.20, y: 0.30, width: 0.76, height: 0.30)),
            (.detail, .wideBottomLeading, CGRect(x: 0.04, y: 0.66, width: 0.76, height: 0.29)),
            (.detail, .wideBottomTrailing, CGRect(x: 0.20, y: 0.66, width: 0.76, height: 0.29)),
            (.detail, .locationBottomLeading, CGRect(x: 0.04, y: 0.73, width: 0.40, height: 0.22)),
            (.detail, .locationBottomTrailing, CGRect(x: 0.56, y: 0.73, width: 0.40, height: 0.22)),
            (.detail, .scenicTopLeading, CGRect(x: 0.02, y: 0.02, width: 0.40, height: 0.24)),
            (.detail, .columnLeading, CGRect(x: 0.03, y: 0.37, width: 0.38, height: 0.58)),
            (.detail, .columnTrailing, CGRect(x: 0.59, y: 0.37, width: 0.38, height: 0.58)),
            (.compact, .topLeading, CGRect(x: 0.04, y: 0.05, width: 0.58, height: 0.30)),
            (.compact, .topTrailing, CGRect(x: 0.48, y: 0.05, width: 0.48, height: 0.25)),
            (.compact, .middleLeading, CGRect(x: 0.04, y: 0.40, width: 0.48, height: 0.32)),
            (.compact, .middleTrailing, CGRect(x: 0.48, y: 0.40, width: 0.48, height: 0.32)),
            (.compact, .bottomLeading, CGRect(x: 0.04, y: 0.58, width: 0.48, height: 0.37)),
            (.compact, .bottomTrailing, CGRect(x: 0.48, y: 0.58, width: 0.48, height: 0.37)),
            (.compact, .wideTopLeading, CGRect(x: 0.04, y: 0.05, width: 0.76, height: 0.38)),
            (.compact, .wideMiddleLeading, CGRect(x: 0.04, y: 0.35, width: 0.76, height: 0.37)),
            (.compact, .wideMiddleTrailing, CGRect(x: 0.20, y: 0.35, width: 0.76, height: 0.37)),
            (.compact, .wideBottomLeading, CGRect(x: 0.04, y: 0.58, width: 0.76, height: 0.37)),
            (.compact, .wideBottomTrailing, CGRect(x: 0.20, y: 0.58, width: 0.76, height: 0.37)),
            (.compact, .locationBottomLeading, CGRect(x: 0.04, y: 0.72, width: 0.58, height: 0.27)),
            (.compact, .locationBottomTrailing, CGRect(x: 0.48, y: 0.72, width: 0.48, height: 0.27)),
            (.compact, .scenicTopLeading, CGRect(x: 0.02, y: 0.02, width: 0.34, height: 0.31)),
            (.compact, .columnLeading, CGRect(x: 0.03, y: 0.37, width: 0.38, height: 0.58)),
            (.compact, .columnTrailing, CGRect(x: 0.59, y: 0.37, width: 0.38, height: 0.58)),
        ]

        XCTAssertEqual(expected.count, PostcardOverlayRegion.allCases.count * 2)
        for (profile, region, rect) in expected {
            XCTAssertEqual(PostcardOverlayGeometry.rect(for: region, profile: profile), rect)
        }
    }

    func testCompactSolverAvoidsSaliencyInRenderedOnlyMiddleDelta() {
        let analysis = PostcardVisualAnalysis(
            salientRegions: [
                .init(rect: CGRect(x: 0.05, y: 0.60, width: 0.42, height: 0.06), weight: 1),
            ],
            samples: .uniform(luminance: 0.5, red: 0.4, green: 0.3, blue: 0.2)
        )

        let layout = PostcardOverlaySolver.solve(
            analysis: analysis,
            messageLength: 12,
            profile: .compact
        )

        XCTAssertEqual(layout.messageRegion, .middleTrailing)
        XCTAssertEqual(layout.pawSignature.placement.mode, .signatureLine)
        XCTAssertFalse(layout.pawSignature.placement.pawFrame.intersects(layout.pawSignature.placement.textFrame))
    }

    func testCompactSolverSamplesContrastAndAccentAcrossActualRenderedRect() {
        let light = PostcardPixelSample(luminance: 0.7, red: 0.9, green: 0.8, blue: 0.7)
        let dark = PostcardPixelSample(luminance: 0.1, red: 0.1, green: 0.2, blue: 0.3)
        let samples = (0..<100).map { row in
            (30..<60).contains(row) ? light : dark
        }
        let analysis = PostcardVisualAnalysis(
            salientRegions: [
                .init(rect: CGRect(x: 0.50, y: 0.28, width: 0.50, height: 0.72), weight: 1),
                .init(rect: CGRect(x: 0, y: 0.66, width: 0.50, height: 0.34), weight: 1),
            ],
            samples: PostcardSampleGrid(columns: 1, rows: 100, values: samples)
        )

        let layout = PostcardOverlaySolver.solve(
            analysis: analysis,
            messageLength: 12,
            profile: .compact
        )

        XCTAssertEqual(layout.messageRegion, .middleLeading)
        XCTAssertLessThan(layout.accent.luminance, 0.58)
        XCTAssertGreaterThan(layout.accent.red, layout.accent.blue)
        let backgrounds = analysis.samples.colorSamples(
            in: PostcardOverlayGeometry.rect(for: layout.messageRegion, profile: .compact)
        )
        let foreground = layout.inkStyle.foreground.relativeLuminance
        for background in backgrounds {
            let effective = PostcardInkColor(
                red: background.red * (1 - layout.inkStyle.washOpacity)
                    + layout.inkStyle.wash.red * layout.inkStyle.washOpacity,
                green: background.green * (1 - layout.inkStyle.washOpacity)
                    + layout.inkStyle.wash.green * layout.inkStyle.washOpacity,
                blue: background.blue * (1 - layout.inkStyle.washOpacity)
                    + layout.inkStyle.wash.blue * layout.inkStyle.washOpacity
            ).relativeLuminance
            XCTAssertGreaterThanOrEqual(
                PostcardTextContrast.contrastRatio(
                    foregroundLuminance: foreground,
                    backgroundLuminance: effective
                ),
                4.5 - 0.000_001
            )
        }
    }

    func testSolverSelectedLocationAndMessageRectsNeverOverlap() {
        let analysis = PostcardVisualAnalysis(
            salientRegions: [],
            samples: .uniform(luminance: 0.5, red: 0.4, green: 0.3, blue: 0.2)
        )

        for profile in [PostcardOverlayProfile.detail, .compact] {
            let layout = PostcardOverlaySolver.solve(
                analysis: analysis,
                messageLength: 12,
                profile: profile
            )
            let message = PostcardOverlayGeometry.rect(for: layout.messageRegion, profile: profile)
            if layout.showsLocationLabel {
                XCTAssertFalse(layout.locationRect.intersects(message))
            }
        }
    }

    func testMetadataUsesPreferredDisplayPlaceAndKeepsFullMoodQuoteWhileNormalizingVisualMessage() {
        let event = postcardEvent(
            location: Location(country: " 日本 ", city: "上高地", place: "上高地"),
            quote: " 风从梓川吹过来，今天的心也变得很轻。 "
        )

        let metadata = PostcardArtworkMetadata(event: event)

        XCTAssertEqual(metadata.locationLabel, "上高地")
        XCTAssertEqual(metadata.fullMessage, event.mood.quote)
        XCTAssertEqual(metadata.visualMessage, "风从梓川吹过来，今天的心也变得很轻。")
    }

    func testMetadataFallsBackWhenDestinationHasNoVisibleComponent() {
        let event = postcardEvent(location: Location(country: " ", city: "\n", place: ""), quote: "出发。")

        XCTAssertEqual(PostcardArtworkMetadata(event: event).locationLabel, "旅途中")
    }

    func testAnalysisNormalizesRegionsAndSamples() {
        let analysis = PostcardVisualAnalysis(
            salientRegions: [
                .init(rect: CGRect(x: -0.2, y: 0.8, width: 1.5, height: 0.5), weight: 2),
                .init(rect: CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1), weight: .infinity),
            ],
            samples: PostcardSampleGrid(
                columns: 1,
                rows: 1,
                values: [.init(luminance: 1.4, red: -0.2, green: .nan, blue: .infinity)]
            )
        )

        XCTAssertEqual(analysis.salientRegions[0].rect.minX, 0, accuracy: 0.000_001)
        XCTAssertEqual(analysis.salientRegions[0].rect.minY, 0.8, accuracy: 0.000_001)
        XCTAssertEqual(analysis.salientRegions[0].rect.maxX, 1, accuracy: 0.000_001)
        XCTAssertEqual(analysis.salientRegions[0].rect.maxY, 1, accuracy: 0.000_001)
        XCTAssertEqual(analysis.salientRegions[0].weight, 1)
        XCTAssertEqual(analysis.salientRegions[1].rect, CGRect.zero)
        XCTAssertEqual(analysis.salientRegions[1].weight, 0)
        XCTAssertEqual(
            analysis.samples.values[0],
            PostcardPixelSample(luminance: 1, red: 0, green: 0, blue: 0)
        )
    }

    func testSolverAvoidsProminentLeftSideAndKeepsOverlaysSeparate() {
        let analysis = PostcardVisualAnalysis(
            salientRegions: [.init(rect: CGRect(x: 0, y: 0, width: 0.58, height: 1), weight: 1)],
            samples: .uniform(luminance: 0.92, red: 0.96, green: 0.94, blue: 0.90)
        )

        let layout = PostcardOverlaySolver.solve(analysis: analysis, messageLength: 18, profile: .detail)

        XCTAssertTrue([.middleTrailing, .bottomTrailing, .wideMiddleTrailing, .wideBottomTrailing].contains(layout.messageRegion))
        XCTAssertTrue(layout.showsLocationLabel)
        XCTAssertEqual(layout.locationRegion, .topTrailing)
        XCTAssertNotEqual(layout.locationRegion, layout.messageRegion)
    }

    func testSolverAvoidsProminentRightSide() {
        let analysis = PostcardVisualAnalysis(
            salientRegions: [.init(rect: CGRect(x: 0.42, y: 0, width: 0.58, height: 1), weight: 1)],
            samples: .uniform(luminance: 0.5, red: 0.3, green: 0.4, blue: 0.5)
        )

        let layout = PostcardOverlaySolver.solve(analysis: analysis, messageLength: 18, profile: .detail)

        XCTAssertEqual(layout.locationRegion, .topLeading)
        XCTAssertTrue([.middleLeading, .bottomLeading, .wideMiddleLeading, .wideBottomLeading].contains(layout.messageRegion))
    }

    func testUniformSampleAppliesToEveryCandidateRegion() {
        let supplied = PostcardPixelSample(luminance: 0.8, red: 0.7, green: 0.6, blue: 0.5)
        let analysis = PostcardVisualAnalysis(
            salientRegions: [],
            samples: .uniform(
                luminance: supplied.luminance,
                red: supplied.red,
                green: supplied.green,
                blue: supplied.blue
            )
        )

        let lightLayout = PostcardOverlaySolver.solve(analysis: analysis, messageLength: 12, profile: .detail)
        let darkLayout = PostcardOverlaySolver.solve(
            analysis: PostcardVisualAnalysis(
                salientRegions: [],
                samples: .uniform(luminance: 0.2, red: 0.1, green: 0.2, blue: 0.3)
            ),
            messageLength: 12,
            profile: .detail
        )

        XCTAssertEqual(lightLayout.inkStyle.sceneFamily, .warmEarth)
        XCTAssertEqual(lightLayout.messageRegion, .bottomLeading)
        XCTAssertEqual(lightLayout.accent, supplied)
        XCTAssertEqual(darkLayout.inkStyle.sceneFamily, .lakeBlue)
        XCTAssertGreaterThanOrEqual(darkLayout.inkStyle.minimumContrastRatio, 4.5)
        XCTAssertEqual(darkLayout.messageRegion, .bottomLeading)
        XCTAssertEqual(
            darkLayout.accent,
            PostcardPixelSample(luminance: 0.2, red: 0.1, green: 0.2, blue: 0.3)
        )
    }

    func testAverageWeightsSamplesByCellAreaOverlap() {
        let grid = PostcardSampleGrid(
            columns: 2,
            rows: 1,
            values: [
                .init(luminance: 0, red: 0, green: 0, blue: 0),
                .init(luminance: 1, red: 1, green: 1, blue: 1),
            ]
        )

        let average = grid.average(in: CGRect(x: 0.45, y: 0, width: 0.2, height: 1))

        XCTAssertEqual(average.luminance, 0.75, accuracy: 0.000_001)
        XCTAssertEqual(average.red, 0.75, accuracy: 0.000_001)
    }

    func testSolverUsesWeightedSaliencyIntersectionAndDeterministicTieBreaking() {
        let analysis = PostcardVisualAnalysis(
            salientRegions: [
                .init(rect: CGRect(x: 0, y: 0.28, width: 0.5, height: 0.72), weight: 0.9),
                .init(rect: CGRect(x: 0.5, y: 0.28, width: 0.5, height: 0.72), weight: 0.1),
            ],
            samples: .uniform(luminance: 0.5, red: 0.4, green: 0.3, blue: 0.2)
        )

        let first = PostcardOverlaySolver.solve(analysis: analysis, messageLength: 12, profile: .detail)
        let second = PostcardOverlaySolver.solve(analysis: analysis, messageLength: 12, profile: .detail)

        XCTAssertEqual(first, second)
        XCTAssertTrue([.middleTrailing, .bottomTrailing].contains(first.messageRegion))
    }

    func testSolverUsesLocalLuminanceAndSampledAccent() {
        let dark = PostcardPixelSample(luminance: 0.2, red: 0.1, green: 0.2, blue: 0.3)
        let light = PostcardPixelSample(luminance: 0.8, red: 0.8, green: 0.7, blue: 0.6)
        let values = (0..<8).flatMap { row in
            (0..<12).map { column in
                (row >= 2 && column < 6) ? dark : light
            }
        }
        let analysis = PostcardVisualAnalysis(
            salientRegions: [.init(rect: CGRect(x: 0.5, y: 0.25, width: 0.5, height: 0.75), weight: 1)],
            samples: PostcardSampleGrid(columns: 12, rows: 8, values: values)
        )

        let layout = PostcardOverlaySolver.solve(analysis: analysis, messageLength: 10, profile: .detail)

        XCTAssertEqual(layout.messageRegion, .middleLeading)
        XCTAssertEqual(layout.inkStyle.sceneFamily, .lakeBlue)
        XCTAssertGreaterThanOrEqual(layout.inkStyle.minimumContrastRatio, 4.5)
        XCTAssertLessThan(layout.accent.luminance, 0.58)
    }

    func testFallbackAndFontSizesAreMonotonicAndBoundedByProfile() {
        let shortDetail = PostcardOverlaySolver.fallback(messageLength: 6, profile: .detail)
        let longDetail = PostcardOverlaySolver.fallback(messageLength: 80, profile: .detail)
        let shortCompact = PostcardOverlaySolver.fallback(messageLength: 6, profile: .compact)
        let longCompact = PostcardOverlaySolver.fallback(messageLength: 80, profile: .compact)

        XCTAssertEqual(shortDetail.messageRegion, .wideBottomLeading)
        XCTAssertEqual(longDetail.messageRegion, .wideBottomLeading)
        XCTAssertLessThanOrEqual(longDetail.messageFontSize, shortDetail.messageFontSize)
        XCTAssertGreaterThanOrEqual(longDetail.messageFontSize, 17)
        XCTAssertLessThanOrEqual(shortDetail.messageFontSize, 30)
        XCTAssertLessThanOrEqual(longCompact.messageFontSize, shortCompact.messageFontSize)
        XCTAssertEqual(longCompact.messageRegion, .wideBottomLeading)
        XCTAssertGreaterThanOrEqual(longCompact.messageFontSize, 12)
        XCTAssertLessThanOrEqual(shortCompact.messageFontSize, 16)
        XCTAssertGreaterThan(longDetail.inkStyle.washOpacity, 0)
    }

    func testMalformedSampleGridFailsSafeToFallback() {
        let analysis = PostcardVisualAnalysis(
            salientRegions: [],
            samples: PostcardSampleGrid(
                columns: 2,
                rows: 2,
                values: [.init(luminance: 0.1, red: 0.1, green: 0.1, blue: 0.1)]
            )
        )

        let layout = PostcardOverlaySolver.solve(analysis: analysis, messageLength: 20, profile: .detail)

        XCTAssertEqual(layout, PostcardOverlaySolver.fallback(messageLength: 20, profile: .detail))
    }

    func testExtremeNegativeMessageLengthIsClampedWithoutOverflow() {
        let layout = PostcardOverlaySolver.fallback(messageLength: .min, profile: .detail)

        XCTAssertEqual(layout.messageFontSize, 30)
    }

    private func makeImageWithColorsInsideEveryAnalysisCell(_ colors: [[UInt8]]) throws -> CGImage {
        XCTAssertFalse(colors.isEmpty)
        XCTAssertTrue(colors.allSatisfy { $0.count == 3 })
        let width = PostcardVisualAnalyzer.sampleColumns * colors.count
        let height = PostcardVisualAnalyzer.sampleRows
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for row in 0..<height {
            for column in 0..<width {
                let color = colors[column % colors.count]
                let offset = (row * width + column) * 4
                bytes[offset] = color[0]
                bytes[offset + 1] = color[1]
                bytes[offset + 2] = color[2]
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

    private func normalized(_ rect: CGRect, in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        return CGRect(
            x: rect.minX / size.width,
            y: rect.minY / size.height,
            width: rect.width / size.width,
            height: rect.height / size.height
        )
    }

    private func postcardEvent(location: Location?, quote: String) -> TripEvent {
        TripEvent(
            id: UUID(),
            tripID: UUID(),
            previousEventID: nil,
            occurredAt: Date(timeIntervalSince1970: 0),
            phase: .postcardReady,
            location: location,
            transport: nil,
            summary: "寄来一张明信片。",
            mood: Mood(level: 4, label: "轻快", quote: quote),
            continuityReferences: [],
            openHook: nil,
            consumedItemID: nil,
            postcardStatus: .ready,
            postcardRelativePath: "postcards/trip/card.webp"
        )
    }

    private func postcardEvent(location: Location?, mood: Mood) -> TripEvent {
        TripEvent(
            id: UUID(),
            tripID: UUID(),
            previousEventID: nil,
            occurredAt: Date(timeIntervalSince1970: 0),
            phase: .postcardReady,
            location: location,
            transport: nil,
            summary: "寄来一张明信片。",
            mood: mood,
            continuityReferences: [],
            openHook: nil,
            consumedItemID: nil,
            postcardStatus: .ready,
            postcardRelativePath: "postcards/trip/card.webp"
        )
    }
}
