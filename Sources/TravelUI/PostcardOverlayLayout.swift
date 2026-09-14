import CoreGraphics
import CoreText
import Foundation
import AppKit
import TravelCore

public enum PostcardOverlayProfile: Sendable {
    case detail
    case compact
}

public enum PostcardOverlayRegion: CaseIterable, Equatable, Sendable {
    case topLeading
    case topTrailing
    case middleLeading
    case middleTrailing
    case bottomLeading
    case bottomTrailing
    case wideTopLeading
    case wideMiddleLeading
    case wideMiddleTrailing
    case wideBottomLeading
    case wideBottomTrailing
    case locationBottomLeading
    case locationBottomTrailing
    case scenicTopLeading
    case columnLeading
    case columnTrailing

    var messageLineLimit: Int {
        self == .columnLeading || self == .columnTrailing ? 3 : 2
    }
}

public enum PostcardOverlayGeometry {
    public static func locationLineLimit(profile: PostcardOverlayProfile) -> Int {
        2
    }

    public static func rect(
        for region: PostcardOverlayRegion,
        profile: PostcardOverlayProfile
    ) -> CGRect {
        switch region {
        case .topLeading:
            return profile == .compact
                ? CGRect(x: 0.04, y: 0.05, width: 0.58, height: 0.30)
                : CGRect(x: 0.04, y: 0.05, width: 0.40, height: 0.22)
        case .topTrailing:
            return profile == .compact
                ? CGRect(x: 0.48, y: 0.05, width: 0.48, height: 0.25)
                : CGRect(x: 0.56, y: 0.05, width: 0.40, height: 0.22)
        case .middleLeading:
            return profile == .compact
                ? CGRect(x: 0.04, y: 0.40, width: 0.48, height: 0.32)
                : CGRect(x: 0.05, y: 0.40, width: 0.42, height: 0.29)
        case .middleTrailing:
            return profile == .compact
                ? CGRect(x: 0.48, y: 0.40, width: 0.48, height: 0.32)
                : CGRect(x: 0.53, y: 0.40, width: 0.42, height: 0.29)
        case .bottomLeading:
            return profile == .compact
                ? CGRect(x: 0.04, y: 0.58, width: 0.48, height: 0.37)
                : CGRect(x: 0.05, y: 0.66, width: 0.42, height: 0.29)
        case .bottomTrailing:
            return profile == .compact
                ? CGRect(x: 0.48, y: 0.58, width: 0.48, height: 0.37)
                : CGRect(x: 0.53, y: 0.66, width: 0.42, height: 0.29)
        case .wideTopLeading:
            return CGRect(
                x: 0.04,
                y: 0.05,
                width: 0.76,
                height: profile == .compact ? 0.38 : 0.30
            )
        case .wideMiddleLeading:
            return CGRect(x: 0.04, y: profile == .compact ? 0.35 : 0.30, width: 0.76, height: profile == .compact ? 0.37 : 0.30)
        case .wideMiddleTrailing:
            return CGRect(x: 0.20, y: profile == .compact ? 0.35 : 0.30, width: 0.76, height: profile == .compact ? 0.37 : 0.30)
        case .wideBottomLeading:
            return CGRect(x: 0.04, y: profile == .compact ? 0.58 : 0.66, width: 0.76, height: profile == .compact ? 0.37 : 0.29)
        case .wideBottomTrailing:
            return CGRect(x: 0.20, y: profile == .compact ? 0.58 : 0.66, width: 0.76, height: profile == .compact ? 0.37 : 0.29)
        case .locationBottomLeading:
            return CGRect(x: 0.04, y: profile == .compact ? 0.72 : 0.73, width: profile == .compact ? 0.58 : 0.40, height: profile == .compact ? 0.27 : 0.22)
        case .locationBottomTrailing:
            return CGRect(x: profile == .compact ? 0.48 : 0.56, y: profile == .compact ? 0.72 : 0.73, width: profile == .compact ? 0.48 : 0.40, height: profile == .compact ? 0.27 : 0.22)
        case .scenicTopLeading:
            return CGRect(x: 0.02, y: 0.02, width: profile == .compact ? 0.34 : 0.40, height: profile == .compact ? 0.31 : 0.24)
        case .columnLeading:
            return CGRect(x: 0.03, y: 0.37, width: 0.38, height: 0.58)
        case .columnTrailing:
            return CGRect(x: 0.59, y: 0.37, width: 0.38, height: 0.58)
        }
    }
}

public enum PostcardOverlayPresentation {
    public static func canvasFrame(containerSize: CGSize) -> CGRect {
        CGRect(origin: .zero, size: containerSize)
    }

    public static func frame(
        for region: PostcardOverlayRegion,
        profile: PostcardOverlayProfile,
        containerSize: CGSize
    ) -> CGRect {
        let rect = PostcardOverlayGeometry.rect(for: region, profile: profile)
        return CGRect(
            x: rect.minX * containerSize.width,
            y: rect.minY * containerSize.height,
            width: rect.width * containerSize.width,
            height: rect.height * containerSize.height
        )
    }
}

public struct PostcardTypographyFit: Equatable, Sendable {
    public let fontSize: CGFloat
    public let requiredLineCount: Int
    public let fitsVertically: Bool
}

public struct PostcardLocationTypographyFit: Equatable, Sendable {
    public let minimumScaleFactor: CGFloat
    public let requiredLineCount: Int
    public let fitsVertically: Bool
}

public enum PostcardOverlayTypography {
    static func messagePadding(profile: PostcardOverlayProfile, frame: CGRect) -> CGFloat {
        profile == .detail && frame.height >= 64 ? 10 : 4
    }

    static func measurementFontTraits(
        fontSize: CGFloat,
        handwriting: PostcardHandwritingStyle
    ) -> NSFontDescriptor.SymbolicTraits {
        measurementFont(fontSize: fontSize, handwriting: handwriting)?.fontDescriptor.symbolicTraits ?? []
    }

    static func locationMeasurementFontTraits(fontSize: CGFloat) -> NSFontDescriptor.SymbolicTraits {
        locationMeasurementFont(fontSize: fontSize).fontDescriptor.symbolicTraits
    }

    static func renderedLineHeight(
        fontSize: CGFloat,
        handwriting: PostcardHandwritingStyle
    ) -> CGFloat {
        guard let font = measurementFont(fontSize: fontSize, handwriting: handwriting) else {
            return max(fontSize * CGFloat(handwriting.lineSpacing), fontSize)
        }
        let natural = font.ascender - font.descender + font.leading
        return max(fontSize * CGFloat(handwriting.lineSpacing), natural)
    }

    static func measurementFont(
        fontSize: CGFloat,
        handwriting: PostcardHandwritingStyle
    ) -> NSFont? {
        let safeSize = max(fontSize.isFinite ? fontSize : 1, 1)
        if let name = handwriting.fontPostScriptName,
           let font = NSFont(name: name, size: safeSize) {
            return font
        }
        return NSFont.systemFont(
            ofSize: safeSize,
            weight: NSFont.Weight(rawValue: CGFloat(handwriting.fontWeight))
        )
    }

