import Foundation

public enum PostcardSceneInkFamily: String, CaseIterable, Equatable, Sendable {
    case lakeBlue
    case warmEarth
    case forestGreen
    case neutral
}

public struct PostcardInkColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = Self.unit(red)
        self.green = Self.unit(green)
        self.blue = Self.unit(blue)
    }

    public var relativeLuminance: Double {
        PostcardTextContrast.relativeLuminance(red: red, green: green, blue: blue)
    }

    private static func unit(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

public struct PostcardInkStyle: Equatable, Sendable {
    public let foreground: PostcardInkColor
    public let wash: PostcardInkColor
    public let washOpacity: Double
    public let shadow: PostcardInkColor
    public let shadowOpacity: Double
    public let shadowRadius: Double
    public let pawOpacity: Double
    public let sceneFamily: PostcardSceneInkFamily
    public let minimumContrastRatio: Double

    public var usesLightText: Bool { foreground.relativeLuminance > 0.5 }

    public init(
        foreground: PostcardInkColor,
        wash: PostcardInkColor,
        washOpacity: Double,
        shadow: PostcardInkColor,
        shadowOpacity: Double,
        shadowRadius: Double,
        pawOpacity: Double,
        sceneFamily: PostcardSceneInkFamily,
        minimumContrastRatio: Double
    ) {
        self.foreground = foreground
        self.wash = wash
        self.washOpacity = Self.bounded(washOpacity, upper: 0.82)
        self.shadow = shadow
        self.shadowOpacity = Self.bounded(shadowOpacity, upper: 0.72)
        self.shadowRadius = Self.bounded(shadowRadius, upper: 8)
        self.pawOpacity = min(max(pawOpacity.isFinite ? pawOpacity : 0.74, 0.68), 0.82)
        self.sceneFamily = sceneFamily
        self.minimumContrastRatio = max(minimumContrastRatio.isFinite ? minimumContrastRatio : 0, 0)
    }

    private static func bounded(_ value: Double, upper: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), upper)
    }
}

public struct PostcardInkResolver: Sendable {
    private init() {}

    private struct Candidate {
        let foreground: PostcardInkColor
        let wash: PostcardInkColor
        let opacity: Double
        let minimumContrast: Double
    }

    public static func resolve(
        sample: PostcardPixelSample,
        backgroundSamples: [PostcardPixelSample],
        colorVariance: Double,
        isUnknown: Bool
    ) -> PostcardInkStyle {
        if isUnknown { return unknownStyle }

        let backgrounds = backgroundSamples.isEmpty ? [sample] : backgroundSamples
        let luminances = backgrounds.map(actualLuminance)
        let lower = luminances.min() ?? actualLuminance(sample)
        let upper = luminances.max() ?? actualLuminance(sample)
        let family = sceneFamily(for: sample)
        let palette = palette(for: family)
        let dark = contrastCandidate(foreground: palette.dark, backgrounds: backgrounds)
        let light = contrastCandidate(foreground: palette.light, backgrounds: backgrounds)
        let variance = colorVariance.isFinite ? max(colorVariance, 0) : 1
        let isClean = upper - lower <= 0.10 && variance <= 0.01
        let chosen = isClean
            ? minimalWash(dark: dark, light: light)
            : choose(dark: dark, light: light, midpoint: (lower + upper) / 2)
        let isComplex = upper - lower > 0.24 || variance > 0.035
        let hasWash = chosen.opacity > 0.005
        let shadowOpacity = isComplex ? (hasWash ? 0.32 : 0.24) : (hasWash ? 0.18 : 0.10)

        return PostcardInkStyle(
            foreground: chosen.foreground,
            wash: chosen.wash,
            washOpacity: chosen.opacity,
            shadow: chosen.foreground.relativeLuminance > 0.5 ? .init(red: 0.04, green: 0.035, blue: 0.03) : .init(red: 0.98, green: 0.95, blue: 0.88),
            shadowOpacity: shadowOpacity,
            shadowRadius: isComplex ? 2.4 : 1.2,
            pawOpacity: palette.pawOpacity,
            sceneFamily: family,
            minimumContrastRatio: chosen.minimumContrast
        )
    }

