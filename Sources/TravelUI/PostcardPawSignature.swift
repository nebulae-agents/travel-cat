import CoreGraphics
import Foundation
import SwiftUI

public struct PostcardPawVectorComponent: Equatable, Sendable {
    public let rect: CGRect
    public let rotation: CGFloat

    public init(rect: CGRect, rotation: CGFloat = 0) {
        self.rect = rect
        self.rotation = rotation
    }
}

public struct PostcardPawVectorComponents: Equatable, Sendable {
    public let pad: [PostcardPawVectorComponent]
    public let toes: [PostcardPawVectorComponent]
}

public enum PostcardPawGeometry {
    public static let pad = [
        PostcardPawVectorComponent(rect: CGRect(x: 0.27, y: 0.43, width: 0.48, height: 0.43), rotation: -0.035),
    ]

    public static let toes = [
        PostcardPawVectorComponent(rect: CGRect(x: 0.12, y: 0.24, width: 0.18, height: 0.24), rotation: -0.20),
        PostcardPawVectorComponent(rect: CGRect(x: 0.31, y: 0.09, width: 0.18, height: 0.25), rotation: -0.07),
        PostcardPawVectorComponent(rect: CGRect(x: 0.52, y: 0.08, width: 0.18, height: 0.25), rotation: 0.08),
        PostcardPawVectorComponent(rect: CGRect(x: 0.71, y: 0.23, width: 0.17, height: 0.23), rotation: 0.21),
    ]

    /// Fixed pinholes make the print feel pressed into paper without runtime randomness.
    public static let textureSpots = [
        PostcardPawVectorComponent(rect: CGRect(x: 0.36, y: 0.56, width: 0.055, height: 0.038), rotation: 0.12),
        PostcardPawVectorComponent(rect: CGRect(x: 0.48, y: 0.70, width: 0.045, height: 0.032), rotation: -0.18),
        PostcardPawVectorComponent(rect: CGRect(x: 0.61, y: 0.53, width: 0.052, height: 0.035), rotation: 0.05),
        PostcardPawVectorComponent(rect: CGRect(x: 0.37, y: 0.18, width: 0.032, height: 0.025), rotation: 0),
        PostcardPawVectorComponent(rect: CGRect(x: 0.57, y: 0.16, width: 0.030, height: 0.024), rotation: 0),
    ]

    public static func components(
        for impression: PostcardPawImpression
    ) -> PostcardPawVectorComponents {
        let parameters: (padScale: CGFloat, toeScale: CGFloat, rotation: CGFloat)
        switch impression {
        case .light: parameters = (0.94, 0.90, -0.025)
        case .balanced: parameters = (1, 1, 0)
        case .lively: parameters = (0.97, 0.96, 0.045)
        case .firm: parameters = (1.04, 1.05, 0.012)
        }
        return PostcardPawVectorComponents(
            pad: pad.map { scaled($0, by: parameters.padScale) },
            toes: toes.enumerated().map { index, toe in
                var transformed = scaled(toe, by: parameters.toeScale)
                transformed = PostcardPawVectorComponent(
                    rect: transformed.rect,
                    rotation: transformed.rotation
                        + parameters.rotation * (index.isMultiple(of: 2) ? 1 : -1)
                )
                return transformed
            }
        )
    }

    public static func path(
        in rect: CGRect,
        impression: PostcardPawImpression = .balanced
    ) -> CGPath {
        guard rect.width > 0, rect.height > 0 else { return CGMutablePath() }
        let combinedPath = CGMutablePath()
        let resolved = components(for: impression)
        for component in resolved.pad + resolved.toes {
            combinedPath.addPath(path(for: component, in: rect))
        }
        return combinedPath
    }

    private static func scaled(
        _ component: PostcardPawVectorComponent,
        by scale: CGFloat
    ) -> PostcardPawVectorComponent {
        let rect = component.rect
        return PostcardPawVectorComponent(
            rect: CGRect(
                x: rect.midX - rect.width * scale / 2,
                y: rect.midY - rect.height * scale / 2,
                width: rect.width * scale,
                height: rect.height * scale
            ),
            rotation: component.rotation
        )
    }