    private static func locationMeasurementFont(fontSize: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: fontSize, weight: .medium)
    }

    public static func locationFontSize(profile: PostcardOverlayProfile) -> CGFloat {
        profile == .detail ? 12 : 11
    }

    public static let locationShadowRadius: CGFloat = 0.7
    public static let locationShadowOffset = CGSize.zero
    public static func locationRenderSlack(profile: PostcardOverlayProfile) -> CGSize {
        profile == .detail ? CGSize(width: 3, height: 1) : CGSize(width: 2, height: 1)
    }
    public static let locationSafetyOutset = CGSize(
        width: ceil(locationShadowRadius + abs(locationShadowOffset.width) + 1),
        height: ceil(locationShadowRadius + abs(locationShadowOffset.height) + 1)
    )
    public static func fit(
        message: String,
        region: PostcardOverlayRegion,
        profile: PostcardOverlayProfile,
        containerSize: CGSize
    ) -> PostcardTypographyFit {
        let handwriting = PostcardMoodTypographyResolver().resolve(
            mood: Mood(level: 0, label: "serene", quote: message)
        )
        return fit(
            message: message,
            region: region,
            profile: profile,
            containerSize: containerSize,
            handwriting: handwriting
        )
    }

    public static func fit(
        message: String,
        region: PostcardOverlayRegion,
        profile: PostcardOverlayProfile,
        containerSize: CGSize,
        handwriting: PostcardHandwritingStyle
    ) -> PostcardTypographyFit {
        fit(
            message: message,
            frame: PostcardOverlayPresentation.frame(
                for: region,
                profile: profile,
                containerSize: containerSize
            ),
            lineLimit: region.messageLineLimit,
            profile: profile,
            handwriting: handwriting
        )
    }

    public static func fit(
        message: String,
        frame: CGRect,
        lineLimit: Int,
        profile: PostcardOverlayProfile,
        handwriting: PostcardHandwritingStyle
    ) -> PostcardTypographyFit {
        let baseBounds: ClosedRange<CGFloat> = profile == .detail ? 17...30 : 12...16
        let scaledUpperBound = max(
            baseBounds.lowerBound,
            baseBounds.upperBound * CGFloat(handwriting.sizeScale)
        )
        let padding = messagePadding(profile: profile, frame: frame)
        let availableWidth = max(frame.width - padding * 2, 1)
        // The larger detail face needs two points of SwiftUI fragment slack.
        // Compact's measured 12-point two-line text already fits a 29-point area;
        // rounding every line up would incorrectly discard that usable space.
        let renderSlack: CGFloat = profile == .detail ? 2 : 0
        let availableHeight = max(frame.height - padding * 2 - renderSlack, 1)
        var size = scaledUpperBound
        while size > baseBounds.lowerBound {
            let result = measuredFit(
                message: message,
                fontSize: size,
                availableWidth: availableWidth,
                availableHeight: availableHeight,
                lineLimit: lineLimit,
                handwriting: handwriting
            )
            if result.requiredLineCount <= lineLimit, result.fitsVertically {
                return PostcardTypographyFit(fontSize: size, requiredLineCount: result.requiredLineCount, fitsVertically: true)
            }
            size = max(size - 0.5, baseBounds.lowerBound)
        }
        let result = measuredFit(
            message: message,
            fontSize: baseBounds.lowerBound,
            availableWidth: availableWidth,
            availableHeight: availableHeight,
            lineLimit: lineLimit,
            handwriting: handwriting
        )
        return PostcardTypographyFit(
            fontSize: baseBounds.lowerBound,
            requiredLineCount: result.requiredLineCount,
            fitsVertically: result.fitsVertically
        )
    }

    public static func fit(
        messageLength: Int,
        region: PostcardOverlayRegion,
        profile: PostcardOverlayProfile,
        containerSize: CGSize
    ) -> PostcardTypographyFit {
        fit(
            message: String(repeating: "字", count: max(messageLength, 0)),
            region: region,
            profile: profile,
            containerSize: containerSize
        )
    }

    public static func locationFit(
        labelLength: Int,
        region: PostcardOverlayRegion,
        profile: PostcardOverlayProfile,
        containerSize: CGSize
    ) -> PostcardLocationTypographyFit {
        locationFit(
            label: String(repeating: "n", count: max(labelLength, 0)),
            region: region,
            profile: profile,
            containerSize: containerSize
        )
    }

    public static func locationFit(
        label: String,
        region: PostcardOverlayRegion,
        profile: PostcardOverlayProfile,
        containerSize: CGSize
    ) -> PostcardLocationTypographyFit {
        let frame = PostcardOverlayPresentation.frame(
            for: region,
            profile: profile,
            containerSize: containerSize
        )
        let baseFontSize = locationFontSize(profile: profile)
        let horizontalChrome: CGFloat = profile == .detail ? 18 : 14
        let verticalPadding: CGFloat = 0
        let availableWidth = max(frame.width - horizontalChrome, 1)
        let availableHeight = max(frame.height - verticalPadding, 1)
        var scale: CGFloat = 1
        let minimumScale: CGFloat = profile == .compact ? 9.0 / 11.0 : 9.0 / 12.0
        while scale > minimumScale {
            let result = locationMeasuredFit(
                label: label,
                fontSize: baseFontSize * scale,
                availableWidth: availableWidth,
                availableHeight: availableHeight
            )
            if result.requiredLineCount <= 2, result.fitsVertically {
                return PostcardLocationTypographyFit(
                    minimumScaleFactor: scale,
                    requiredLineCount: result.requiredLineCount,
                    fitsVertically: true
                )
            }
            scale = max(scale - 0.02, minimumScale)
        }
        let result = locationMeasuredFit(
            label: label,
            fontSize: baseFontSize * minimumScale,
            availableWidth: availableWidth,
            availableHeight: availableHeight
        )
        return PostcardLocationTypographyFit(
            minimumScaleFactor: minimumScale,
            requiredLineCount: result.requiredLineCount,
            fitsVertically: result.fitsVertically
        )
    }

    public static func defaultContainerSize(profile: PostcardOverlayProfile) -> CGSize {
        profile == .detail
            ? CGSize(width: 360, height: 230)
            : CGSize(width: 340, height: 120)
    }

    public static func locationRect(
        label: String,
        region: PostcardOverlayRegion,
        profile: PostcardOverlayProfile,
        containerSize: CGSize
    ) -> CGRect {
        guard containerSize.width > 0, containerSize.height > 0 else { return .zero }
        let corner = PostcardOverlayPresentation.frame(
            for: region,
            profile: profile,
            containerSize: containerSize
        )
        let baseFontSize = locationFontSize(profile: profile)
        let fit = locationFit(
            label: label,
            region: region,
            profile: profile,
            containerSize: containerSize
        )
        let font = locationMeasurementFont(fontSize: baseFontSize)
        let spacing: CGFloat = profile == .detail ? 6 : 3
        let iconWidth = baseFontSize
        let renderSlack = locationRenderSlack(profile: profile)
        let maximumTextWidth = max(corner.width - iconWidth - spacing, 1)
        let naturalTextWidth = ceil((label as NSString).size(withAttributes: [.font: font]).width)
        let textWidth = min(naturalTextWidth, maximumTextWidth)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let lineCount = min(
            max(fit.requiredLineCount, 1),
            PostcardOverlayGeometry.locationLineLimit(profile: profile)
        )
        let renderedSize = CGSize(
            width: min(ceil(iconWidth + spacing + textWidth + renderSlack.width), corner.width),
            height: min(ceil(CGFloat(lineCount) * lineHeight + renderSlack.height), corner.height)
        )
        let trailing = region == .topTrailing || region == .locationBottomTrailing
        let bottom = region == .locationBottomLeading || region == .locationBottomTrailing
        let frame = CGRect(
            x: trailing ? corner.maxX - renderedSize.width : corner.minX,
            y: bottom ? corner.maxY - renderedSize.height : corner.minY,
            width: renderedSize.width,
            height: renderedSize.height
        )
        return CGRect(
            x: frame.minX / containerSize.width,
            y: frame.minY / containerSize.height,
            width: frame.width / containerSize.width,
            height: frame.height / containerSize.height
        )
    }

    public static func locationSafetyRect(
        label: String,
        region: PostcardOverlayRegion,
        profile: PostcardOverlayProfile,
        containerSize: CGSize
    ) -> CGRect {
        guard containerSize.width > 0, containerSize.height > 0 else { return .zero }
        let content = locationRect(
            label: label,
            region: region,
            profile: profile,
            containerSize: containerSize
        )
        let contentFrame = CGRect(
            x: content.minX * containerSize.width,
            y: content.minY * containerSize.height,
            width: content.width * containerSize.width,
            height: content.height * containerSize.height
        )
        let expanded = contentFrame.insetBy(
            dx: -locationSafetyOutset.width,
            dy: -locationSafetyOutset.height
        ).intersection(PostcardOverlayPresentation.canvasFrame(containerSize: containerSize))
        guard !expanded.isNull, !expanded.isEmpty else { return .zero }
        return CGRect(
            x: expanded.minX / containerSize.width,
            y: expanded.minY / containerSize.height,
            width: expanded.width / containerSize.width,
            height: expanded.height / containerSize.height
        )
    }

    private static func measuredFit(
        message: String,
        fontSize: CGFloat,
        availableWidth: CGFloat,
        availableHeight: CGFloat,
        lineLimit: Int,
        handwriting: PostcardHandwritingStyle
    ) -> (requiredLineCount: Int, fitsVertically: Bool) {
        guard !message.isEmpty else { return (1, true) }
        let font = measurementFont(fontSize: fontSize, handwriting: handwriting)! as CTFont
        let attributes = [kCTFontAttributeName: font] as CFDictionary
        let attributed = CFAttributedStringCreate(nil, message as CFString, attributes)!
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        _ = framesetter
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let utf16Length = (message as NSString).length
        var index = 0
        var lines = 0
        while index < utf16Length {
            let count = CTTypesetterSuggestLineBreak(typesetter, index, Double(availableWidth))
            guard count > 0 else { break }
            lines += 1
            index += count
        }
        let requiredLines = max(lines, 1)
        return (
            requiredLines,
            requiredLines <= lineLimit
                && CGFloat(requiredLines) * renderedLineHeight(
                    fontSize: fontSize,
                    handwriting: handwriting
                ) <= availableHeight + 0.001
        )
    }

    private static func locationMeasuredFit(
        label: String,
        fontSize: CGFloat,
        availableWidth: CGFloat,
        availableHeight: CGFloat
    ) -> (requiredLineCount: Int, fitsVertically: Bool) {
        let result = measuredLineCount(
            text: label,
            font: locationMeasurementFont(fontSize: fontSize),
            availableWidth: availableWidth
        )
        return (
            result,
            result <= 2 && CGFloat(result) * fontSize * 1.15 <= availableHeight + 0.001
        )
    }

    private static func measuredLineCount(
        text: String,
        font: NSFont,
        availableWidth: CGFloat
    ) -> Int {
        guard !text.isEmpty else { return 1 }
        let attributes = [kCTFontAttributeName: font as CTFont] as CFDictionary
        let attributed = CFAttributedStringCreate(nil, text as CFString, attributes)!
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let length = (text as NSString).length
        var index = 0
        var lines = 0
        while index < length {
            let count = CTTypesetterSuggestLineBreak(typesetter, index, Double(availableWidth))
            guard count > 0 else { break }
            lines += 1
            index += count
        }
        return max(lines, 1)
    }
}

