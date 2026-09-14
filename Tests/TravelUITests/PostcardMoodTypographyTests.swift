import AppKit
import CoreGraphics
import CoreText
import os
import XCTest
import TravelCore
@testable import TravelUI

final class PostcardMoodTypographyTests: XCTestCase {
    func testMoodLevelProvidesStableFamilyAndKeywordsRefineIt() {
        let resolver = resolverWithAllPreferredFonts()

        XCTAssertEqual(resolver.resolve(mood: mood(-2, "unknown")).family, .reflective)
        XCTAssertEqual(resolver.resolve(mood: mood(0, "unknown")).family, .serene)
        XCTAssertEqual(resolver.resolve(mood: mood(1, "unknown")).family, .playful)
        XCTAssertEqual(resolver.resolve(mood: mood(2, "unknown")).family, .bold)

        XCTAssertEqual(resolver.resolve(mood: mood(2, "平静")).family, .serene)
        XCTAssertEqual(resolver.resolve(mood: mood(0, "开心")).family, .playful)
        XCTAssertEqual(resolver.resolve(mood: mood(0, "兴奋")).family, .playful)
        XCTAssertEqual(resolver.resolve(mood: mood(0, "思念")).family, .reflective)
        XCTAssertEqual(resolver.resolve(mood: mood(0, "孤独")).family, .reflective)
        XCTAssertEqual(resolver.resolve(mood: mood(0, "惊讶")).family, .bold)
        XCTAssertEqual(resolver.resolve(mood: mood(0, "坚定")).family, .bold)
    }

    func testEnglishKeywordsAreCaseDiacriticAndWidthTolerant() {
        let resolver = resolverWithAllPreferredFonts()

        XCTAssertEqual(resolver.resolve(mood: mood(0, "  CÚRIOUS  ")).family, .playful)
        XCTAssertEqual(resolver.resolve(mood: mood(0, "ＲＥＦＬＥＣＴＩＶＥ")).family, .reflective)
        XCTAssertEqual(resolver.resolve(mood: mood(0, "Peaceful")).family, .serene)
        XCTAssertEqual(resolver.resolve(mood: mood(0, "EXCITED")).family, .playful)
        XCTAssertEqual(resolver.resolve(mood: mood(0, "LONELY")).family, .reflective)
        XCTAssertEqual(resolver.resolve(mood: mood(0, "SURPRISED")).family, .bold)
        XCTAssertEqual(resolver.resolve(mood: mood(0, "DETERMINED")).family, .bold)
    }

    func testEnglishKeywordsUseWordBoundariesAndMixedMatchesHaveStablePriority() {
        let resolver = resolverWithAllPreferredFonts()

        XCTAssertEqual(resolver.resolve(mood: mood(-1, "unhappy")).family, .reflective)
        XCTAssertEqual(resolver.resolve(mood: mood(2, "discontent")).family, .bold)
        XCTAssertEqual(resolver.resolve(mood: mood(0, "curiosity!")).family, .playful)
        XCTAssertEqual(resolver.resolve(mood: mood(0, "not happy")).family, .playful)
        XCTAssertEqual(resolver.resolve(mood: mood(0, "calm, curious, determined")).family, .bold)
    }

    func testChineseNegationDoesNotReverseMoodClassification() {
        let resolver = resolverWithAllPreferredFonts()

        XCTAssertEqual(resolver.resolve(mood: mood(-1, "不开心")).family, .reflective)
        XCTAssertEqual(resolver.resolve(mood: mood(2, "不满足")).family, .bold)
        XCTAssertEqual(resolver.resolve(mood: mood(-1, "没有那么兴奋")).family, .reflective)
        XCTAssertEqual(resolver.resolve(mood: mood(1, "并不紧张")).family, .playful)
        XCTAssertEqual(resolver.resolve(mood: mood(-1, "没有很开心")).family, .reflective)
        XCTAssertEqual(resolver.resolve(mood: mood(0, "不怎么开心")).family, .serene)
    }

    func testFailedBundledRegistrationCannotLeakPartialOrExternalSameNameFaces() {
        let attemptedSystemCandidates = OSAllocatedUnfairLock(initialState: [String]())
        let resolver = PostcardMoodTypographyResolver(
            bundledFontLookup: { _, _ in nil },
            fontLookup: { candidate, _ in
                attemptedSystemCandidates.withLock { $0.append(candidate) }
                return candidate == "Kaiti SC"
                    ? .init(postScriptName: "STKaiti", actualWeight: 0)
                    : .init(postScriptName: candidate, actualWeight: 0)
            }
        )

        let style = resolver.resolve(mood: mood(0, "平静"))

        XCTAssertEqual(style.fontPostScriptName, "STKaiti")
        XCTAssertFalse(attemptedSystemCandidates.withLock { $0 }.contains {
            $0.hasPrefix("LXGWWenKaiLite-")
        })
    }

