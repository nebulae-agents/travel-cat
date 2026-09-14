import CoreGraphics

public enum PostcardMessagePlacementSearch {
    private struct TypographyKey: Hashable {
        let width: CGFloat
        let height: CGFloat
        let lineLimit: Int
    }

    public struct Request: Equatable, Sendable {
        public let message: String
        public let analysis: PostcardVisualAnalysis
        public let profile: PostcardOverlayProfile
        public let containerSize: CGSize
        public let handwriting: PostcardHandwritingStyle

        public init(
            message: String,
            analysis: PostcardVisualAnalysis,
            profile: PostcardOverlayProfile,
            containerSize: CGSize,
            handwriting: PostcardHandwritingStyle
        ) {
            self.message = message
            self.analysis = analysis
            self.profile = profile
            self.containerSize = containerSize
            self.handwriting = handwriting
        }
    }

    public struct Placement: Equatable, Sendable {
        public let normalizedRect: CGRect
        public let lineLimit: Int
        public let fontSize: CGFloat
    }

    public struct Result: Equatable, Sendable {
        public let placement: Placement?
        public let evaluatedCandidateCount: Int
        public let typographyEvaluationCount: Int
        public let fallbackReason: PostcardMessageFallbackReason?
    }

    public static func search(_ request: Request) -> Result {
        guard request.containerSize.width > 0, request.containerSize.height > 0 else {
            return Result(
                placement: nil,
                evaluatedCandidateCount: 0,
                typographyEvaluationCount: 0,
                fallbackReason: .textDoesNotFit
            )
        }
        let maximumFrame = pixelFrame(
            CGRect(
                x: 0,
                y: 0,
                width: 0.76,
                height: request.profile == .detail ? 0.80 : 0.58
            ),
            in: request.containerSize
        )
        let maximumFit = PostcardOverlayTypography.fit(
            message: request.message,
            frame: maximumFrame,
            lineLimit: 4,
            profile: request.profile,
            handwriting: request.handwriting
        )
        guard maximumFit.fitsVertically else {
            return Result(
                placement: nil,
                evaluatedCandidateCount: 0,
                typographyEvaluationCount: 0,
                fallbackReason: .textDoesNotFit
            )
        }
        let protected = request.analysis.protectedRegions + request.analysis.foregroundRegions
        let candidates = normalizedCandidates(profile: request.profile)
        var evaluated = 0
        var typographyEvaluations = 0
        var typographyCache: [TypographyKey: PostcardTypographyFit] = [:]
        var hadSubjectClearGeometry = false
        var placements: [(placement: Placement, score: Double, order: Int)] = []

        for (order, rect) in candidates.enumerated() {
            evaluated += 1
            guard !protected.contains(where: rect.intersects) else { continue }
            hadSubjectClearGeometry = true
            let frame = pixelFrame(rect, in: request.containerSize)
            for lineLimit in 2...4 {
                let key = TypographyKey(
                    width: frame.width,
                    height: frame.height,
                    lineLimit: lineLimit
                )
                let fit: PostcardTypographyFit
                if let cached = typographyCache[key] {
                    fit = cached
                } else {
                    typographyEvaluations += 1
                    fit = PostcardOverlayTypography.fit(
                        message: request.message,
                        frame: frame,
                        lineLimit: lineLimit,
                        profile: request.profile,
                        handwriting: request.handwriting
                    )
                    typographyCache[key] = fit
                }
                guard fit.fitsVertically, fit.requiredLineCount <= lineLimit else { continue }
                let variance = request.analysis.samples.colorVariance(in: rect)
                let candidateArea = Double(rect.width * rect.height)
                let saliency = request.analysis.salientRegions.reduce(0.0) { sum, region in
                    let overlap = rect.intersection(region.rect)
                    guard !overlap.isNull, !overlap.isEmpty, candidateArea > 0 else {
                        return sum
                    }
                    return sum
                        + Double(overlap.width * overlap.height) / candidateArea * region.weight
                }
                let fontPenalty = Double((request.profile == .detail ? 30 : 16) - fit.fontSize) * 0.4
                let linePenalty = Double(lineLimit - 2) * 0.08
                let positionPenalty = Double(rect.minY) * 0.03 + Double(rect.minX) * 0.01
                placements.append((
                    Placement(
                        normalizedRect: rect,
                        lineLimit: lineLimit,
                        fontSize: fit.fontSize
                    ),
                    variance * 2 + saliency * 6 + fontPenalty + linePenalty + positionPenalty,
                    order
                ))
            }
        }

        let best = placements.min { lhs, rhs in
            lhs.score == rhs.score ? lhs.order < rhs.order : lhs.score < rhs.score
        }
        return Result(
            placement: best?.placement,
            evaluatedCandidateCount: evaluated,
            typographyEvaluationCount: typographyEvaluations,
            fallbackReason: best == nil
                ? (hadSubjectClearGeometry ? .textDoesNotFit : .subjectConflict)
                : nil
        )
    }

    private static func normalizedCandidates(profile: PostcardOverlayProfile) -> [CGRect] {
        let widths: [CGFloat] = [0.76, 0.68, 0.60, 0.58, 0.54, 0.48]
        let heights: [CGFloat] = profile == .detail
            ? [0.80, 0.66, 0.44, 0.38, 0.32, 0.28]
            : [0.58, 0.54, 0.50, 0.46, 0.42, 0.38, 0.34]
        let margin: CGFloat = profile == .detail ? 0.04 : 0.02
        var result: [CGRect] = []
        for width in widths {
            let xValues = unique([margin, (1 - width) / 2, 1 - margin - width])
            for height in heights {
                let yValues = unique([margin, (1 - height) / 2, 1 - margin - height])
                for y in yValues {
                    for x in xValues {
                        let rect = CGRect(x: x, y: y, width: width, height: height)
                        if rect.minX >= 0, rect.minY >= 0,
                           rect.maxX <= 1, rect.maxY <= 1 {
                            result.append(rect)
                        }
                    }
                }
            }
        }
        // A square detail card can have a clear sky strip above the subject.
        // Add only eight bounded candidates rather than multiplying the grid.
        if profile == .detail {
            for width: CGFloat in [0.92, 0.84] {
                for height: CGFloat in [0.22, 0.20] {
                    for y: CGFloat in [0.02, 0.98 - height] {
                        result.append(CGRect(x: (1 - width) / 2, y: y, width: width, height: height))
                    }
                }
            }
        }
        return result
    }

    private static func unique(_ values: [CGFloat]) -> [CGFloat] {
        values.reduce(into: []) { result, value in
            if !result.contains(where: { abs($0 - value) < 0.000_001 }) {
                result.append(value)
            }
        }
    }

    private static func pixelFrame(_ rect: CGRect, in size: CGSize) -> CGRect {
        CGRect(
            x: rect.minX * size.width,
            y: rect.minY * size.height,
            width: rect.width * size.width,
            height: rect.height * size.height
        )
    }
}