enum PostcardSaliencySource: Sendable {
    case attention
    case animal
    case heuristic

    var isVision: Bool {
        switch self {
        case .attention, .animal:
            true
        case .heuristic:
            false
        }
    }
}

public struct PostcardSalientRegion: Equatable, Sendable {
    public let rect: CGRect
    public let weight: Double
    let source: PostcardSaliencySource

    public init(rect: CGRect, weight: Double) {
        self.init(rect: rect, weight: weight, source: .heuristic)
    }

    init(rect: CGRect, weight: Double, source: PostcardSaliencySource) {
        self.rect = Self.normalized(rect)
        self.weight = Self.unitValue(weight)
        self.source = source
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rect == rhs.rect && lhs.weight == rhs.weight
    }

    private static func normalized(_ rect: CGRect) -> CGRect {
        guard rect.origin.x.isFinite,
              rect.origin.y.isFinite,
              rect.size.width.isFinite,
              rect.size.height.isFinite,
              rect.width > 0,
              rect.height > 0 else { return .zero }

        let minX = min(max(rect.minX, 0), 1)
        let minY = min(max(rect.minY, 0), 1)
        let maxX = min(max(rect.maxX, 0), 1)
        let maxY = min(max(rect.maxY, 0), 1)
        guard maxX > minX, maxY > minY else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    fileprivate static func unitValue(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

public struct PostcardColorSample: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = PostcardSalientRegion.unitValue(red)
        self.green = PostcardSalientRegion.unitValue(green)
        self.blue = PostcardSalientRegion.unitValue(blue)
    }

    public var relativeLuminance: Double {
        PostcardTextContrast.relativeLuminance(red: red, green: green, blue: blue)
    }
}

public struct PostcardPixelSample: Equatable, Sendable {
    public let luminance: Double
    public let red: Double
    public let green: Double
    public let blue: Double
    public let locationContrastWitnesses: PostcardLocationContrastWitnesses

    public init(
        luminance: Double,
        red: Double,
        green: Double,
        blue: Double,
        locationContrastWitnesses: PostcardLocationContrastWitnesses? = nil
    ) {
        self.luminance = PostcardSalientRegion.unitValue(luminance)
        self.red = PostcardSalientRegion.unitValue(red)
        self.green = PostcardSalientRegion.unitValue(green)
        self.blue = PostcardSalientRegion.unitValue(blue)
        self.locationContrastWitnesses = locationContrastWitnesses
            ?? PostcardLocationContrastWitnesses(backgroundSamples: [
                PostcardColorSample(red: red, green: green, blue: blue),
            ])
    }
}

public struct PostcardSampleGrid: Equatable, Sendable {
    public let columns: Int
    public let rows: Int
    public let values: [PostcardPixelSample]

    public init(columns: Int, rows: Int, values: [PostcardPixelSample]) {
        self.columns = max(columns, 0)
        self.rows = max(rows, 0)
        self.values = values
    }

    public static func uniform(
        luminance: Double,
        red: Double,
        green: Double,
        blue: Double
    ) -> Self {
        Self(
            columns: 1,
            rows: 1,
            values: [PostcardPixelSample(luminance: luminance, red: red, green: green, blue: blue)]
        )
    }

    public func average(in rect: CGRect) -> PostcardPixelSample {
        guard isValid else { return Self.neutralSample }
        let selected = weightedSamples(in: rect)
        let totalWeight = selected.reduce(0) { $0 + $1.weight }
        guard totalWeight > 0 else { return Self.neutralSample }
        let locationWitnesses = PostcardLocationContrastWitnesses.combining(
            selected.map(\.sample.locationContrastWitnesses)
        )
        return PostcardPixelSample(
            luminance: selected.reduce(0) { $0 + $1.sample.luminance * $1.weight } / totalWeight,
            red: selected.reduce(0) { $0 + $1.sample.red * $1.weight } / totalWeight,
            green: selected.reduce(0) { $0 + $1.sample.green * $1.weight } / totalWeight,
            blue: selected.reduce(0) { $0 + $1.sample.blue * $1.weight } / totalWeight,
            locationContrastWitnesses: locationWitnesses
        )
    }

    public func luminanceRange(in rect: CGRect) -> ClosedRange<Double> {
        guard isValid else { return 0.5...0.5 }
        let values = weightedSamples(in: rect).map(\.sample.luminance)
        guard let minimum = values.min(), let maximum = values.max() else { return 0.5...0.5 }
        return minimum...maximum
    }

    var isValid: Bool {
        guard columns > 0, rows > 0, columns <= Int.max / rows else { return false }
        return values.count == columns * rows
    }

    func colorVariance(in rect: CGRect) -> Double {
        guard isValid else { return 0 }
        let selected = weightedSamples(in: rect)
        guard selected.count > 1 else { return 0 }
        let totalWeight = selected.reduce(0) { $0 + $1.weight }
        guard totalWeight > 0 else { return 0 }
        let mean = average(in: rect)
        return selected.reduce(0) { result, weightedSample in
            let sample = weightedSample.sample
            let luminanceDelta = sample.luminance - mean.luminance
            let redDelta = sample.red - mean.red
            let greenDelta = sample.green - mean.green
            let blueDelta = sample.blue - mean.blue
            return result + weightedSample.weight * (
                luminanceDelta * luminanceDelta
                + (redDelta * redDelta + greenDelta * greenDelta + blueDelta * blueDelta) / 3
            )
        } / totalWeight
    }

    func colorSamples(in rect: CGRect) -> [PostcardPixelSample] {
        guard isValid else { return [] }
        return weightedSamples(in: rect).map(\.sample)
    }

    func locationContrastWitnesses(in rect: CGRect) -> PostcardLocationContrastWitnesses? {
        guard isValid else { return nil }
        let selected = weightedSamples(in: rect)
        guard !selected.isEmpty else { return nil }
        return .combining(selected.map(\.sample.locationContrastWitnesses))
    }

    private func weightedSamples(in rect: CGRect) -> [(sample: PostcardPixelSample, weight: Double)] {
        let normalizedRect = PostcardSalientRegion(rect: rect, weight: 1).rect
        guard !normalizedRect.isEmpty else { return [] }
        var selected: [(sample: PostcardPixelSample, weight: Double)] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let cell = CGRect(
                    x: CGFloat(column) / CGFloat(columns),
                    y: CGFloat(row) / CGFloat(rows),
                    width: 1 / CGFloat(columns),
                    height: 1 / CGFloat(rows)
                )
                let overlap = normalizedRect.intersection(cell)
                guard !overlap.isNull, !overlap.isEmpty else { continue }
                selected.append((
                    sample: values[row * columns + column],
                    weight: Double(overlap.width * overlap.height)
                ))
            }
        }
        return selected
    }

    private static let neutralSample = PostcardPixelSample(
        luminance: 0.5,
        red: 0.5,
        green: 0.5,
        blue: 0.5
    )
}

public struct PostcardVisualAnalysis: Equatable, Sendable {
    public let salientRegions: [PostcardSalientRegion]
    public let samples: PostcardSampleGrid
    public let protectedRegions: [CGRect]
    public let foregroundRegions: [CGRect]

    public init(
        salientRegions: [PostcardSalientRegion],
        samples: PostcardSampleGrid,
        protectedRegions: [CGRect] = [],
        foregroundRegions: [CGRect] = []
    ) {
        self.salientRegions = salientRegions
        self.samples = samples
        self.protectedRegions = protectedRegions.compactMap { rect in
            let normalized = PostcardSalientRegion(rect: rect, weight: 1).rect
            return normalized.isEmpty ? nil : normalized
        }
        self.foregroundRegions = foregroundRegions.compactMap { rect in
            let normalized = PostcardSalientRegion(rect: rect, weight: 1).rect
            return normalized.isEmpty ? nil : normalized
        }
    }
}

public extension PostcardVisualAnalysis {
    func protecting(_ normalizedRect: CGRect) -> PostcardVisualAnalysis {
        let region = PostcardSalientRegion(rect: normalizedRect, weight: 1)
        guard !region.rect.isEmpty else { return self }
        return PostcardVisualAnalysis(
            salientRegions: salientRegions + [region],
            samples: samples,
            protectedRegions: protectedRegions + [region.rect],
            foregroundRegions: foregroundRegions
        )
    }
}

public enum PostcardMessagePlacement: Equatable, Sendable {
    case onImage
    case belowImage
}