    func testUnknownLabelsUseClampedLevelDeterministically() {
        let resolver = resolverWithAllPreferredFonts()
        let veryLow = resolver.resolve(mood: mood(.min, "???"))
        let veryHigh = resolver.resolve(mood: mood(.max, "???"))

        XCTAssertEqual(veryLow.family, .reflective)
        XCTAssertEqual(veryHigh.family, .bold)
        XCTAssertEqual(veryLow, resolver.resolve(mood: mood(.min, "???")))
        XCTAssertEqual(veryHigh, resolver.resolve(mood: mood(.max, "???")))
    }

    func testEachFamilyHasBoundedSemanticRenderingValues() {
        let resolver = resolverWithAllPreferredFonts()
        let styles = [
            resolver.resolve(mood: mood(0, "平静")),
            resolver.resolve(mood: mood(0, "开心")),
            resolver.resolve(mood: mood(0, "思念")),
            resolver.resolve(mood: mood(0, "紧张")),
        ]

        XCTAssertEqual(Set(styles.map(\.family)), Set(PostcardHandwritingFamily.allCases))
        for style in styles {
            XCTAssertTrue((0.92...1.08).contains(style.sizeScale))
            XCTAssertTrue((1.05...1.35).contains(style.lineSpacing))
            XCTAssertTrue((0.55...0.70).contains(style.pawOpacity))
            XCTAssertTrue((-1...1).contains(style.fontWeight))
        }
    }

    func testPreferredFontResolutionAndSereneKaiFallback() {
        let preferred = PostcardMoodTypographyResolver(fontLookup: { name, weight in
            switch name {
            case "HanziPen SC": .init(postScriptName: "HanziPenSC-W3", actualWeight: weight)
            case "Kaiti SC": .init(postScriptName: "STKaitiSC-Regular", actualWeight: weight)
            default: nil
            }
        })

        XCTAssertEqual(
            preferred.resolve(mood: mood(1, "开心")).fontPostScriptName,
            "HanziPenSC-W3"
        )

        let kaiOnly = PostcardMoodTypographyResolver(fontLookup: { name, weight in
            name == "Kaiti SC"
                ? .init(postScriptName: "STKaitiSC-Regular", actualWeight: weight)
                : nil
        })
        let playfulFallback = kaiOnly.resolve(mood: mood(1, "开心"))
        XCTAssertEqual(playfulFallback.family, .playful)
        XCTAssertEqual(playfulFallback.fontPostScriptName, "STKaitiSC-Regular")
        XCTAssertFalse(playfulFallback.usesSystemFont)
    }

    func testMissingAllPreferredFontsFallsBackToSystemWithoutRoundedItalic() {
        let resolver = PostcardMoodTypographyResolver(fontLookup: { _, _ in nil })
        let style = resolver.resolve(mood: mood(2, "兴奋"))

        XCTAssertNil(style.fontPostScriptName)
        XCTAssertTrue(style.usesSystemFont)
        let traits = PostcardOverlayTypography.measurementFontTraits(
            fontSize: 17,
            handwriting: style
        )
        XCTAssertFalse(traits.contains(.italic))
    }

    func testDefaultResolverReturnsAFontThatExistsOnMacOS() throws {
        let style = PostcardMoodTypographyResolver().resolve(mood: mood(0, "平静"))
        let font = try XCTUnwrap(
            PostcardOverlayTypography.measurementFont(fontSize: 17, handwriting: style)
        )

        XCTAssertGreaterThan(font.pointSize, 0)
        if let name = style.fontPostScriptName {
            XCTAssertEqual(font.fontName, name)
        }
    }

