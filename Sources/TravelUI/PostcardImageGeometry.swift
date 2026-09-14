import CoreGraphics
import SwiftUI

enum PostcardImageContentMode: Equatable, Sendable {
    case subjectPreservingFill
    case fit
}

struct PostcardImageGeometry: Equatable, Sendable {
    static let normalizedSafetyMargin: CGFloat = 0.015

    let imageSize: CGSize
    let containerSize: CGSize
    let contentMode: PostcardImageContentMode
    let imageFrame: CGRect
    let visibleCanvas: CGRect

    init(
        imageSize: CGSize,
        containerSize: CGSize,
        analysis: PostcardVisualAnalysis?
    ) {
        self.imageSize = imageSize
        self.containerSize = containerSize

        let container = CGRect(origin: .zero, size: containerSize)
        guard imageSize.width.isFinite, imageSize.height.isFinite,
              containerSize.width.isFinite, containerSize.height.isFinite,
              imageSize.width > 0, imageSize.height > 0,
              containerSize.width > 0, containerSize.height > 0 else {
            contentMode = .fit
            imageFrame = .zero
            visibleCanvas = .zero
            return
        }

        guard let analysis, analysis.samples.isValid else {
            let frame = Self.centeredFrame(
                imageSize: imageSize, containerSize: containerSize, filling: false
            )
            contentMode = .fit
            imageFrame = frame
            visibleCanvas = frame.intersection(container)
            return
        }

        let anchors = analysis.protectedRegions + analysis.foregroundRegions
        guard !anchors.isEmpty else {
            let frame = Self.centeredFrame(
                imageSize: imageSize, containerSize: containerSize, filling: false
            )
            contentMode = .fit
            imageFrame = frame
            visibleCanvas = frame.intersection(container)
            return
        }

        let credibleAnimals = analysis.salientRegions.compactMap { region -> CGRect? in
            guard region.source == .animal,
                  region.weight >= 0.65,
                  region.rect.width * region.rect.height <= 0.55 else { return nil }
            return region.rect
        }
        let protected = (anchors + credibleAnimals).map(Self.expandedAndClipped)
        let union = protected.dropFirst().reduce(protected[0]) { $0.union($1) }
        let centered = Self.centeredFrame(
            imageSize: imageSize, containerSize: containerSize, filling: true
        )
        let minimumX = max(containerSize.width - centered.width, -union.minX * centered.width)
        let maximumX = min(0, containerSize.width - union.maxX * centered.width)
        let minimumY = max(containerSize.height - centered.height, -union.minY * centered.height)
        let maximumY = min(0, containerSize.height - union.maxY * centered.height)

        guard minimumX <= maximumX, minimumY <= maximumY else {
            let frame = Self.centeredFrame(
                imageSize: imageSize, containerSize: containerSize, filling: false
            )
            contentMode = .fit
            imageFrame = frame
            visibleCanvas = frame.intersection(container)
            return
        }

        let origin = CGPoint(
            x: min(max(centered.minX, minimumX), maximumX),
            y: min(max(centered.minY, minimumY), maximumY)
        )
        let frame = CGRect(origin: origin, size: centered.size)
        contentMode = .subjectPreservingFill
        imageFrame = frame
        visibleCanvas = frame.intersection(container)
    }

    init(imageSize: CGSize, containerSize: CGSize, imageFrame: CGRect) {
        self.imageSize = imageSize
        self.containerSize = containerSize
        self.imageFrame = imageFrame
        let container = CGRect(origin: .zero, size: containerSize)
        self.visibleCanvas = imageFrame.intersection(container)
        self.contentMode = imageFrame.contains(container) ? .subjectPreservingFill : .fit
    }

    func displayRect(forImageNormalized rect: CGRect) -> CGRect {
        guard imageFrame.width > 0, imageFrame.height > 0,
              visibleCanvas.width > 0, visibleCanvas.height > 0 else { return .zero }
        let absolute = CGRect(
            x: imageFrame.minX + rect.minX * imageFrame.width,
            y: imageFrame.minY + rect.minY * imageFrame.height,
            width: rect.width * imageFrame.width,
            height: rect.height * imageFrame.height
        ).intersection(visibleCanvas)
        guard !absolute.isNull, !absolute.isEmpty else { return .zero }
        return CGRect(
            x: (absolute.minX - visibleCanvas.minX) / visibleCanvas.width,
            y: (absolute.minY - visibleCanvas.minY) / visibleCanvas.height,
            width: absolute.width / visibleCanvas.width,
            height: absolute.height / visibleCanvas.height
        )
    }

