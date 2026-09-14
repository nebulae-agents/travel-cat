import CoreText
import Foundation
import TravelCore
import os

public enum PostcardHandwritingFamily: String, CaseIterable, Equatable, Sendable {
    case serene
    case playful
    case reflective
    case bold
}

public struct PostcardHandwritingStyle: Equatable, Sendable {
    public let family: PostcardHandwritingFamily
    public let fontPostScriptName: String?
    public let fontWeight: Double
    public let sizeScale: Double
    public let lineSpacing: Double
    public let pawOpacity: Double

    public var usesSystemFont: Bool { fontPostScriptName == nil }

    public init(
        family: PostcardHandwritingFamily,
        fontPostScriptName: String?,
        fontWeight: Double,
        sizeScale: Double,
        lineSpacing: Double,
        pawOpacity: Double
    ) {
        self.family = family
        self.fontPostScriptName = fontPostScriptName
        self.fontWeight = min(max(fontWeight.isFinite ? fontWeight : 0, -1), 1)
        self.sizeScale = min(max(sizeScale.isFinite ? sizeScale : 1, 0.92), 1.08)
        self.lineSpacing = min(max(lineSpacing.isFinite ? lineSpacing : 1.2, 1.05), 1.35)
        self.pawOpacity = min(max(pawOpacity.isFinite ? pawOpacity : 0.62, 0.55), 0.70)
    }

    public static let sereneSystemFallback = PostcardHandwritingStyle(
        family: .serene,
        fontPostScriptName: nil,
        fontWeight: 0,
        sizeScale: 1,
        lineSpacing: 1.18,
        pawOpacity: 0.62
    )
}

struct PostcardResolvedFontFace: Equatable, Sendable {
    let postScriptName: String
    let actualWeight: Double
}

enum PostcardBundledFontRegistry {
    private enum State: Sendable {
        case unattempted
        case registered([String: PostcardResolvedFontFace])
        case failed
    }

    private static let state = OSAllocatedUnfairLock(initialState: State.unattempted)

    static func registerFonts() -> Bool {
        state.withLock { state in
            switch state {
            case .registered:
                return true
            case .failed:
                return false
            case .unattempted:
                break
            }

            let entries = [
                ("LXGWWenKaiLite-Light", "LXGWWenKaiLite-Light.ttf"),
                ("LXGWWenKaiLite-Regular", "LXGWWenKaiLite-Regular.ttf"),
                ("LXGWWenKaiLite-Medium", "LXGWWenKaiLite-Medium.ttf"),
            ]
            var faces: [String: PostcardResolvedFontFace] = [:]
            var registeredGraphicsFonts: [CGFont] = []
            for (postScriptName, file) in entries {
                guard let url = resourceURL(file),
                      let provider = CGDataProvider(url: url as CFURL),
                      let graphicsFont = CGFont(provider),
                      graphicsFont.postScriptName as String? == postScriptName else {
                    unregister(registeredGraphicsFonts)
                    state = .failed
                    return false
                }
                var error: Unmanaged<CFError>?
                let registered = CTFontManagerRegisterGraphicsFont(graphicsFont, &error)
                guard acceptsRegistrationResult(registered) else {
                    _ = error?.takeRetainedValue()
                    unregister(registeredGraphicsFonts)
                    state = .failed
                    return false
                }
                registeredGraphicsFonts.append(graphicsFont)
                let font = CTFontCreateWithName(postScriptName as CFString, 17, nil)
                guard CTFontCopyPostScriptName(font) as String == postScriptName,
                      coversPostcardChinese(font) else {
                    unregister(registeredGraphicsFonts)
                    state = .failed
                    return false
                }
                let traits = CTFontCopyTraits(font) as NSDictionary
                let weight = (traits[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0
                faces[postScriptName] = PostcardResolvedFontFace(
                    postScriptName: postScriptName,
                    actualWeight: weight
                )
            }
            state = .registered(faces)
            return true
        }
    }

    static func face(named postScriptName: String) -> PostcardResolvedFontFace? {
        guard registerFonts() else { return nil }
        return state.withLock { state in
            guard case let .registered(faces) = state else { return nil }
            return faces[postScriptName]
        }
    }

    static func acceptsRegistrationResult(_ registered: Bool) -> Bool {
        registered
    }

    private static func unregister(_ fonts: [CGFont]) {
        for font in fonts.reversed() {
            var error: Unmanaged<CFError>?
            _ = CTFontManagerUnregisterGraphicsFont(font, &error)
            if error != nil { _ = error?.takeRetainedValue() }
        }
    }

    private static func resourceURL(_ file: String) -> URL? {
        let url = URL(fileURLWithPath: file)
        return TravelUIResources.bundle.url(
            forResource: url.deletingPathExtension().lastPathComponent,
            withExtension: url.pathExtension,
            subdirectory: "Fonts"
        ) ?? TravelUIResources.bundle.url(
            forResource: url.deletingPathExtension().lastPathComponent,
            withExtension: url.pathExtension
        )
    }

    private static func coversPostcardChinese(_ font: CTFont) -> Bool {
        var characters = Array("猫旅风景心情".utf16)
        var glyphs = Array(repeating: CGGlyph(), count: characters.count)
        return CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count)
    }
}

public struct PostcardMoodTypographyResolver: Sendable {
    typealias FontLookup = @Sendable (String, Double) -> PostcardResolvedFontFace?