public enum PostcardMessageFallbackReason: Equatable, Sendable {
    case unknownAnalysis
    case noReliableForeground
    case subjectConflict
    case textDoesNotFit
    case insufficientReadability
}

public struct PostcardOverlayLayout: Equatable, Sendable {
    public static let locationRegions: [PostcardOverlayRegion] = [
        .topLeading,
        .topTrailing,
        .locationBottomLeading,
        .locationBottomTrailing,
    ]

    public let locationRegion: PostcardOverlayRegion
    public let locationRect: CGRect
    public let locationSafetyRect: CGRect
    public let showsLocationLabel: Bool
    public let locationInkStyle: PostcardLocationInkStyle?
    public let messageRegion: PostcardOverlayRegion
    public let messagePlacement: PostcardMessagePlacement
    public let normalizedMessageRect: CGRect?
    public let messageLineLimitOverride: Int?
    public let fallbackReason: PostcardMessageFallbackReason?
    public var messageLineLimit: Int {
        min(max(messageLineLimitOverride ?? messageRegion.messageLineLimit, 1), 4)
    }
    public let messageFontSize: CGFloat
    public let handwritingStyle: PostcardHandwritingStyle
    public let inkStyle: PostcardInkStyle
    public let accent: PostcardPixelSample
    public let pawSignature: PostcardPawSignature

    public var usesLightText: Bool { inkStyle.usesLightText }
    public var washOpacity: Double { inkStyle.washOpacity }
    public var messageFont: NSFont {
        PostcardOverlayTypography.measurementFont(
            fontSize: messageFontSize,
            handwriting: handwritingStyle
        )!
    }
    public var messageLineHeight: CGFloat {
        PostcardOverlayTypography.renderedLineHeight(
            fontSize: messageFontSize,
            handwriting: handwritingStyle
        )
    }
    public var messageLineSpacing: CGFloat {
        let font = messageFont
        return max(messageLineHeight - (font.ascender - font.descender + font.leading), 0)
    }

    public init(
        locationRegion: PostcardOverlayRegion,
        locationRect: CGRect = .zero,
        locationSafetyRect: CGRect = .zero,
        showsLocationLabel: Bool = false,
        locationInkStyle: PostcardLocationInkStyle? = nil,
        messageRegion: PostcardOverlayRegion,
        messageFontSize: CGFloat,
        inkStyle: PostcardInkStyle,
        accent: PostcardPixelSample,
        pawSignature: PostcardPawSignature? = nil,
        handwritingStyle: PostcardHandwritingStyle = .sereneSystemFallback,
        messagePlacement: PostcardMessagePlacement = .onImage,
        normalizedMessageRect: CGRect? = nil,
        messageLineLimitOverride: Int? = nil,
        fallbackReason: PostcardMessageFallbackReason? = nil
    ) {
        self.locationRegion = locationRegion
        self.locationRect = showsLocationLabel ? locationRect : .zero
        self.locationSafetyRect = showsLocationLabel ? locationSafetyRect : .zero
        self.showsLocationLabel = showsLocationLabel
        self.locationInkStyle = showsLocationLabel ? locationInkStyle : nil
        self.messageRegion = messageRegion
        self.messagePlacement = messagePlacement
        self.normalizedMessageRect = normalizedMessageRect
        self.messageLineLimitOverride = messageLineLimitOverride
        self.fallbackReason = fallbackReason
        self.messageFontSize = messageFontSize
        self.handwritingStyle = handwritingStyle
        self.inkStyle = inkStyle
        self.accent = accent
        self.pawSignature = pawSignature ?? PostcardPawSignature(
            placement: .omitted,
            style: PostcardPawSignatureStyle(handwriting: handwritingStyle, ink: inkStyle)
        )
    }

    public func resolvedNormalizedMessageRect(profile: PostcardOverlayProfile) -> CGRect {
        normalizedMessageRect ?? PostcardOverlayGeometry.rect(for: messageRegion, profile: profile)
    }

    public func messageFrame(
        profile: PostcardOverlayProfile,
        containerSize: CGSize
    ) -> CGRect {
        let rect = resolvedNormalizedMessageRect(profile: profile)
        return CGRect(
            x: rect.minX * containerSize.width,
            y: rect.minY * containerSize.height,
            width: rect.width * containerSize.width,
            height: rect.height * containerSize.height
        )
    }

    func placingMessageBelowImage(reason: PostcardMessageFallbackReason? = nil) -> Self {
        Self(locationRegion: .topLeading, messageRegion: messageRegion,
             messageFontSize: messageFontSize, inkStyle: inkStyle, accent: accent,
             handwritingStyle: handwritingStyle, messagePlacement: .belowImage,
             normalizedMessageRect: normalizedMessageRect,
             messageLineLimitOverride: messageLineLimitOverride,
             fallbackReason: reason ?? fallbackReason)
    }
}

public struct PostcardTextTreatment: Equatable, Sendable {
    public let usesLightText: Bool
    public let washOpacity: Double
    public let effectiveBackgroundLuminance: Double
    public var foregroundLuminance: Double { usesLightText ? 1 : 0 }

    public init(
        usesLightText: Bool,
        washOpacity: Double,
        effectiveBackgroundLuminance: Double
    ) {
        self.usesLightText = usesLightText
        self.washOpacity = PostcardSalientRegion.unitValue(washOpacity)
        self.effectiveBackgroundLuminance = PostcardSalientRegion.unitValue(
            effectiveBackgroundLuminance
        )
    }
}

public enum PostcardTextContrast {
    public static let minimumContrastRatio = 4.5
    public static let maximumWashOpacity = 0.82
    private static let lightTextThreshold = 0.58

    public static func treatment(backgroundLuminance: Double) -> PostcardTextTreatment {
        let background = PostcardSalientRegion.unitValue(backgroundLuminance)
        let usesLightText = background < lightTextThreshold
        let opacity: Double
        if usesLightText {
            let maximumBackground = (1.05 / minimumContrastRatio) - 0.05
            opacity = background > maximumBackground
                ? 1 - maximumBackground / background
                : 0
        } else {
            let minimumBackground = 0.05 * minimumContrastRatio - 0.05
            opacity = background < minimumBackground
                ? (minimumBackground - background) / (1 - background)
                : 0
        }
        let boundedOpacity = min(max(opacity, 0), maximumWashOpacity)
        let washLuminance = usesLightText ? 0.0 : 1.0
        let effective = background * (1 - boundedOpacity) + washLuminance * boundedOpacity
        return PostcardTextTreatment(
            usesLightText: usesLightText,
            washOpacity: boundedOpacity,
            effectiveBackgroundLuminance: effective
        )
    }

    public static func treatment(
        backgroundLuminanceRange range: ClosedRange<Double>
    ) -> PostcardTextTreatment {
        let lower = PostcardSalientRegion.unitValue(range.lowerBound)
        let upper = PostcardSalientRegion.unitValue(range.upperBound)
        if abs(upper - lower) < 0.000_001 {
            return treatment(backgroundLuminance: lower)
        }
        let maximumBackground = (1.05 / minimumContrastRatio) - 0.05
        let lightOpacity = upper > maximumBackground ? 1 - maximumBackground / upper : 0
        let minimumBackground = 0.05 * minimumContrastRatio - 0.05
        let darkOpacity = lower < minimumBackground
            ? (minimumBackground - lower) / (1 - lower)
            : 0
        let prefersLight = (lower + upper) / 2 < lightTextThreshold
        let usesLightText = lightOpacity == darkOpacity ? prefersLight : lightOpacity < darkOpacity
        let opacity = usesLightText ? lightOpacity : darkOpacity
        let boundedOpacity = min(max(opacity, 0), maximumWashOpacity)
        let endpoint = usesLightText ? upper : lower
        let washLuminance = usesLightText ? 0.0 : 1.0
        let effective = endpoint * (1 - boundedOpacity) + washLuminance * boundedOpacity
        return PostcardTextTreatment(
            usesLightText: usesLightText,
            washOpacity: boundedOpacity,
            effectiveBackgroundLuminance: effective
        )
    }

    public static func contrastRatio(
        foregroundLuminance: Double,
        backgroundLuminance: Double
    ) -> Double {
        let foreground = PostcardSalientRegion.unitValue(foregroundLuminance)
        let background = PostcardSalientRegion.unitValue(backgroundLuminance)
        let lighter = max(foreground, background)
        let darker = min(foreground, background)
        return (lighter + 0.05) / (darker + 0.05)
    }

    public static func relativeLuminance(red: Double, green: Double, blue: Double) -> Double {
        0.2126 * linearized(red) + 0.7152 * linearized(green) + 0.0722 * linearized(blue)
    }

    private static func linearized(_ component: Double) -> Double {
        let value = PostcardSalientRegion.unitValue(component)
        return value <= 0.04045
            ? value / 12.92
            : pow((value + 0.055) / 1.055, 2.4)
    }
}