    static func path(for component: PostcardPawVectorComponent, in rect: CGRect) -> CGPath {
        let componentRect = CGRect(
            x: rect.minX + component.rect.minX * rect.width,
            y: rect.minY + component.rect.minY * rect.height,
            width: component.rect.width * rect.width,
            height: component.rect.height * rect.height
        )
        var transform = CGAffineTransform.identity
        if component.rotation != 0 {
            transform = transform
                .translatedBy(x: componentRect.midX, y: componentRect.midY)
                .rotated(by: component.rotation)
                .translatedBy(x: -componentRect.midX, y: -componentRect.midY)
        }
        let path = CGMutablePath()
        path.addEllipse(in: componentRect, transform: transform)
        return path
    }
}

public enum PostcardPawImpression: Equatable, Sendable {
    case light
    case balanced
    case lively
    case firm
}

public struct PostcardPawSignatureStyle: Equatable, Sendable {
    public static let isAccessibilityHidden = true

    public let impression: PostcardPawImpression
    public let color: PostcardInkColor
    public let opacity: Double
    public let textureStrength: Double

    public init(handwriting: PostcardHandwritingStyle, ink: PostcardInkStyle) {
        switch handwriting.family {
        case .reflective:
            impression = .light
            textureStrength = 0.42
        case .playful:
            impression = .lively
            textureStrength = 0.30
        case .bold:
            impression = .firm
            textureStrength = 0.18
        case .serene:
            impression = .balanced
            textureStrength = 0.26
        }
        color = ink.foreground
        opacity = min(max(ink.pawOpacity, 0.68), 0.82)
    }
}

public struct PostcardPawSignature: Equatable, Sendable {
    public let placement: PostcardPawPlacement
    public let style: PostcardPawSignatureStyle

    public init(placement: PostcardPawPlacement, style: PostcardPawSignatureStyle) {
        self.placement = placement
        self.style = style
    }
}

public enum PostcardPawPlacementMode: Equatable, Sendable {
    case inline
    case signatureLine
    case omitted
}

public struct PostcardPawPlacement: Equatable, Sendable {
    public let mode: PostcardPawPlacementMode
    public let pawFrame: CGRect
    public let textFrame: CGRect
    public let textBlockFrame: CGRect
    public let messageFits: Bool
    public let measuredLineCount: Int

    public init(
        mode: PostcardPawPlacementMode,
        pawFrame: CGRect,
        textFrame: CGRect,
        textBlockFrame: CGRect? = nil,
        messageFits: Bool,
        measuredLineCount: Int
    ) {
        self.mode = mode
        self.pawFrame = pawFrame
        self.textFrame = textFrame
        self.textBlockFrame = textBlockFrame ?? textFrame
        self.messageFits = messageFits
        self.measuredLineCount = measuredLineCount
    }

    public static let omitted = PostcardPawPlacement(
        mode: .omitted,
        pawFrame: .zero,
        textFrame: .zero,
        textBlockFrame: .zero,
        messageFits: true,
        measuredLineCount: 1
    )
}

public enum PostcardPawLayout {
    public static func resolve(
        message: String,
        messageFrame: CGRect,
        signatureBounds: CGRect? = nil,
        fontSize: CGFloat,
        typography: PostcardHandwritingStyle,
        profile: PostcardOverlayProfile,
        lineLimit: Int? = nil,
        protectedFrames: [CGRect] = []
    ) -> PostcardPawPlacement {
        let lineLimit = lineLimit ?? (profile == .detail ? 3 : 2)
        let safeFrame = messageFrame.standardized
        let safeSignatureBounds = (signatureBounds ?? safeFrame).standardized
        guard safeFrame.width > 0, safeFrame.height > 0 else {
            return PostcardPawPlacement(
                mode: .omitted,
                pawFrame: .zero,
                textFrame: .zero,
                textBlockFrame: .zero,
                messageFits: message.isEmpty,
                measuredLineCount: message.isEmpty ? 1 : 0
            )
        }
        let textLayout = PostcardMessageLineLayout.resolve(
            message: message,
            frame: safeFrame,
            fontSize: fontSize,
            typography: typography,
            lineLimit: lineLimit
        )
        return resolve(
            textLayout: textLayout,
            signatureBounds: safeSignatureBounds,
            profile: profile,
            protectedFrames: protectedFrames
        )
    }