    static let unknownStyle = PostcardInkStyle(
        foreground: .init(red: 1, green: 1, blue: 1),
        wash: .init(red: 0, green: 0, blue: 0),
        washOpacity: 0.82,
        shadow: .init(red: 0, green: 0, blue: 0),
        shadowOpacity: 0.55,
        shadowRadius: 2,
        pawOpacity: 0.78,
        sceneFamily: .neutral,
        minimumContrastRatio: PostcardTextContrast.minimumContrastRatio
    )

    private static func sceneFamily(for sample: PostcardPixelSample) -> PostcardSceneInkFamily {
        let red = sample.red
        let green = sample.green
        let blue = sample.blue
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let chroma = maximum - minimum
        guard chroma >= 0.12 else { return .neutral }
        let hue: Double
        if maximum == red {
            hue = 60 * (((green - blue) / chroma).truncatingRemainder(dividingBy: 6))
        } else if maximum == green {
            hue = 60 * ((blue - red) / chroma + 2)
        } else {
            hue = 60 * ((red - green) / chroma + 4)
        }
        let normalizedHue = hue < 0 ? hue + 360 : hue
        switch normalizedHue {
        case 75..<165: return .forestGreen
        case 165..<285: return .lakeBlue
        default: return .warmEarth
        }
    }

    private static func palette(
        for family: PostcardSceneInkFamily
    ) -> (dark: PostcardInkColor, light: PostcardInkColor, pawOpacity: Double) {
        switch family {
        case .lakeBlue:
            return (
                .init(red: 0.06, green: 0.165, blue: 0.255),
                .init(red: 0.80, green: 0.90, blue: 0.96),
                0.76
            )
        case .warmEarth:
            return (
                .init(red: 0.28, green: 0.11, blue: 0.07),
                .init(red: 0.98, green: 0.87, blue: 0.75),
                0.82
            )
        case .forestGreen:
            return (
                .init(red: 0.05, green: 0.18, blue: 0.085),
                .init(red: 0.95, green: 0.86, blue: 0.70),
                0.74
            )
        case .neutral:
            return (
                .init(red: 0.12, green: 0.115, blue: 0.11),
                .init(red: 0.96, green: 0.92, blue: 0.84),
                0.78
            )
        }
    }

    private static func contrastCandidate(
        foreground: PostcardInkColor,
        backgrounds: [PostcardPixelSample]
    ) -> Candidate {
        let usesLightText = foreground.relativeLuminance > 0.5
        let foregroundLuminance = quantizedLuminance(
            foreground,
            direction: usesLightText ? .down : .up
        )
        let wash = usesLightText
            ? PostcardInkColor(red: 0.025, green: 0.022, blue: 0.02)
            : PostcardInkColor(red: 0.98, green: 0.96, blue: 0.91)
        let opacity = minimumWashOpacity(
            foregroundLuminance: foregroundLuminance,
            wash: wash,
            backgrounds: backgrounds
        )
        let endpointContrasts = backgrounds.map { background in
            contrastRatio(
                foregroundLuminance: foregroundLuminance,
                background: background,
                wash: wash,
                opacity: opacity
            )
        }
        return Candidate(
            foreground: foreground,
            wash: wash,
            opacity: opacity,
            minimumContrast: endpointContrasts.min() ?? 0
        )
    }

    private static func minimumWashOpacity(
        foregroundLuminance: Double,
        wash: PostcardInkColor,
        backgrounds: [PostcardPixelSample]
    ) -> Double {
        let minimum = PostcardTextContrast.minimumContrastRatio
        let maximumOpacity = 0.82
        let maximumStep = Int(floor(maximumOpacity * 255))
        for step in 0...maximumStep {
            let opacity = Double(step) / 255
            let passesEverySample = backgrounds.allSatisfy {
                contrastRatio(
                    foregroundLuminance: foregroundLuminance,
                    background: $0,
                    wash: wash,
                    opacity: opacity
                ) >= minimum
            }
            if passesEverySample { return opacity }
        }
        return maximumOpacity
    }