public enum PostcardVisualMessage {
    public static func resolve(_ fullMessage: String) -> String {
        var normalized = ""
        var pendingSpace = false
        for scalar in fullMessage.unicodeScalars {
            if scalar.properties.isWhitespace {
                pendingSpace = !normalized.isEmpty
            } else {
                if pendingSpace { normalized.append(" ") }
                normalized.unicodeScalars.append(scalar)
                pendingSpace = false
            }
        }
        return normalized
    }
}

public struct PostcardArtworkMetadata: Equatable, Sendable {
    public let locationLabel: String
    public let spokenLocationLabel: String
    public let fullMessage: String
    public let visualMessage: String
    public let mood: Mood

    public init(event: TripEvent) {
        let displayLocation = PostcardDisplayLocation()
        locationLabel = displayLocation.resolveCompact(event.location, maximumLength: 16)
        spokenLocationLabel = displayLocation.resolveSpoken(event.location)
        fullMessage = event.mood.quote
        visualMessage = PostcardVisualMessage.resolve(event.mood.quote)
        mood = event.mood
    }
}

public enum PostcardArtworkLayoutResolver {
    public static func resolve(
        metadata: PostcardArtworkMetadata,
        analysis: PostcardVisualAnalysis?,
        profile: PostcardOverlayProfile,
        containerSize: CGSize
    ) -> PostcardOverlayLayout {
        guard let analysis, analysis.samples.isValid else {
            let serene = PostcardMoodTypographyResolver().resolve(
                mood: Mood(level: 0, label: "serene", quote: metadata.visualMessage)
            )
            return PostcardOverlaySolver.unknownFallback(
                message: metadata.visualMessage,
                profile: profile,
                containerSize: containerSize,
                handwriting: serene
            ).placingMessageBelowImage(reason: .unknownAnalysis)
        }
        let handwriting = PostcardMoodTypographyResolver().resolve(mood: metadata.mood)
        // Preserve known preview cats and every foreground-object boundary.
        // Objectness works for illustrated subjects too, unlike animal labels.
        // Generic animal/attention hints alone do not authorize an overlay.
        let subjects = analysis.protectedRegions + analysis.foregroundRegions
        guard !subjects.isEmpty else {
            return PostcardOverlaySolver.solve(
                analysis: analysis, locationLabel: metadata.locationLabel,
                message: metadata.visualMessage, profile: profile,
                containerSize: containerSize, handwriting: handwriting
            ).placingMessageBelowImage(reason: .noReliableForeground)
        }
        let protectedAnalysis = subjects.reduce(analysis) { result, subject in
            result.protecting(subject.insetBy(dx: -0.015, dy: -0.015))
        }
        let layout = PostcardOverlaySolver.solve(
            analysis: protectedAnalysis,
            locationLabel: metadata.locationLabel,
            message: metadata.visualMessage,
            profile: profile,
            containerSize: containerSize,
            handwriting: handwriting
        )
        let messageRect = layout.resolvedNormalizedMessageRect(profile: profile)
        let presetIsSafe = !protectedAnalysis.protectedRegions.contains(where: messageRect.intersects)
        let presetFits = layout.messageTextLayout(
            message: metadata.visualMessage,
            profile: profile,
            containerSize: containerSize
        ).fits
        if presetIsSafe, presetFits {
            return layout
        }
        let search = PostcardMessagePlacementSearch.search(.init(
            message: metadata.visualMessage,
            analysis: protectedAnalysis,
            profile: profile,
            containerSize: containerSize,
            handwriting: handwriting
        ))
        if let placement = search.placement {
            return PostcardOverlaySolver.layout(
                searchPlacement: placement,
                analysis: protectedAnalysis,
                locationLabel: metadata.locationLabel,
                message: metadata.visualMessage,
                profile: profile,
                containerSize: containerSize,
                handwriting: handwriting
            )
        }
        return layout.placingMessageBelowImage(
            reason: search.fallbackReason ?? (presetIsSafe ? .textDoesNotFit : .subjectConflict)
        )
    }
}

public enum PostcardOverlaySolver {
    /// Reuses the existing location safety and contrast evaluator without
    /// inventing a second ordinary-message rectangle for generated handwriting.
    static func presentationLocation(
        analysis: PostcardVisualAnalysis,
        label: String,
        handwritingRect: CGRect,
        profile: PostcardOverlayProfile,
        containerSize: CGSize
    ) -> PostcardOverlayLayout {
        let subjects = analysis.protectedRegions + analysis.foregroundRegions
        let protected = subjects.reduce(analysis) {
            $0.protecting($1.insetBy(dx: -0.015, dy: -0.015))
        }.protecting(handwritingRect)
        let location = analysis.samples.isValid && !subjects.isEmpty
            ? bestLocation(label: label, messageRect: handwritingRect,
                           analysis: protected, profile: profile, containerSize: containerSize)
            : nil
        return PostcardOverlayLayout(
            locationRegion: location?.candidate.safety.region ?? .topLeading,
            locationRect: location?.candidate.contentRect ?? .zero,
            locationSafetyRect: location?.candidate.safety.rect ?? .zero,
            showsLocationLabel: location != nil,
            locationInkStyle: location?.inkStyle,
            messageRegion: .topLeading,
            messageFontSize: 13,
            inkStyle: PostcardInkResolver.unknownStyle,
            accent: analysis.samples.average(in: location?.candidate.contentRect ?? handwritingRect)
        )
    }

    private struct Candidate {
        let region: PostcardOverlayRegion
        let rect: CGRect
        let positionPenalty: Double
        let order: Int
    }

    private struct MessageCandidateEvaluation {
        let candidate: Candidate
        let fit: PostcardTypographyFit
        let paw: PostcardPawPlacement
    }

    private struct LocationCandidateEvaluation {
        let candidate: LocationCandidate
        let inkStyle: PostcardLocationInkStyle
    }

    private struct LocationCandidate {
        let safety: Candidate
        let contentRect: CGRect
    }

    static func layout(
        searchPlacement: PostcardMessagePlacementSearch.Placement,
        analysis: PostcardVisualAnalysis,
        locationLabel: String,
        message: String,
        profile: PostcardOverlayProfile,
        containerSize: CGSize,
        handwriting: PostcardHandwritingStyle
    ) -> PostcardOverlayLayout {
        let rect = searchPlacement.normalizedRect
        let location = bestLocation(
            label: locationLabel,
            messageRect: rect,
            analysis: analysis,
            profile: profile,
            containerSize: containerSize
        )
        let protectedFrames = pawProtectedFrames(
            locationRect: location?.candidate.safety.rect ?? .zero,
            analysis: analysis,
            containerSize: containerSize
        )
        let outerFrame = CGRect(
            x: rect.minX * containerSize.width,
            y: rect.minY * containerSize.height,
            width: rect.width * containerSize.width,
            height: rect.height * containerSize.height
        )
        let padding = PostcardOverlayTypography.messagePadding(profile: profile, frame: outerFrame)
        let messageFrame = outerFrame.insetBy(dx: padding, dy: padding)
        let paw = PostcardPawLayout.resolve(
            message: message,
            messageFrame: messageFrame,
            fontSize: searchPlacement.fontSize,
            typography: handwriting,
            profile: profile,
            lineLimit: searchPlacement.lineLimit,
            protectedFrames: protectedFrames
        )
        let sampledColor = analysis.samples.average(in: rect)
        let inkStyle = PostcardInkResolver.resolve(
            sample: sampledColor,
            backgroundSamples: analysis.samples.colorSamples(in: rect),
            colorVariance: analysis.samples.colorVariance(in: rect),
            isUnknown: false
        )
        return PostcardOverlayLayout(
            locationRegion: location?.candidate.safety.region ?? .topLeading,
            locationRect: location?.candidate.contentRect ?? .zero,
            locationSafetyRect: location?.candidate.safety.rect ?? .zero,
            showsLocationLabel: location != nil,
            locationInkStyle: location?.inkStyle,
            messageRegion: .wideTopLeading,
            messageFontSize: searchPlacement.fontSize,
            inkStyle: inkStyle,
            accent: sampledColor,
            pawSignature: PostcardPawSignature(
                placement: paw,
                style: PostcardPawSignatureStyle(handwriting: handwriting, ink: inkStyle)
            ),
            handwritingStyle: handwriting,
            normalizedMessageRect: rect,
            messageLineLimitOverride: searchPlacement.lineLimit
        )
    }

    public static func solve(
        analysis: PostcardVisualAnalysis,
        locationLabel: String = "旅途中",
        messageLength: Int,
        profile: PostcardOverlayProfile,
        containerSize: CGSize? = nil,
        handwriting: PostcardHandwritingStyle = .sereneSystemFallback
    ) -> PostcardOverlayLayout {
        solve(
            analysis: analysis,
            locationLabel: locationLabel,
            message: String(repeating: "字", count: max(messageLength, 0)),
            profile: profile,
            containerSize: containerSize,
            handwriting: handwriting
        )
    }