    public static func resolve(
        textLayout: PostcardMessageLineLayout,
        signatureBounds: CGRect? = nil,
        profile: PostcardOverlayProfile,
        protectedFrames: [CGRect] = []
    ) -> PostcardPawPlacement {
        let safeFrame = textLayout.frame.standardized
        let safeSignatureBounds = (signatureBounds ?? safeFrame).standardized
        let obstacles = protectedFrames
            .map(\.standardized)
            .filter { !$0.isNull && !$0.isEmpty }
        func overlapsProtectedContent(_ frame: CGRect) -> Bool {
            obstacles.contains { $0.intersects(frame) }
        }
        func nearestLeadingFrame(
            startingX: CGFloat,
            y: CGFloat,
            size: CGFloat,
            bounds: CGRect,
            clearance: CGFloat
        ) -> CGRect? {
            let candidates = [max(startingX, bounds.minX)] + obstacles.compactMap { obstacle -> CGFloat? in
                let row = CGRect(x: bounds.minX, y: y, width: bounds.width, height: size)
                guard obstacle.intersects(row), obstacle.maxX >= startingX else { return nil }
                return obstacle.maxX + clearance
            }
            for x in candidates.sorted() {
                let frame = CGRect(x: x, y: y, width: size, height: size)
                if bounds.contains(frame), !overlapsProtectedContent(frame) { return frame }
            }
            return nil
        }
        func closestLargestFrame(_ frames: [CGRect], startingX: CGFloat) -> CGRect? {
            frames.min { lhs, rhs in
                let lhsDistance = lhs.minX - startingX
                let rhsDistance = rhs.minX - startingX
                if abs(lhsDistance - rhsDistance) < 0.000_001 { return lhs.width > rhs.width }
                return lhsDistance < rhsDistance
            }
        }
        let metrics = textLayout.lines.map(\.width)
        let lineHeight = textLayout.lineHeight
        let messageFits = textLayout.fits
        let textFrame = occupiedTextFrame(
            widths: metrics,
            lineHeight: lineHeight,
            in: safeFrame
        )
        guard messageFits, !textLayout.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return PostcardPawPlacement(
                mode: .omitted,
                pawFrame: .zero,
                textFrame: textFrame,
                textBlockFrame: textFrame,
                messageFits: messageFits,
                measuredLineCount: metrics.count
            )
        }

        let pawSizes = pawSizes(fontSize: textLayout.font.pointSize, profile: profile)
        let gap = profile == .detail ? max(textLayout.font.pointSize * 0.20, 4) : max(textLayout.font.pointSize * 0.16, 2)
        let lastWidth = min(metrics.last ?? 0, safeFrame.width)
        let lastLineY = safeFrame.minY + CGFloat(metrics.count - 1) * lineHeight
        let lastLineTextFrame = CGRect(
            x: safeFrame.minX,
            y: lastLineY,
            width: lastWidth,
            height: min(lineHeight, safeFrame.maxY - lastLineY)
        )
        let startingX = safeFrame.minX + lastWidth + gap
        let inlineFrames = pawSizes.compactMap { pawSize -> CGRect? in
            let inlineY = lastLineY + max((lineHeight - pawSize) / 2, 0)
            if let inlineFrame = nearestLeadingFrame(
                startingX: startingX,
                y: inlineY,
                size: pawSize,
                bounds: safeFrame,
                clearance: gap
            ), !inlineFrame.intersects(lastLineTextFrame) {
                return inlineFrame
            }
            return nil
        }
        if let inlineFrame = closestLargestFrame(inlineFrames, startingX: startingX) {
            return PostcardPawPlacement(
                mode: .inline,
                pawFrame: inlineFrame,
                textFrame: lastLineTextFrame,
                textBlockFrame: textFrame,
                messageFits: true,
                measuredLineCount: metrics.count
            )
        }