    private static func contrastRatio(
        foregroundLuminance: Double,
        background: PostcardPixelSample,
        wash: PostcardInkColor,
        opacity: Double
    ) -> Double {
        let composited = PostcardInkColor(
            red: background.red * (1 - opacity) + wash.red * opacity,
            green: background.green * (1 - opacity) + wash.green * opacity,
            blue: background.blue * (1 - opacity) + wash.blue * opacity
        )
        let usesLightText = foregroundLuminance > 0.5
        return PostcardTextContrast.contrastRatio(
            foregroundLuminance: foregroundLuminance,
            backgroundLuminance: quantizedLuminance(
                composited,
                direction: usesLightText ? .up : .down
            )
        )
    }

    private enum QuantizationDirection {
        case down
        case up
    }

    private static func quantizedLuminance(
        _ color: PostcardInkColor,
        direction: QuantizationDirection
    ) -> Double {
        PostcardTextContrast.relativeLuminance(
            red: quantize(color.red, direction: direction),
            green: quantize(color.green, direction: direction),
            blue: quantize(color.blue, direction: direction)
        )
    }

    private static func quantize(
        _ component: Double,
        direction: QuantizationDirection
    ) -> Double {
        let scaled = component * 255
        switch direction {
        case .down: return floor(scaled) / 255
        case .up: return ceil(scaled) / 255
        }
    }

    private static func actualLuminance(_ sample: PostcardPixelSample) -> Double {
        PostcardTextContrast.relativeLuminance(
            red: sample.red,
            green: sample.green,
            blue: sample.blue
        )
    }

    private static func choose(dark: Candidate, light: Candidate, midpoint: Double) -> Candidate {
        if midpoint <= 0.30 { return light }
        if midpoint >= 0.55 { return dark }
        if abs(dark.opacity - light.opacity) < 0.000_001 {
            return midpoint >= 0.5 ? dark : light
        }
        return dark.opacity < light.opacity ? dark : light
    }

    private static func minimalWash(dark: Candidate, light: Candidate) -> Candidate {
        if abs(dark.opacity - light.opacity) < 0.000_001 {
            return dark
        }
        return dark.opacity < light.opacity ? dark : light
    }

}

public struct PostcardLocationInkStyle: Equatable, Sendable {
    public let foreground: PostcardInkColor
    public let shadow: PostcardInkColor
    public let shadowOpacity: Double
    public let opacity: Double
    public let minimumContrastRatio: Double
    public let usesContrastEdgeFallback: Bool

    public init(
        foreground: PostcardInkColor,
        shadow: PostcardInkColor,
        shadowOpacity: Double,
        opacity: Double,
        minimumContrastRatio: Double,
        usesContrastEdgeFallback: Bool = false
    ) {
        self.foreground = foreground
        self.shadow = shadow
        self.shadowOpacity = min(max(shadowOpacity.isFinite ? shadowOpacity : 0, 0), 0.72)
        self.opacity = min(max(opacity.isFinite ? opacity : 0, 0), 1)
        self.minimumContrastRatio = max(
            minimumContrastRatio.isFinite ? minimumContrastRatio : 0,
            0
        )
        self.usesContrastEdgeFallback = usesContrastEdgeFallback
    }
}

struct PostcardLocationContrastRatios {
    let compactDark: Double
    let compactLight: Double
    let detailDark: Double
    let detailLight: Double
}

enum PostcardLocationContrast {
    static let darkForeground = PostcardInkColor(red: 0.02, green: 0.02, blue: 0.02)
    static let lightForeground = PostcardInkColor(red: 1, green: 1, blue: 1)

    static func opacity(profile: PostcardOverlayProfile) -> Double {
        profile == .detail ? 0.78 : 0.74
    }

    static func ratio(
        background: PostcardColorSample,
        foreground: PostcardInkColor,
        profile: PostcardOverlayProfile
    ) -> Double {
        let ratios = ratios(background: background)
        let usesLightForeground = foreground.relativeLuminance > 0.5
        return switch (profile, usesLightForeground) {
        case (.compact, false): ratios.compactDark
        case (.compact, true): ratios.compactLight
        case (.detail, false): ratios.detailDark
        case (.detail, true): ratios.detailLight
        }
    }