    private let fontLookup: FontLookup
    private let bundledFontLookup: FontLookup

    public init() {
        bundledFontLookup = { candidate, _ in
            PostcardBundledFontRegistry.face(named: candidate)
        }
        fontLookup = Self.coreTextFace(candidate:desiredWeight:)
    }

    init(fontLookup: @escaping FontLookup) {
        self.fontLookup = fontLookup
        bundledFontLookup = fontLookup
    }

    init(
        bundledFontLookup: @escaping FontLookup,
        fontLookup: @escaping FontLookup
    ) {
        self.bundledFontLookup = bundledFontLookup
        self.fontLookup = fontLookup
    }

    public func resolve(mood: Mood) -> PostcardHandwritingStyle {
        let family = refinedFamily(label: mood.label) ?? levelFamily(mood.level)
        let values = semanticValues(for: family)
        let resolvedFont = resolvedFont(for: family, desiredWeight: values.weight)
        return PostcardHandwritingStyle(
            family: family,
            fontPostScriptName: resolvedFont?.postScriptName,
            fontWeight: resolvedFont?.actualWeight ?? values.weight,
            sizeScale: values.scale,
            lineSpacing: values.lineSpacing,
            pawOpacity: values.pawOpacity
        )
    }

    private func levelFamily(_ level: Int) -> PostcardHandwritingFamily {
        switch level {
        case ...(-1): .reflective
        case 0: .serene
        case 1: .playful
        default: .bold
        }
    }

    private func refinedFamily(label: String) -> PostcardHandwritingFamily? {
        let normalized = label
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Locale(identifier: "en_US_POSIX"))

        let englishTokens = normalized.split {
            !$0.isLetter && !$0.isNumber
        }.map(String.init)
        for family in Self.keywordPriority {
            let hasChineseKeyword = Self.chineseKeywords[family, default: []]
                .contains { Self.containsUnnegatedChineseKeyword($0, in: normalized) }
            let hasEnglishKeyword = Self.englishKeywords[family, default: []]
                .contains(where: englishTokens.contains)
            if hasChineseKeyword || hasEnglishKeyword {
                return family
            }
        }
        return nil
    }

    private func resolvedFont(
        for family: PostcardHandwritingFamily,
        desiredWeight: Double
    ) -> (postScriptName: String, actualWeight: Double)? {
        let preferred = Self.preferredFontNames[family, default: []]
        let match = preferred.lazy.compactMap {
            lookupFace(named: $0, desiredWeight: desiredWeight)
        }.first ?? Self.sereneFontNames.lazy.compactMap {
            lookupFace(named: $0, desiredWeight: desiredWeight)
        }.first
        return match.map { ($0.postScriptName, $0.actualWeight) }
    }

    private func lookupFace(
        named candidate: String,
        desiredWeight: Double
    ) -> PostcardResolvedFontFace? {
        if candidate.hasPrefix("LXGWWenKaiLite-") {
            return bundledFontLookup(candidate, desiredWeight)
        }
        return fontLookup(candidate, desiredWeight)
    }