    public static func solve(
        analysis: PostcardVisualAnalysis,
        locationLabel: String = "旅途中",
        message messageText: String,
        profile: PostcardOverlayProfile,
        containerSize: CGSize? = nil,
        handwriting: PostcardHandwritingStyle = .sereneSystemFallback
    ) -> PostcardOverlayLayout {
        guard analysis.samples.isValid else {
            return fallback(message: messageText, profile: profile, containerSize: containerSize, handwriting: handwriting)
        }
        guard !analysis.salientRegions.isEmpty else {
            return fallback(
                analysis: analysis,
                locationLabel: locationLabel,
                message: messageText,
                profile: profile,
                containerSize: containerSize,
                handwriting: handwriting
            )
        }

        let size = containerSize ?? PostcardOverlayTypography.defaultContainerSize(profile: profile)
        let initialLocation = bestLocation(
            label: locationLabel,
            messageRect: .zero,
            analysis: analysis,
            profile: profile,
            containerSize: size
        )
        let initialPawProtectedFrames = pawProtectedFrames(
            locationRect: initialLocation?.candidate.safety.rect ?? .zero,
            analysis: analysis,
            containerSize: size
        )
        var regularMessages = evaluateCandidates(
            messageCandidates(profile: profile),
            excluding: initialLocation?.candidate.safety.rect ?? .zero,
            message: messageText,
            profile: profile,
            containerSize: size,
            handwriting: handwriting,
            pawProtectedFrames: initialPawProtectedFrames,
            analysis: analysis
        )
        var wideMessages = evaluateCandidates(
            wideMessageCandidates(profile: profile),
            excluding: initialLocation?.candidate.safety.rect ?? .zero,
            message: messageText,
            profile: profile,
            containerSize: size,
            handwriting: handwriting,
            pawProtectedFrames: initialPawProtectedFrames,
            analysis: analysis
        )
        if regularMessages.isEmpty, wideMessages.isEmpty {
            regularMessages = evaluateCandidates(
                messageCandidates(profile: profile) + emergencyTopMessageCandidates(profile: profile) + columnMessageCandidates(profile: profile),
                excluding: .zero,
                message: messageText,
                profile: profile,
                containerSize: size,
                handwriting: handwriting,
                pawProtectedFrames: initialPawProtectedFrames,
                analysis: analysis
            )
            wideMessages = evaluateCandidates(
                wideMessageCandidates(profile: profile),
                excluding: .zero,
                message: messageText,
                profile: profile,
                containerSize: size,
                handwriting: handwriting,
                pawProtectedFrames: initialPawProtectedFrames,
                analysis: analysis
            )
        }
        let safeRegularMessages = regularMessages.filter { !hasHighSaliencyOverlap($0.candidate, analysis: analysis) }
        let safeWideMessages = wideMessages.filter { !hasHighSaliencyOverlap($0.candidate, analysis: analysis) }
        let eligibleMessages: [MessageCandidateEvaluation]
        if !safeRegularMessages.isEmpty || !safeWideMessages.isEmpty {
            eligibleMessages = preferredCandidatePool(
                regular: safeRegularMessages,
                wide: safeWideMessages,
                analysis: analysis
            )
        } else {
            eligibleMessages = preferredCandidatePool(
                regular: regularMessages,
                wide: wideMessages,
                analysis: analysis
            )
        }
        guard let message = bestEvaluation(in: eligibleMessages, analysis: analysis) else {
            return fallback(message: messageText, profile: profile, containerSize: containerSize, handwriting: handwriting)
        }
        let location = bestLocation(
            label: locationLabel,
            messageRect: message.candidate.rect,
            analysis: analysis,
            profile: profile,
            containerSize: size
        )
        let pawProtectedFrames = pawProtectedFrames(
            locationRect: location?.candidate.safety.rect ?? .zero,
            analysis: analysis,
            containerSize: size
        )
        let messageWithPaw = typographyAndPaw(
            message: messageText,
            region: message.candidate.region,
            profile: profile,
            containerSize: size,
            handwriting: handwriting,
            pawProtectedFrames: pawProtectedFrames
        )
        let sampledColor = analysis.samples.average(in: message.candidate.rect)
        let inkStyle = PostcardInkResolver.resolve(
            sample: sampledColor,
            backgroundSamples: analysis.samples.colorSamples(in: message.candidate.rect),
            colorVariance: analysis.samples.colorVariance(in: message.candidate.rect),
            isUnknown: false
        )
        return PostcardOverlayLayout(
            locationRegion: location?.candidate.safety.region ?? .topLeading,
            locationRect: location?.candidate.contentRect ?? .zero,
            locationSafetyRect: location?.candidate.safety.rect ?? .zero,
            showsLocationLabel: location != nil,
            locationInkStyle: location?.inkStyle,
            messageRegion: message.candidate.region,
            messageFontSize: messageWithPaw.fit.fontSize,
            inkStyle: inkStyle,
            accent: sampledColor,
            pawSignature: PostcardPawSignature(
                placement: messageWithPaw.paw,
                style: PostcardPawSignatureStyle(handwriting: handwriting, ink: inkStyle)
            ),
            handwritingStyle: handwriting
        )
    }

    public static func fallback(
        messageLength: Int,
        profile: PostcardOverlayProfile,
        containerSize: CGSize? = nil,
        handwriting: PostcardHandwritingStyle = .sereneSystemFallback
    ) -> PostcardOverlayLayout {
        fallback(
            message: String(repeating: "字", count: max(messageLength, 0)),
            profile: profile,
            containerSize: containerSize,
            handwriting: handwriting
        )
    }

    public static func fallback(
        message: String,
        profile: PostcardOverlayProfile,
        containerSize: CGSize? = nil,
        handwriting: PostcardHandwritingStyle = .sereneSystemFallback
    ) -> PostcardOverlayLayout {
        unknownFallback(message: message, profile: profile, containerSize: containerSize, handwriting: handwriting)
    }

    public static func unknownFallback(
        messageLength: Int,
        profile: PostcardOverlayProfile,
        containerSize: CGSize? = nil,
        handwriting: PostcardHandwritingStyle = .sereneSystemFallback
    ) -> PostcardOverlayLayout {
        unknownFallback(
            message: String(repeating: "字", count: max(messageLength, 0)),
            profile: profile,
            containerSize: containerSize,
            handwriting: handwriting
        )
    }

    public static func unknownFallback(
        message: String,
        profile: PostcardOverlayProfile,
        containerSize: CGSize? = nil,
        handwriting: PostcardHandwritingStyle = .sereneSystemFallback
    ) -> PostcardOverlayLayout {
        let size = containerSize ?? PostcardOverlayTypography.defaultContainerSize(profile: profile)
        let region = fallbackRegion(message: message, profile: profile, containerSize: size, handwriting: handwriting)
        let typographyFit = PostcardOverlayTypography.fit(
            message: message,
            region: region,
            profile: profile,
            containerSize: size,
            handwriting: handwriting
        )
        return PostcardOverlayLayout(
            locationRegion: .topLeading,
            messageRegion: region,
            messageFontSize: typographyFit.fontSize,
            inkStyle: PostcardInkResolver.unknownStyle,
            accent: PostcardPixelSample(
                luminance: 0,
                red: 0,
                green: 0,
                blue: 0
            ),
            pawSignature: pawSignature(
                message: message,
                region: region,
                fontSize: typographyFit.fontSize,
                inkStyle: PostcardInkResolver.unknownStyle,
                profile: profile,
                containerSize: size,
                handwriting: handwriting,
                protectedFrames: []
            ),
            handwritingStyle: handwriting
        )
    }

    private static func fallback(
        analysis: PostcardVisualAnalysis,
        locationLabel: String,
        message: String,
        profile: PostcardOverlayProfile,
        containerSize: CGSize?,
        handwriting: PostcardHandwritingStyle
    ) -> PostcardOverlayLayout {
        let size = containerSize ?? PostcardOverlayTypography.defaultContainerSize(profile: profile)
        let region = fallbackRegion(message: message, profile: profile, containerSize: size, handwriting: handwriting)
        let rect = PostcardOverlayGeometry.rect(for: region, profile: profile)
        let sample = analysis.samples.average(in: rect)
        let backgroundSamples = analysis.samples.colorSamples(in: rect)
        let colorVariance = analysis.samples.colorVariance(in: rect)
        let inkStyle = PostcardInkResolver.resolve(
            sample: sample,
            backgroundSamples: backgroundSamples.isEmpty ? [sample] : backgroundSamples,
            colorVariance: colorVariance,
            isUnknown: false
        )
        let typographyFit = PostcardOverlayTypography.fit(
            message: message,
            region: region,
            profile: profile,
            containerSize: size,
            handwriting: handwriting
        )
        let location = bestLocation(
            label: locationLabel,
            messageRect: rect,
            analysis: analysis,
            profile: profile,
            containerSize: size
        )
        let pawProtectedFrames = pawProtectedFrames(
            locationRect: location?.candidate.safety.rect ?? .zero,
            analysis: analysis,
            containerSize: size
        )
        return PostcardOverlayLayout(
            locationRegion: location?.candidate.safety.region ?? .topLeading,
            locationRect: location?.candidate.contentRect ?? .zero,
            locationSafetyRect: location?.candidate.safety.rect ?? .zero,
            showsLocationLabel: location != nil,
            locationInkStyle: location?.inkStyle,
            messageRegion: region,
            messageFontSize: typographyFit.fontSize,
            inkStyle: inkStyle,
            accent: sample,
            pawSignature: pawSignature(
                message: message,
                region: region,
                fontSize: typographyFit.fontSize,
                inkStyle: inkStyle,
                profile: profile,
                containerSize: size,
                handwriting: handwriting,
                protectedFrames: pawProtectedFrames
            ),
            handwritingStyle: handwriting
        )
    }