    static func ratios(background: PostcardColorSample) -> PostcardLocationContrastRatios {
        let backgroundBytes = (
            quantizedByte(background.red),
            quantizedByte(background.green),
            quantizedByte(background.blue)
        )
        let backgroundLuminance = luminance(backgroundBytes)
        return PostcardLocationContrastRatios(
            compactDark: ratio(
                background: background,
                backgroundLuminance: backgroundLuminance,
                foreground: darkForeground,
                profile: .compact
            ),
            compactLight: ratio(
                background: background,
                backgroundLuminance: backgroundLuminance,
                foreground: lightForeground,
                profile: .compact
            ),
            detailDark: ratio(
                background: background,
                backgroundLuminance: backgroundLuminance,
                foreground: darkForeground,
                profile: .detail
            ),
            detailLight: ratio(
                background: background,
                backgroundLuminance: backgroundLuminance,
                foreground: lightForeground,
                profile: .detail
            )
        )
    }

    private static func ratio(
        background: PostcardColorSample,
        backgroundLuminance: Double,
        foreground: PostcardInkColor,
        profile: PostcardOverlayProfile
    ) -> Double {
        let opacity = opacity(profile: profile)
        let foregroundBytes = (
            quantizedByte(foreground.red * opacity + background.red * (1 - opacity)),
            quantizedByte(foreground.green * opacity + background.green * (1 - opacity)),
            quantizedByte(foreground.blue * opacity + background.blue * (1 - opacity))
        )
        return PostcardTextContrast.contrastRatio(
            foregroundLuminance: luminance(foregroundBytes),
            backgroundLuminance: backgroundLuminance
        )
    }

    private static func quantizedByte(_ component: Double) -> Int {
        Int((min(max(component.isFinite ? component : 0, 0), 1) * 255).rounded())
    }

    private static func luminance(_ components: (Int, Int, Int)) -> Double {
        0.2126 * linearized8BitComponent[components.0]
            + 0.7152 * linearized8BitComponent[components.1]
            + 0.0722 * linearized8BitComponent[components.2]
    }

    private static let linearized8BitComponent: [Double] = (0...255).map { value in
        let component = Double(value) / 255
        return component <= 0.04045
            ? component / 12.92
            : pow((component + 0.055) / 1.055, 2.4)
    }
}

public struct PostcardLocationContrastWitnesses: Equatable, Sendable {
    public let compactDarkBackground: PostcardColorSample
    public let compactLightBackground: PostcardColorSample
    public let detailDarkBackground: PostcardColorSample
    public let detailLightBackground: PostcardColorSample
    /// Conservative source evidence retained independently of contrast-witness compression.
    public let maximumSourceChroma: Double
    let hasSourceChromaticFringeHazard: Bool
    public let isFailClosed: Bool

    public init(backgroundSamples: [PostcardColorSample]) {
        let backgrounds = backgroundSamples.isEmpty ? Self.failClosedBackgrounds : backgroundSamples
        self.init(
            compactDarkBackground: Self.worstBackground(
                in: backgrounds,
                profile: .compact,
                foreground: PostcardLocationContrast.darkForeground
            ),
            compactLightBackground: Self.worstBackground(
                in: backgrounds,
                profile: .compact,
                foreground: PostcardLocationContrast.lightForeground
            ),
            detailDarkBackground: Self.worstBackground(
                in: backgrounds,
                profile: .detail,
                foreground: PostcardLocationContrast.darkForeground
            ),
            detailLightBackground: Self.worstBackground(
                in: backgrounds,
                profile: .detail,
                foreground: PostcardLocationContrast.lightForeground
            ),
            maximumSourceChroma: backgrounds.map(Self.chroma).max() ?? 1,
            hasSourceChromaticFringeHazard: backgrounds.contains(where: Self.isChromaticFringeHazard),
            isFailClosed: backgroundSamples.isEmpty
        )
    }

    public var allBackgrounds: [PostcardColorSample] {
        [
            compactDarkBackground,
            compactLightBackground,
            detailDarkBackground,
            detailLightBackground,
        ]
    }