        let signatureLineY = safeFrame.minY + CGFloat(metrics.count) * lineHeight
        if metrics.count < textLayout.lineLimit {
            let signatureFrames = pawSizes.compactMap { pawSize -> CGRect? in
                let signatureY = signatureLineY + max((lineHeight - pawSize) / 2, 0)
                let signatureFrame = nearestLeadingFrame(
                    startingX: safeSignatureBounds.minX,
                    y: signatureY,
                    size: pawSize,
                    bounds: safeSignatureBounds,
                    clearance: gap
                )
                if let signatureFrame,
                   safeSignatureBounds.contains(signatureFrame),
                   !signatureFrame.intersects(textFrame),
                   !overlapsProtectedContent(signatureFrame) {
                    return signatureFrame
                }
                return nil
            }
            let signatureFrame = closestLargestFrame(
                signatureFrames,
                startingX: safeSignatureBounds.minX
            )
            if let signatureFrame {
                return PostcardPawPlacement(
                    mode: .signatureLine,
                    pawFrame: signatureFrame,
                    textFrame: textFrame,
                    textBlockFrame: textFrame,
                    messageFits: true,
                    measuredLineCount: metrics.count
                )
            }
        }

        return PostcardPawPlacement(
            mode: .omitted,
            pawFrame: .zero,
            textFrame: textFrame,
            textBlockFrame: textFrame,
            messageFits: true,
            measuredLineCount: metrics.count
        )
    }

    private static func pawSizes(
        fontSize: CGFloat,
        profile: PostcardOverlayProfile
    ) -> [CGFloat] {
        let proposed = fontSize * 0.78
        let minimum = minimumPawSize(profile: profile)
        let previousMaximum: CGFloat = profile == .compact ? 12 : 20
        let previousInitial = min(max(proposed, minimum), previousMaximum)
        let enlargedMaximum: CGFloat = profile == .compact ? 14.4 : 24
        let enlargedInitial = min(previousInitial * 1.20, enlargedMaximum)
        var result: [CGFloat] = []

        func appendUnique(_ size: CGFloat) {
            guard !result.contains(where: { abs($0 - size) < 0.000_001 }) else { return }
            result.append(size)
        }

        var size = enlargedInitial
        while size > previousInitial {
            appendUnique(size)
            size = max(size - 0.5, previousInitial)
        }

        size = previousInitial
        while size > minimum {
            appendUnique(size)
            size = max(size - 0.5, minimum)
        }
        appendUnique(minimum)
        return result
    }

    private static func minimumPawSize(profile: PostcardOverlayProfile) -> CGFloat {
        profile == .compact ? 7 : 10
    }

    private static func occupiedTextFrame(
        widths: [CGFloat],
        lineHeight: CGFloat,
        in frame: CGRect
    ) -> CGRect {
        guard let maximumWidth = widths.max() else { return .zero }
        let width = min(max(maximumWidth, 0), frame.width)
        return CGRect(
            x: frame.minX,
            y: frame.minY,
            width: width,
            height: min(CGFloat(widths.count) * lineHeight, frame.height)
        )
    }

}

public struct PostcardPawSignatureView: View {
    public let signature: PostcardPawSignature

    public init(signature: PostcardPawSignature) {
        self.signature = signature
    }

    public var body: some View {
        if signature.placement.mode != .omitted {
            let style = signature.style
            let frame = signature.placement.pawFrame
            Canvas { context, size in
                let bounds = CGRect(origin: .zero, size: size)
                let ink = Color(
                        red: style.color.red,
                        green: style.color.green,
                        blue: style.color.blue
                    )
                let base = CGMutablePath()
                let components = PostcardPawGeometry.components(for: style.impression)
                for component in components.pad + components.toes {
                    base.addPath(PostcardPawGeometry.path(for: component, in: bounds))
                }
                context.blendMode = .normal
                context.fill(Path(base), with: .color(ink.opacity(style.opacity)))
                context.stroke(
                    Path(base),
                    with: .color(ink.opacity(style.opacity * 0.85)),
                    lineWidth: style.impression == .lively ? 1.1 : 0.8
                )
                context.drawLayer { layer in
                    layer.blendMode = .destinationOut
                    for spot in PostcardPawGeometry.textureSpots {
                        let textureOpacity = max(0, min(style.textureStrength * style.opacity * 0.28, 1))
                        layer.fill(
                            Path(PostcardPawGeometry.path(for: spot, in: bounds)),
                            with: .color(.black.opacity(textureOpacity))
                        )
                    }
                }
            }
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
            .accessibilityHidden(PostcardPawSignatureStyle.isAccessibilityHidden)
        }
    }
}