    func testDefaultFamiliesUsePromotedBundledFacesWithRealDescriptorWeights() throws {
        let resolver = PostcardMoodTypographyResolver()
        let styles = [
            resolver.resolve(mood: mood(0, "平静")),
            resolver.resolve(mood: mood(0, "好奇")),
            resolver.resolve(mood: mood(0, "思念")),
            resolver.resolve(mood: mood(0, "坚定")),
        ]
        let names = styles.compactMap(\.fontPostScriptName)

        XCTAssertEqual(names.count, styles.count)
        XCTAssertEqual(
            names,
            [
                "LXGWWenKaiLite-Medium",
                "LXGWWenKaiLite-Medium",
                "LXGWWenKaiLite-Regular",
                "LXGWWenKaiLite-Medium",
            ]
        )
        XCTAssertEqual(Set(names).count, 2)
        XCTAssertNotEqual(styles[0].lineSpacing, styles[1].lineSpacing)
        XCTAssertNotEqual(styles[0].sizeScale, styles[1].sizeScale)
        for (style, name) in zip(styles, names) {
            let font = CTFontCreateWithName(name as CFString, 17, nil)
            let traits = CTFontCopyTraits(font) as NSDictionary
            let actualWeight = try XCTUnwrap(traits[kCTFontWeightTrait] as? NSNumber).doubleValue
            XCTAssertEqual(CTFontCopyPostScriptName(font) as String, name)
            XCTAssertEqual(style.fontWeight, actualWeight, accuracy: 0.001)
            var characters = Array("猫旅风景心情".utf16)
            var glyphs = Array(repeating: CGGlyph(), count: characters.count)
            XCTAssertTrue(
                CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count),
                "\(name) must cover representative postcard Chinese"
            )
        }
    }

    func testFacePromotionDoesNotChangeFamilyScaleOrLeading() {
        let resolver = PostcardMoodTypographyResolver()
        let cases: [(Mood, PostcardHandwritingFamily, Double, Double)] = [
            (mood(0, "平静"), .serene, 1, 1.18),
            (mood(0, "好奇"), .playful, 1.06, 1.12),
            (mood(0, "思念"), .reflective, 0.95, 1.24),
            (mood(0, "坚定"), .bold, 1.03, 1.10),
        ]

        for (mood, family, scale, leading) in cases {
            let style = resolver.resolve(mood: mood)
            XCTAssertEqual(style.family, family)
            XCTAssertEqual(style.sizeScale, scale, accuracy: 0.001)
            XCTAssertEqual(style.lineSpacing, leading, accuracy: 0.001)
        }
    }

    func testDefaultResolverIsDeterministicUnderConcurrentCalls() async {
        let resolver = PostcardMoodTypographyResolver()
        let expected = resolver.resolve(mood: mood(0, "好奇"))
        let results = await withTaskGroup(of: PostcardHandwritingStyle.self) { group in
            for _ in 0..<64 {
                group.addTask {
                    resolver.resolve(mood: Mood(level: 0, label: "好奇", quote: "风景刚刚好。"))
                }
            }
            var values: [PostcardHandwritingStyle] = []
            for await value in group { values.append(value) }
            return values
        }

        XCTAssertEqual(results.count, 64)
        XCTAssertTrue(results.allSatisfy { $0 == expected })
    }

    func testFitMeasuresWithResolvedFontAndKeepsMinimumSizes() {
        let style = PostcardMoodTypographyResolver(fontLookup: { name, _ in
            name == "Kaiti SC"
                ? .init(postScriptName: "Helvetica", actualWeight: 0)
                : nil
        }).resolve(mood: mood(0, "平静"))

        XCTAssertEqual(
            PostcardOverlayTypography.measurementFont(fontSize: 17, handwriting: style)?.fontName,
            style.fontPostScriptName
        )

        let detail = PostcardOverlayTypography.fit(
            message: "湖光和晨风一起把旧码头点亮了。",
            region: .bottomLeading,
            profile: .detail,
            containerSize: CGSize(width: 520, height: 230),
            handwriting: style
        )
        let compact = PostcardOverlayTypography.fit(
            message: "湖光和晨风一起把旧码头点亮了。",
            region: .wideBottomLeading,
            profile: .compact,
            containerSize: CGSize(width: 340, height: 120),
            handwriting: style
        )

        XCTAssertGreaterThanOrEqual(detail.fontSize, 17)
        XCTAssertGreaterThanOrEqual(compact.fontSize, 12)
    }

    func testMeasurementUsesResolvedFaceWithMatchingActualWeight() throws {
        let style = PostcardMoodTypographyResolver(fontLookup: { name, _ in
            name == "HanziPen SC"
                ? .init(postScriptName: "Helvetica-Bold", actualWeight: 0.4)
                : nil
        }).resolve(mood: mood(2, "坚定"))
        let font = try XCTUnwrap(
            PostcardOverlayTypography.measurementFont(fontSize: 17, handwriting: style)
        )
        let traits = try XCTUnwrap(
            font.fontDescriptor.object(forKey: .traits)
                as? [NSFontDescriptor.TraitKey: Any]
        )
        let actualWeight = try XCTUnwrap(traits[.weight] as? NSNumber).doubleValue

        XCTAssertEqual(font.fontName, style.fontPostScriptName)
        XCTAssertEqual(actualWeight, style.fontWeight, accuracy: 0.001)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold))
    }

    func testResolvedFitPreservesExplicitLinesAndLegalMaximumMessage() {
        let style = resolverWithAllPreferredFonts().resolve(mood: mood(-1, "想念"))
        let explicitLines = PostcardOverlayTypography.fit(
            message: "第一行\n第二行",
            region: .middleTrailing,
            profile: .compact,
            containerSize: CGSize(width: 340, height: 120),
            handwriting: style
        )
        let legalMaximum = PostcardOverlayTypography.fit(
            message: String(repeating: "旅", count: 80),
            region: .wideBottomTrailing,
            profile: .compact,
            containerSize: CGSize(width: 676, height: 120),
            handwriting: style
        )

        XCTAssertEqual(explicitLines.requiredLineCount, 2)
        XCTAssertTrue(explicitLines.fitsVertically)
        XCTAssertLessThanOrEqual(legalMaximum.requiredLineCount, 2)
        XCTAssertTrue(legalMaximum.fitsVertically)
        XCTAssertGreaterThanOrEqual(legalMaximum.fontSize, 12)
    }

    private func mood(_ level: Int, _ label: String) -> Mood {
        Mood(level: level, label: label, quote: "风景刚刚好。")
    }

    private func resolverWithAllPreferredFonts() -> PostcardMoodTypographyResolver {
        PostcardMoodTypographyResolver(fontLookup: { name, weight in
            .init(
                postScriptName: name.replacingOccurrences(of: " ", with: ""),
                actualWeight: weight
            )
        })
    }
}