    static func combining(_ witnesses: [Self]) -> Self {
        guard !witnesses.isEmpty else { return Self(backgroundSamples: []) }
        return witnesses.dropFirst().reduce(witnesses[0]) { result, next in
            Self(
                compactDarkBackground: worseBackground(
                    result.compactDarkBackground,
                    next.compactDarkBackground,
                    profile: .compact,
                    foreground: PostcardLocationContrast.darkForeground
                ),
                compactLightBackground: worseBackground(
                    result.compactLightBackground,
                    next.compactLightBackground,
                    profile: .compact,
                    foreground: PostcardLocationContrast.lightForeground
                ),
                detailDarkBackground: worseBackground(
                    result.detailDarkBackground,
                    next.detailDarkBackground,
                    profile: .detail,
                    foreground: PostcardLocationContrast.darkForeground
                ),
                detailLightBackground: worseBackground(
                    result.detailLightBackground,
                    next.detailLightBackground,
                    profile: .detail,
                    foreground: PostcardLocationContrast.lightForeground
                ),
                maximumSourceChroma: max(result.maximumSourceChroma, next.maximumSourceChroma),
                hasSourceChromaticFringeHazard: result.hasSourceChromaticFringeHazard
                    || next.hasSourceChromaticFringeHazard,
                isFailClosed: result.isFailClosed || next.isFailClosed
            )
        }
    }

    func including(_ background: PostcardColorSample) -> Self {
        Self(
            compactDarkBackground: Self.worseBackground(
                compactDarkBackground,
                background,
                profile: .compact,
                foreground: PostcardLocationContrast.darkForeground
            ),
            compactLightBackground: Self.worseBackground(
                compactLightBackground,
                background,
                profile: .compact,
                foreground: PostcardLocationContrast.lightForeground
            ),
            detailDarkBackground: Self.worseBackground(
                detailDarkBackground,
                background,
                profile: .detail,
                foreground: PostcardLocationContrast.darkForeground
            ),
            detailLightBackground: Self.worseBackground(
                detailLightBackground,
                background,
                profile: .detail,
                foreground: PostcardLocationContrast.lightForeground
            ),
            maximumSourceChroma: max(maximumSourceChroma, Self.chroma(background)),
            hasSourceChromaticFringeHazard: hasSourceChromaticFringeHazard
                || Self.isChromaticFringeHazard(background),
            isFailClosed: isFailClosed
        )
    }

    fileprivate func background(
        profile: PostcardOverlayProfile,
        foreground: PostcardInkColor
    ) -> PostcardColorSample {
        let usesLightForeground = foreground.relativeLuminance > 0.5
        return switch (profile, usesLightForeground) {
        case (.compact, false): compactDarkBackground
        case (.compact, true): compactLightBackground
        case (.detail, false): detailDarkBackground
        case (.detail, true): detailLightBackground
        }
    }

    init(
        compactDarkBackground: PostcardColorSample,
        compactLightBackground: PostcardColorSample,
        detailDarkBackground: PostcardColorSample,
        detailLightBackground: PostcardColorSample,
        maximumSourceChroma: Double,
        hasSourceChromaticFringeHazard: Bool,
        isFailClosed: Bool = false
    ) {
        self.compactDarkBackground = compactDarkBackground
        self.compactLightBackground = compactLightBackground
        self.detailDarkBackground = detailDarkBackground
        self.detailLightBackground = detailLightBackground
        self.maximumSourceChroma = min(max(maximumSourceChroma.isFinite ? maximumSourceChroma : 1, 0), 1)
        self.hasSourceChromaticFringeHazard = hasSourceChromaticFringeHazard
        self.isFailClosed = isFailClosed
    }

    private static func chroma(_ background: PostcardColorSample) -> Double {
        max(background.red, background.green, background.blue)
            - min(background.red, background.green, background.blue)
    }

    static func isChromaticFringeHazard(_ background: PostcardColorSample) -> Bool {
        let components = [background.red, background.green, background.blue].sorted()
        return components[2] - components[0] > 0.95 && components[1] > 0.50
    }