    private static func pawSignature(
        message: String,
        region: PostcardOverlayRegion,
        fontSize: CGFloat,
        inkStyle: PostcardInkStyle,
        profile: PostcardOverlayProfile,
        containerSize: CGSize,
        handwriting: PostcardHandwritingStyle,
        protectedFrames: [CGRect] = []
    ) -> PostcardPawSignature {
        let outerFrame = PostcardOverlayPresentation.frame(
            for: region,
            profile: profile,
            containerSize: containerSize
        )
        let padding = PostcardOverlayTypography.messagePadding(profile: profile, frame: outerFrame)
        let messageFrame = outerFrame.insetBy(dx: padding, dy: padding)
        let signatureBounds = protectedFrames.isEmpty ? nil : pawSignatureBounds(
            messageFrame: messageFrame,
            region: region,
            profile: profile,
            containerSize: containerSize,
            protectedFrames: protectedFrames
        )
        let placement = PostcardPawLayout.resolve(
            message: message,
            messageFrame: messageFrame,
            signatureBounds: signatureBounds,
            fontSize: fontSize,
            typography: handwriting,
            profile: profile,
            lineLimit: region.messageLineLimit,
            protectedFrames: protectedFrames
        )
        return PostcardPawSignature(
            placement: placement,
            style: PostcardPawSignatureStyle(handwriting: handwriting, ink: inkStyle)
        )
    }

    private static func isTrailing(_ region: PostcardOverlayRegion) -> Bool {
        switch region {
        case .topTrailing, .middleTrailing, .bottomTrailing,
             .wideMiddleTrailing, .wideBottomTrailing, .locationBottomTrailing:
            true
        default:
            false
        }
    }

    private static func fallbackRegion(
        message: String,
        profile: PostcardOverlayProfile,
        containerSize: CGSize,
        handwriting: PostcardHandwritingStyle
    ) -> PostcardOverlayRegion {
        let regular: PostcardOverlayRegion = .bottomLeading
        let wide: PostcardOverlayRegion = .wideBottomLeading
        let regularResult = typographyAndPaw(
            message: message,
            region: regular,
            profile: profile,
            containerSize: containerSize,
            handwriting: handwriting
        )
        let wideResult = typographyAndPaw(
            message: message,
            region: wide,
            profile: profile,
            containerSize: containerSize,
            handwriting: handwriting
        )
        if regularResult.fit.fitsVertically, regularResult.paw.mode == .inline { return regular }
        if wideResult.fit.fitsVertically, wideResult.paw.mode == .inline { return wide }
        if regularResult.fit.fitsVertically { return regular }
        return wide
    }

    private static func evaluateCandidates(
        _ candidates: [Candidate],
        excluding locationRect: CGRect,
        message: String,
        profile: PostcardOverlayProfile,
        containerSize: CGSize,
        handwriting: PostcardHandwritingStyle,
        pawProtectedFrames: [CGRect],
        analysis: PostcardVisualAnalysis
    ) -> [MessageCandidateEvaluation] {
        candidates.compactMap { candidate in
            guard !candidate.rect.intersects(locationRect) else { return nil }
            guard !analysis.protectedRegions.contains(where: candidate.rect.intersects) else {
                return nil
            }
            let result = typographyAndPaw(
                message: message,
                region: candidate.region,
                profile: profile,
                containerSize: containerSize,
                handwriting: handwriting,
                pawProtectedFrames: pawProtectedFrames
            )
            guard result.fit.fitsVertically else { return nil }
            return MessageCandidateEvaluation(
                candidate: candidate,
                fit: result.fit,
                paw: result.paw
            )
        }
    }

    private static func bestEvaluation(
        in evaluations: [MessageCandidateEvaluation],
        analysis: PostcardVisualAnalysis
    ) -> MessageCandidateEvaluation? {
        let clear = evaluations.filter {
            !hasAnyProtectedSaliencyOverlap($0.candidate, analysis: analysis)
        }
        let overlapPool = clear.isEmpty ? evaluations : clear
        let safe = overlapPool.filter {
            !hasHighSaliencyOverlap($0.candidate, analysis: analysis)
        }
        let saliencyPool = safe.isEmpty ? overlapPool : safe
        let visible = saliencyPool.filter { $0.paw.mode != .omitted }
        let preferred = visible.isEmpty ? saliencyPool : visible
        guard let candidate = bestCandidateIfPresent(
            in: preferred.map(\.candidate),
            analysis: analysis
        ) else { return nil }
        return preferred.first { $0.candidate.region == candidate.region }
    }

    private static func preferredCandidatePool(
        regular: [MessageCandidateEvaluation],
        wide: [MessageCandidateEvaluation],
        analysis: PostcardVisualAnalysis
    ) -> [MessageCandidateEvaluation] {
        guard !regular.isEmpty else { return wide }
        guard !wide.isEmpty else { return regular }
        let regularBest = bestEvaluation(in: regular, analysis: analysis)
        let wideBest = bestEvaluation(in: wide, analysis: analysis)
        let regularIsClear = regularBest.map {
            !hasAnyProtectedSaliencyOverlap($0.candidate, analysis: analysis)
        } ?? false
        let wideIsClear = wideBest.map {
            !hasAnyProtectedSaliencyOverlap($0.candidate, analysis: analysis)
        } ?? false
        if regularIsClear != wideIsClear { return regularIsClear ? regular : wide }
        let regularMode = regularBest?.paw.mode ?? .omitted
        let wideMode = wideBest?.paw.mode ?? .omitted
        if regularMode == .inline { return regular }
        if wideMode == .inline { return wide }
        if regularMode != .omitted { return regular }
        return wideMode != .omitted ? wide : regular
    }

    private static func typographyAndPaw(
        message: String,
        region: PostcardOverlayRegion,
        profile: PostcardOverlayProfile,
        containerSize: CGSize,
        handwriting: PostcardHandwritingStyle,
        pawProtectedFrames: [CGRect] = []
    ) -> (fit: PostcardTypographyFit, paw: PostcardPawPlacement) {
        let fit = PostcardOverlayTypography.fit(
            message: message,
            region: region,
            profile: profile,
            containerSize: containerSize,
            handwriting: handwriting
        )
        let outerFrame = PostcardOverlayPresentation.frame(
            for: region,
            profile: profile,
            containerSize: containerSize
        )
        let padding = PostcardOverlayTypography.messagePadding(profile: profile, frame: outerFrame)
        let frame = outerFrame.insetBy(dx: padding, dy: padding)
        let signatureBounds = pawProtectedFrames.isEmpty ? nil : pawSignatureBounds(
            messageFrame: frame,
            region: region,
            profile: profile,
            containerSize: containerSize,
            protectedFrames: pawProtectedFrames
        )
        return (
            fit,
            PostcardPawLayout.resolve(
                message: message,
                messageFrame: frame,
                signatureBounds: signatureBounds,
                fontSize: fit.fontSize,
                typography: handwriting,
                profile: profile,
                lineLimit: region.messageLineLimit,
                protectedFrames: pawProtectedFrames
            )
        )
    }

    private static func pawSignatureBounds(
        messageFrame: CGRect,
        region: PostcardOverlayRegion,
        profile: PostcardOverlayProfile,
        containerSize: CGSize,
        protectedFrames: [CGRect]
    ) -> CGRect {
        let horizontal = PostcardOverlayPresentation.frame(
            for: region,
            profile: profile,
            containerSize: containerSize
        )
        let canvas = PostcardOverlayPresentation.canvasFrame(containerSize: containerSize)
        let clearance: CGFloat = profile == .detail ? 4 : 2
        let firstProtectedBelow = protectedFrames
            .filter { obstacle in
                obstacle.minY >= messageFrame.maxY - 0.001
                    && obstacle.maxX > horizontal.minX
                    && obstacle.minX < horizontal.maxX
            }
            .map(\.minY)
            .min()
        let maximumY = min(
            canvas.maxY,
            (firstProtectedBelow ?? canvas.maxY) - clearance
        )
        guard maximumY > messageFrame.minY else { return messageFrame }
        return CGRect(
            x: horizontal.minX,
            y: messageFrame.minY,
            width: horizontal.width,
            height: maximumY - messageFrame.minY
        ).intersection(canvas)
    }