    private static func coreTextFace(
        candidate: String,
        desiredWeight: Double
    ) -> PostcardResolvedFontFace? {
        let baseFont = CTFontCreateWithName(candidate as CFString, 17, nil)
        guard CTFontCopyPostScriptName(baseFont) as String == candidate,
              coversPostcardChinese(baseFont) else { return nil }
        let font: CTFont
        if desiredWeight >= 0.39 {
            font = CTFontCreateCopyWithSymbolicTraits(
                baseFont,
                17,
                nil,
                .boldTrait,
                .boldTrait
            ) ?? baseFont
        } else if CTFontGetSymbolicTraits(baseFont).contains(.boldTrait) {
            font = CTFontCreateCopyWithSymbolicTraits(
                baseFont,
                17,
                nil,
                [],
                .boldTrait
            ) ?? baseFont
        } else {
            font = baseFont
        }
        let traits = CTFontCopyTraits(font) as NSDictionary
        let actualWeight = (traits[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0
        return PostcardResolvedFontFace(
            postScriptName: CTFontCopyPostScriptName(font) as String,
            actualWeight: actualWeight
        )
    }

    private func semanticValues(
        for family: PostcardHandwritingFamily
    ) -> (weight: Double, scale: Double, lineSpacing: Double, pawOpacity: Double) {
        switch family {
        case .serene: (0, 1, 1.18, 0.62)
        case .playful: (0.23, 1.06, 1.12, 0.68)
        case .reflective: (-0.10, 0.95, 1.24, 0.56)
        case .bold: (0.40, 1.03, 1.10, 0.70)
        }
    }

    private static let sereneFontNames = [
        "LXGWWenKaiLite-Medium",
        "Kaiti SC",
        "STKaiti",
        "KaiTi",
        "STSongti-SC-Regular",
        "STSong",
    ]

    private static let reflectiveFontNames = [
        "LXGWWenKaiLite-Regular",
        "Kaiti SC",
        "STKaiti",
        "KaiTi",
        "STSongti-SC-Light",
        "STSongti-SC-Regular",
        "STSong",
    ]

    private static let preferredFontNames: [PostcardHandwritingFamily: [String]] = [
        .serene: sereneFontNames,
        .reflective: reflectiveFontNames,
        .playful: [
            "LXGWWenKaiLite-Medium",
            "HanziPen SC",
            "Xingkai SC",
            "HiraginoSansGB-W3",
            "PingFangSC-Regular",
        ],
        .bold: [
            "LXGWWenKaiLite-Medium",
            "HanziPen SC",
            "Xingkai SC",
            "PingFangSC-Semibold",
            "HiraginoSansGB-W6",
        ],
    ]

    // When a generated label contains several emotions, the more expressive
    // signal wins deterministically. English matches whole tokens so words
    // such as "unhappy" never accidentally match "happy".
    private static let keywordPriority: [PostcardHandwritingFamily] = [
        .bold, .reflective, .playful, .serene,
    ]

    private static let chineseKeywords: [PostcardHandwritingFamily: [String]] = [
        .serene: [
            "平静", "安静", "安定", "治愈", "松弛", "满足", "舒然",
        ],
        .playful: [
            "开心", "快乐", "轻快", "好奇", "俏皮", "雀跃", "兴奋",
        ],
        .reflective: [
            "疲惫", "思念", "想念", "想家", "孤独", "低落", "怀念", "忧郁", "沉思",
        ],
        .bold: [
            "惊讶", "紧张", "坚定", "决心", "勇敢", "期待", "激动",
        ],
    ]

    private static let englishKeywords: [PostcardHandwritingFamily: [String]] = [
        .serene: ["serene", "calm", "peaceful", "relaxed", "content"],
        .playful: [
            "happy", "joyful", "playful", "curious", "curiosity", "cheerful", "excited",
        ],
        .reflective: [
            "tired", "lonely", "wistful", "reflective", "melancholy", "homesick",
        ],
        .bold: [
            "tense", "surprised", "determined", "nervous", "bold", "adventurous",
        ],
    ]

    private static func coversPostcardChinese(_ font: CTFont) -> Bool {
        var characters = Array("猫旅风景心情".utf16)
        var glyphs = Array(repeating: CGGlyph(), count: characters.count)
        return CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count)
    }

    private static func containsUnnegatedChineseKeyword(
        _ keyword: String,
        in label: String
    ) -> Bool {
        var searchStart = label.startIndex
        while let range = label.range(of: keyword, range: searchStart..<label.endIndex) {
            let prefixStart = label.index(range.lowerBound, offsetBy: -6, limitedBy: label.startIndex)
                ?? label.startIndex
            let prefix = String(label[prefixStart..<range.lowerBound])
            if !chineseNegationPrefixes.contains(where: prefix.hasSuffix) {
                return true
            }
            searchStart = range.upperBound
        }
        return false
    }

    private static let chineseNegationPrefixes = [
        "没有特别", "没有那么", "没有很", "没有太", "不怎么", "不那么", "不算",
        "并不是", "并不", "并非", "不是", "不太", "不再",
        "没有", "不", "没", "未", "无", "非", "别",
    ]
}