    func imageRect(forDisplayNormalized rect: CGRect) -> CGRect {
        guard imageFrame.width > 0, imageFrame.height > 0,
              visibleCanvas.width > 0, visibleCanvas.height > 0 else { return .zero }
        return CGRect(
            x: (visibleCanvas.minX + rect.minX * visibleCanvas.width - imageFrame.minX) / imageFrame.width,
            y: (visibleCanvas.minY + rect.minY * visibleCanvas.height - imageFrame.minY) / imageFrame.height,
            width: rect.width * visibleCanvas.width / imageFrame.width,
            height: rect.height * visibleCanvas.height / imageFrame.height
        )
    }

    func displayAnalysis(_ analysis: PostcardVisualAnalysis) -> PostcardVisualAnalysis {
        let displayedRegions = analysis.salientRegions.compactMap { region -> PostcardSalientRegion? in
            let rect = displayRect(forImageNormalized: region.rect)
            guard !rect.isEmpty else { return nil }
            return PostcardSalientRegion(rect: rect, weight: region.weight, source: region.source)
        }
        let localizedHeuristics = displayedRegions.filter { region in
            region.source == .heuristic
                && region.weight >= 0.70
                && region.rect.width * region.rect.height <= 0.55
        }
        let salient = displayedRegions.filter { region in
            let isLowConfidencePanorama = region.rect.width * region.rect.height > 0.55
                && region.weight < 0.65
            switch region.source {
            case .attention:
                return !isLowConfidencePanorama
            case .animal:
                guard isLowConfidencePanorama else { return true }
                return !localizedHeuristics.contains { heuristic in
                    let overlap = region.rect.intersection(heuristic.rect)
                    guard !overlap.isNull, !overlap.isEmpty else { return false }
                    let heuristicArea = heuristic.rect.width * heuristic.rect.height
                    return overlap.width * overlap.height >= heuristicArea * 0.50
                }
            case .heuristic:
                return true
            }
        }
        let columns = analysis.samples.columns
        let rows = analysis.samples.rows
        guard columns > 0, rows > 0 else { return analysis }
        var samples: [PostcardPixelSample] = []
        samples.reserveCapacity(columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let displayCell = CGRect(
                    x: CGFloat(column) / CGFloat(columns),
                    y: CGFloat(row) / CGFloat(rows),
                    width: 1 / CGFloat(columns),
                    height: 1 / CGFloat(rows)
                )
                samples.append(analysis.samples.average(in: imageRect(forDisplayNormalized: displayCell)))
            }
        }
        let credibleAnimalProtection: [CGRect]
        if analysis.protectedRegions.isEmpty && analysis.foregroundRegions.isEmpty {
            credibleAnimalProtection = []
        } else {
            credibleAnimalProtection = salient.compactMap { region in
                guard region.source == .animal,
                      region.weight >= 0.65,
                      region.rect.width * region.rect.height <= 0.55 else { return nil }
                return region.rect
            }
        }
        return PostcardVisualAnalysis(
            salientRegions: salient,
            samples: PostcardSampleGrid(columns: columns, rows: rows, values: samples),
            protectedRegions: analysis.protectedRegions.compactMap {
                let displayed = displayRect(forImageNormalized: $0)
                return displayed.isEmpty ? nil : displayed
            } + credibleAnimalProtection,
            foregroundRegions: analysis.foregroundRegions.compactMap {
                let displayed = displayRect(forImageNormalized: $0)
                return displayed.isEmpty ? nil : displayed
            }
        )
    }

    private static func centeredFrame(
        imageSize: CGSize,
        containerSize: CGSize,
        filling: Bool
    ) -> CGRect {
        let widthScale = containerSize.width / imageSize.width
        let heightScale = containerSize.height / imageSize.height
        let scale = filling ? max(widthScale, heightScale) : min(widthScale, heightScale)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (containerSize.width - size.width) / 2,
            y: (containerSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    private static func expandedAndClipped(_ rect: CGRect) -> CGRect {
        rect.insetBy(dx: -normalizedSafetyMargin, dy: -normalizedSafetyMargin)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}

@MainActor
struct PostcardRenderedImage: View {
    let image: CGImage
    let geometry: PostcardImageGeometry

    var body: some View {
        ZStack(alignment: .topLeading) {
            Image(decorative: image, scale: 1)
                .resizable()
                .frame(width: geometry.imageFrame.width, height: geometry.imageFrame.height)
                .position(x: geometry.imageFrame.midX, y: geometry.imageFrame.midY)
        }
        .frame(width: geometry.containerSize.width, height: geometry.containerSize.height)
        .clipped()
    }
}