    private static func worstBackground(
        in backgrounds: [PostcardColorSample],
        profile: PostcardOverlayProfile,
        foreground: PostcardInkColor
    ) -> PostcardColorSample {
        backgrounds.dropFirst().reduce(backgrounds.first ?? failClosedBackgrounds[0]) {
            worseBackground($0, $1, profile: profile, foreground: foreground)
        }
    }

    private static func worseBackground(
        _ lhs: PostcardColorSample,
        _ rhs: PostcardColorSample,
        profile: PostcardOverlayProfile,
        foreground: PostcardInkColor
    ) -> PostcardColorSample {
        PostcardLocationContrast.ratio(
            background: rhs,
            foreground: foreground,
            profile: profile
        ) < PostcardLocationContrast.ratio(
            background: lhs,
            foreground: foreground,
            profile: profile
        ) ? rhs : lhs
    }

    private static let failClosedBackgrounds = [
        PostcardColorSample(red: 0, green: 0, blue: 0),
        PostcardColorSample(red: 1, green: 1, blue: 1),
    ]
}

public enum PostcardLocationInkResolver {
    private struct Candidate {
        let foreground: PostcardInkColor
        let minimumContrastRatio: Double
    }

    public static func resolve(
        backgroundSamples: [PostcardPixelSample],
        profile: PostcardOverlayProfile
    ) -> PostcardLocationInkStyle? {
        guard !backgroundSamples.isEmpty else { return nil }
        return resolve(
            backgroundWitnesses: .combining(backgroundSamples.map(\.locationContrastWitnesses)),
            profile: profile
        )
    }

    public static func resolve(
        backgroundSamples: [PostcardColorSample],
        profile: PostcardOverlayProfile
    ) -> PostcardLocationInkStyle? {
        guard !backgroundSamples.isEmpty else { return nil }
        return resolve(
            backgroundWitnesses: PostcardLocationContrastWitnesses(
                backgroundSamples: backgroundSamples
            ),
            profile: profile
        )
    }

    public static func resolve(
        backgroundWitnesses: PostcardLocationContrastWitnesses,
        profile: PostcardOverlayProfile
    ) -> PostcardLocationInkStyle? {
        guard !backgroundWitnesses.isFailClosed else { return nil }
        let opacity = PostcardLocationContrast.opacity(profile: profile)
        let dark = candidate(
            foreground: PostcardLocationContrast.darkForeground,
            backgroundWitnesses: backgroundWitnesses,
            profile: profile
        )
        let light = candidate(
            foreground: PostcardLocationContrast.lightForeground,
            backgroundWitnesses: backgroundWitnesses,
            profile: profile
        )
        let chosen = dark.minimumContrastRatio >= light.minimumContrastRatio ? dark : light
        let usesLightText = chosen.foreground.relativeLuminance > 0.5
        let shadow = usesLightText
            ? PostcardInkColor(red: 0, green: 0, blue: 0)
            : PostcardInkColor(red: 1, green: 1, blue: 1)
        let usesEdgeFallback = chosen.minimumContrastRatio < PostcardTextContrast.minimumContrastRatio
        // A black/white edge is dependable on natural low-to-moderate chroma scenery,
        // but produces unstable color fringes on saturated complementary witnesses.
        if usesEdgeFallback,
           backgroundWitnesses.maximumSourceChroma > 0.99
            || backgroundWitnesses.hasSourceChromaticFringeHazard {
            return nil
        }
        return PostcardLocationInkStyle(
            foreground: chosen.foreground,
            shadow: shadow,
            shadowOpacity: usesEdgeFallback ? 0.68 : 0.38,
            opacity: opacity,
            minimumContrastRatio: chosen.minimumContrastRatio,
            usesContrastEdgeFallback: usesEdgeFallback
        )
    }

    private static func candidate(
        foreground: PostcardInkColor,
        backgroundWitnesses: PostcardLocationContrastWitnesses,
        profile: PostcardOverlayProfile
    ) -> Candidate {
        let background = backgroundWitnesses.background(
            profile: profile,
            foreground: foreground
        )
        return Candidate(
            foreground: foreground,
            minimumContrastRatio: PostcardLocationContrast.ratio(
                background: background,
                foreground: foreground,
                profile: profile
            )
        )
    }
}