    static func pawProtectedFrames(
        locationRect: CGRect,
        analysis: PostcardVisualAnalysis,
        containerSize: CGSize
    ) -> [CGRect] {
        let explicitSubjects = analysis.protectedRegions + analysis.foregroundRegions
        let credibleAnimals = analysis.salientRegions
            .filter { $0.source == .animal && $0.weight >= salientObstacleWeightThreshold }
            .map(\.rect)
        // Direct solver callers may not have run subject extraction. Preserve
        // their conservative salient-region behavior, while resolved artwork
        // with explicit subjects must not turn a broad attention heatmap into
        // a hard paw exclusion zone.
        let subjectFrames = explicitSubjects.isEmpty
            ? analysis.salientRegions
                .filter { $0.weight >= salientObstacleWeightThreshold }
                .map(\.rect)
            : explicitSubjects + credibleAnimals
        let normalizedFrames = subjectFrames + (locationRect.isEmpty ? [] : [locationRect])
        let canvas = PostcardOverlayPresentation.canvasFrame(containerSize: containerSize)
        return normalizedFrames.compactMap { normalized in
            let frame = CGRect(
                x: normalized.minX * containerSize.width,
                y: normalized.minY * containerSize.height,
                width: normalized.width * containerSize.width,
                height: normalized.height * containerSize.height
            ).intersection(canvas)
            return frame.isNull || frame.isEmpty ? nil : frame
        }
    }

    private static func bestLocation(
        label: String,
        messageRect: CGRect,
        analysis: PostcardVisualAnalysis,
        profile: PostcardOverlayProfile,
        containerSize: CGSize
    ) -> LocationCandidateEvaluation? {
        locationCandidates(label: label, profile: profile, containerSize: containerSize)
            .filter { !$0.safety.rect.intersects(messageRect) }
            .filter { !hasProtectedLocationOverlap($0.safety, analysis: analysis) }
            .compactMap { candidate in
                guard let witnesses = analysis.samples.locationContrastWitnesses(
                    in: candidate.contentRect
                ), let inkStyle = PostcardLocationInkResolver.resolve(
                    backgroundWitnesses: witnesses,
                    profile: profile
                ) else { return nil }
                return LocationCandidateEvaluation(candidate: candidate, inkStyle: inkStyle)
            }
            .min { lhs, rhs in
                let lhsScore = score(lhs.candidate.safety, analysis: analysis)
                let rhsScore = score(rhs.candidate.safety, analysis: analysis)
                if lhsScore == rhsScore {
                    return lhs.candidate.safety.order < rhs.candidate.safety.order
                }
                return lhsScore < rhsScore
            }
    }

    private static func locationCandidates(
        label: String,
        profile: PostcardOverlayProfile,
        containerSize: CGSize
    ) -> [LocationCandidate] {
        PostcardOverlayLayout.locationRegions.enumerated().map { order, region in
            let contentRect = PostcardOverlayTypography.locationRect(
                label: label,
                region: region,
                profile: profile,
                containerSize: containerSize
            )
            return LocationCandidate(
                safety: Candidate(
                    region: region,
                    rect: PostcardOverlayTypography.locationSafetyRect(
                        label: label,
                        region: region,
                        profile: profile,
                        containerSize: containerSize
                    ),
                    positionPenalty: Double(order) * 0.04,
                    order: order
                ),
                contentRect: contentRect
            )
        }
    }

    private static func messageCandidates(profile: PostcardOverlayProfile) -> [Candidate] {
        [
            Candidate(
                region: .scenicTopLeading,
                rect: PostcardOverlayGeometry.rect(for: .scenicTopLeading, profile: profile),
                positionPenalty: 0.02,
                order: 0
            ),
            Candidate(
                region: .middleLeading,
                rect: PostcardOverlayGeometry.rect(for: .middleLeading, profile: profile),
                positionPenalty: 0,
                order: 1
            ),
            Candidate(
                region: .middleTrailing,
                rect: PostcardOverlayGeometry.rect(for: .middleTrailing, profile: profile),
                positionPenalty: 0.04,
                order: 2
            ),
            Candidate(
                region: .bottomLeading,
                rect: PostcardOverlayGeometry.rect(for: .bottomLeading, profile: profile),
                positionPenalty: 0.08,
                order: 3
            ),
            Candidate(
                region: .bottomTrailing,
                rect: PostcardOverlayGeometry.rect(for: .bottomTrailing, profile: profile),
                positionPenalty: 0.12,
                order: 4
            ),
        ]
    }

    private static func wideMessageCandidates(profile: PostcardOverlayProfile) -> [Candidate] {
        [
            Candidate(region: .wideMiddleLeading, rect: PostcardOverlayGeometry.rect(for: .wideMiddleLeading, profile: profile), positionPenalty: 0, order: 0),
            Candidate(region: .wideMiddleTrailing, rect: PostcardOverlayGeometry.rect(for: .wideMiddleTrailing, profile: profile), positionPenalty: 0.04, order: 1),
            Candidate(region: .wideBottomLeading, rect: PostcardOverlayGeometry.rect(for: .wideBottomLeading, profile: profile), positionPenalty: 0.08, order: 2),
            Candidate(region: .wideBottomTrailing, rect: PostcardOverlayGeometry.rect(for: .wideBottomTrailing, profile: profile), positionPenalty: 0.12, order: 3),
        ]
    }

    private static func emergencyTopMessageCandidates(
        profile: PostcardOverlayProfile
    ) -> [Candidate] {
        [
            Candidate(
                region: .wideTopLeading,
                rect: PostcardOverlayGeometry.rect(for: .wideTopLeading, profile: profile),
                positionPenalty: 0.16,
                order: 5
            ),
            Candidate(
                region: .topTrailing,
                rect: PostcardOverlayGeometry.rect(for: .topTrailing, profile: profile),
                positionPenalty: 0.20,
                order: 6
            ),
        ]
    }

    private static func columnMessageCandidates(profile: PostcardOverlayProfile) -> [Candidate] {
        [.columnLeading, .columnTrailing].enumerated().map { index, region in
            Candidate(region: region, rect: PostcardOverlayGeometry.rect(for: region, profile: profile),
                      positionPenalty: 0.24 + Double(index) * 0.04, order: 7 + index)
        }
    }

    private static func bestCandidateIfPresent(
        in candidates: [Candidate],
        analysis: PostcardVisualAnalysis
    ) -> Candidate? {
        let safe = candidates.filter { !hasHighSaliencyOverlap($0, analysis: analysis) }
        let pool = safe.isEmpty ? candidates : safe
        return pool.min { lhs, rhs in
            let lhsScore = score(lhs, analysis: analysis)
            let rhsScore = score(rhs, analysis: analysis)
            if lhsScore == rhsScore { return lhs.order < rhs.order }
            return lhsScore < rhsScore
        }
    }

    private static func hasHighSaliencyOverlap(
        _ candidate: Candidate,
        analysis: PostcardVisualAnalysis
    ) -> Bool {
        let area = candidate.rect.width * candidate.rect.height
        guard area > 0 else { return true }
        return analysis.salientRegions.contains { salient in
            guard salient.weight >= salientObstacleWeightThreshold else { return false }
            let overlap = candidate.rect.intersection(salient.rect)
            return !overlap.isNull && !overlap.isEmpty
                && overlap.width * overlap.height / area >= salientCandidateOverlapLimit
        }
    }

    private static func hasAnyProtectedSaliencyOverlap(
        _ candidate: Candidate,
        analysis: PostcardVisualAnalysis
    ) -> Bool {
        return analysis.salientRegions.contains { salient in
            guard salient.weight >= salientObstacleWeightThreshold else { return false }
            let overlap = candidate.rect.intersection(salient.rect)
            return !overlap.isNull && !overlap.isEmpty
        }
    }

    private static func hasProtectedLocationOverlap(
        _ candidate: Candidate,
        analysis: PostcardVisualAnalysis
    ) -> Bool {
        if !analysis.protectedRegions.isEmpty {
            return analysis.protectedRegions.contains { protected in
                let overlap = candidate.rect.intersection(protected)
                return !overlap.isNull && !overlap.isEmpty
            }
        }
        return analysis.salientRegions.contains { salient in
            guard salient.weight >= salientObstacleWeightThreshold else { return false }
            let overlap = candidate.rect.intersection(salient.rect)
            return !overlap.isNull && !overlap.isEmpty
        }
    }

    private static let salientObstacleWeightThreshold: Double = 0.55
    private static let salientCandidateOverlapLimit: Double = 0.12

    private static func score(_ candidate: Candidate, analysis: PostcardVisualAnalysis) -> Double {
        let candidateArea = Double(candidate.rect.width * candidate.rect.height)
        let saliency = analysis.salientRegions.reduce(0.0) { total, salientRegion in
            let overlap = candidate.rect.intersection(salientRegion.rect)
            guard !overlap.isNull, !overlap.isEmpty, candidateArea > 0 else { return total }
            return total + Double(overlap.width * overlap.height) / candidateArea * salientRegion.weight
        }
        return saliency * 10
            + analysis.samples.colorVariance(in: candidate.rect) * 2
            + candidate.positionPenalty
    }

}
