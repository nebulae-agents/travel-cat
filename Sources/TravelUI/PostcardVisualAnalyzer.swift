import CoreGraphics
import CoreVideo
import Vision

public enum PostcardVisualAnalyzerError: Error, Equatable, Sendable {
    case bitmapContextCreationFailed
    case malformedBitmapStorage
}

public enum PostcardVisualAnalyzer {
    public static let sampleColumns = 12
    public static let sampleRows = 8

    private static let bytesPerPixel = 4
    private static let expectedByteCount = sampleColumns * sampleRows * bytesPerPixel
    private static let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
        CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    )

    private struct LocationContrastAccumulator {
        private var compactDark = Entry()
        private var compactLight = Entry()
        private var detailDark = Entry()
        private var detailLight = Entry()
        private var hasSamples = false
        private var isFailClosed = false
        private var maximumSourceChroma = 0.0
        private var hasSourceChromaticFringeHazard = false

        mutating func include(_ background: PostcardColorSample, failClosed: Bool = false) {
            hasSamples = true
            isFailClosed = isFailClosed || failClosed
            maximumSourceChroma = max(
                maximumSourceChroma,
                max(background.red, background.green, background.blue)
                    - min(background.red, background.green, background.blue)
            )
            hasSourceChromaticFringeHazard = hasSourceChromaticFringeHazard
                || PostcardLocationContrastWitnesses.isChromaticFringeHazard(background)
            let ratios = PostcardLocationContrast.ratios(background: background)
            compactDark.include(background, ratio: ratios.compactDark)
            compactLight.include(background, ratio: ratios.compactLight)
            detailDark.include(background, ratio: ratios.detailDark)
            detailLight.include(background, ratio: ratios.detailLight)
        }

        var witnesses: PostcardLocationContrastWitnesses {
            guard hasSamples else {
                return PostcardLocationContrastWitnesses(backgroundSamples: [])
            }
            return PostcardLocationContrastWitnesses(
                compactDarkBackground: compactDark.background,
                compactLightBackground: compactLight.background,
                detailDarkBackground: detailDark.background,
                detailLightBackground: detailLight.background,
                maximumSourceChroma: maximumSourceChroma,
                hasSourceChromaticFringeHazard: hasSourceChromaticFringeHazard,
                isFailClosed: isFailClosed
            )
        }

        private struct Entry {
            var ratio = Double.infinity
            var background = PostcardColorSample(red: 0, green: 0, blue: 0)

            mutating func include(_ candidate: PostcardColorSample, ratio candidateRatio: Double) {
                guard candidateRatio < ratio else { return }
                ratio = candidateRatio
                background = candidate
            }
        }
    }

    public static func analyze(_ image: CGImage) throws -> PostcardVisualAnalysis {
        try Task.checkCancellation()
        var rgba = [UInt8](repeating: 0, count: expectedByteCount)
        let rendered = rgba.withUnsafeMutableBytes { storage -> Bool in
            guard let baseAddress = storage.baseAddress,
                  let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                    data: baseAddress,
                    width: sampleColumns,
                    height: sampleRows,
                    bitsPerComponent: 8,
                    bytesPerRow: sampleColumns * bytesPerPixel,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo.rawValue
                  ) else { return false }

            context.setBlendMode(.copy)
            context.interpolationQuality = .high
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: sampleColumns, height: sampleRows)
            )
            return true
        }
        guard rendered else {
            throw PostcardVisualAnalyzerError.bitmapContextCreationFailed
        }
        try Task.checkCancellation()
        let averagedSamples = try samples(fromRGBABytes: rgba)
        let witnesses = try locationContrastWitnesses(in: image)
        let values = zip(averagedSamples.values, witnesses).map { average, cellWitnesses in
            PostcardPixelSample(
                luminance: average.luminance,
                red: average.red,
                green: average.green,
                blue: average.blue,
                locationContrastWitnesses: cellWitnesses
            )
        }
        let samples = PostcardSampleGrid(
            columns: sampleColumns,
            rows: sampleRows,
            values: values
        )
        try Task.checkCancellation()
        let regions = try salientRegions(in: image, samples: samples)
        try Task.checkCancellation()

        return PostcardVisualAnalysis(
            salientRegions: regions.salient,
            samples: samples,
            foregroundRegions: regions.foreground
        )
    }

    static func samples(fromRGBABytes bytes: [UInt8]) throws -> PostcardSampleGrid {
        try Task.checkCancellation()
        guard bytes.count == expectedByteCount else {
            throw PostcardVisualAnalyzerError.malformedBitmapStorage
        }

        var values: [PostcardPixelSample] = []
        values.reserveCapacity(sampleColumns * sampleRows)
        for offset in stride(from: 0, to: bytes.count, by: bytesPerPixel) {
            let alpha = Double(bytes[offset + 3]) / 255
            let red = unpremultiplied(bytes[offset], alpha: alpha)
            let green = unpremultiplied(bytes[offset + 1], alpha: alpha)
            let blue = unpremultiplied(bytes[offset + 2], alpha: alpha)
            values.append(PostcardPixelSample(
                luminance: PostcardTextContrast.relativeLuminance(
                    red: red,
                    green: green,
                    blue: blue
                ),
                red: red,
                green: green,
                blue: blue
            ))
        }
        try Task.checkCancellation()
        return PostcardSampleGrid(columns: sampleColumns, rows: sampleRows, values: values)
    }

    private static func locationContrastWitnesses(
        in image: CGImage
    ) throws -> [PostcardLocationContrastWitnesses] {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              width <= Int.max / height,
              width * height <= Int.max / bytesPerPixel else {
            throw PostcardVisualAnalyzerError.malformedBitmapStorage
        }
        var rgba = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        let rendered = rgba.withUnsafeMutableBytes { storage -> Bool in
            guard let baseAddress = storage.baseAddress,
                  let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * bytesPerPixel,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo.rawValue
                  ) else { return false }
            context.setBlendMode(.copy)
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else {
            throw PostcardVisualAnalyzerError.bitmapContextCreationFailed
        }

        var cells = [LocationContrastAccumulator](
            repeating: LocationContrastAccumulator(),
            count: sampleColumns * sampleRows
        )
        for row in 0..<height {
            try Task.checkCancellation()
            let sampleRow = min(row * sampleRows / height, sampleRows - 1)
            for column in 0..<width {
                let offset = (row * width + column) * bytesPerPixel
                let alpha = Double(rgba[offset + 3]) / 255
                let cellIndex = sampleRow * sampleColumns
                    + min(column * sampleColumns / width, sampleColumns - 1)
                let colors: [PostcardColorSample]
                if alpha < 1 {
                    colors = [
                        PostcardColorSample(red: 0, green: 0, blue: 0),
                        PostcardColorSample(red: 1, green: 1, blue: 1),
                    ]
                } else {
                    colors = [PostcardColorSample(
                        red: unpremultiplied(rgba[offset], alpha: alpha),
                        green: unpremultiplied(rgba[offset + 1], alpha: alpha),
                        blue: unpremultiplied(rgba[offset + 2], alpha: alpha)
                    )]
                }
                for color in colors {
                    cells[cellIndex].include(color, failClosed: alpha < 1)
                }
            }
        }
        return cells.map(\.witnesses)
    }

    private static func unpremultiplied(_ component: UInt8, alpha: Double) -> Double {
        guard alpha > 0 else { return 0 }
        return min(max((Double(component) / 255) / alpha, 0), 1)
    }

    private static func salientRegions(
        in image: CGImage,
        samples: PostcardSampleGrid
    ) throws -> (salient: [PostcardSalientRegion], foreground: [CGRect]) {
        try Task.checkCancellation()
        return try autoreleasepool {
            let attentionRequest = VNGenerateAttentionBasedSaliencyImageRequest()
            let animalRequest = VNRecognizeAnimalsRequest()
            let foregroundRequest = VNGenerateObjectnessBasedSaliencyImageRequest()
            let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
            try Task.checkCancellation()
            try? handler.perform([attentionRequest])
            try Task.checkCancellation()
            try? handler.perform([animalRequest])
            try Task.checkCancellation()
            try? handler.perform([foregroundRequest])
            try Task.checkCancellation()

            var candidates = (attentionRequest.results ?? []).flatMap { observation in
                (observation.salientObjects ?? []).compactMap { object -> CanonicalRegion? in
                    guard let region = visionRegion(
                        fromVisionRect: object.boundingBox,
                        confidence: object.confidence,
                        source: .attention
                    ) else { return nil }
                    return CanonicalRegion(
                        rect: region.rect,
                        weight: region.weight,
                        source: region.source
                    )
                }
            }
            candidates.append(contentsOf: (animalRequest.results ?? []).compactMap { observation in
                let confidence = observation.labels.map(\.confidence).max() ?? observation.confidence
                guard let region = visionRegion(
                    fromVisionRect: observation.boundingBox,
                    confidence: confidence,
                    source: .animal
                ) else { return nil }
                return CanonicalRegion(
                    rect: region.rect,
                    weight: region.weight,
                    source: region.source
                )
            })
            candidates.append(contentsOf: darkForegroundRegions(in: samples).map {
                CanonicalRegion(rect: $0.rect, weight: $0.weight, source: .heuristic)
            })
            candidates.append(contentsOf: chromaticLandmarkRegions(in: samples).map {
                CanonicalRegion(rect: $0.rect, weight: $0.weight, source: .heuristic)
            })
            let regions = candidates.sorted().map {
                PostcardSalientRegion(rect: $0.rect, weight: $0.weight, source: $0.source)
            }
            try Task.checkCancellation()
            var foreground = (foregroundRequest.results ?? []).flatMap { observation in
                (observation.salientObjects ?? []).compactMap { object -> CGRect? in
                    guard object.confidence >= 0.5,
                          let region = salientRegion(fromVisionRect: object.boundingBox, confidence: object.confidence)
                    else { return nil }
                    // Include ears/edges beyond the tightly fitted foreground box.
                    return region.rect.insetBy(dx: -0.035, dy: -0.035)
                }
            }
            if foreground.isEmpty {
                let instanceRequest = VNGenerateForegroundInstanceMaskRequest()
                try Task.checkCancellation()
                try? handler.perform([instanceRequest])
                try Task.checkCancellation()
                foreground = try (instanceRequest.results ?? []).flatMap { observation in
                    try foregroundInstanceRects(from: observation.instanceMask)
                }.map { rect in
                    rect.insetBy(dx: -0.035, dy: -0.035)
                        .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                }
            }
            return (regions, foreground)
        }
    }

    private static func foregroundInstanceRects(
        from mask: CVPixelBuffer
    ) throws -> [CGRect] {
        guard CVPixelBufferGetPixelFormatType(mask) == kCVPixelFormatType_OneComponent8 else {
            return []
        }
        let width = CVPixelBufferGetWidth(mask)
        let height = CVPixelBufferGetHeight(mask)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(mask)
        guard !CVPixelBufferIsPlanar(mask),
              width > 0, height > 0,
              width <= 4_096, height <= 4_096,
              bytesPerRow >= width, bytesPerRow <= 16_384,
              height <= Int.max / bytesPerRow,
              bytesPerRow * height <= 64 * 1_024 * 1_024,
              CVPixelBufferGetDataSize(mask) >= bytesPerRow * height,
              CVPixelBufferLockBaseAddress(mask, .readOnly) == kCVReturnSuccess else {
            return []
        }
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(mask) else { return [] }
        let labels = Array(
            UnsafeBufferPointer(
                start: baseAddress.assumingMemoryBound(to: UInt8.self),
                count: bytesPerRow * height
            )
        )
        return try PostcardForegroundInstanceBounds.normalizedRects(
            labels: labels,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow
        )
    }

    static func darkForegroundRegions(in samples: PostcardSampleGrid) -> [PostcardSalientRegion] {
        guard samples.columns > 0,
              samples.rows > 0,
              samples.values.count == samples.columns * samples.rows else { return [] }
        let sorted = samples.values.map(\.luminance).sorted()
        let median = sorted[sorted.count / 2]
        let threshold = min(0.18, median * 0.58)
        return connectedRegions(
            indices: samples.values.indices.filter { samples.values[$0].luminance <= threshold },
            samples: samples,
            weight: 0.78
        )
    }

    static func chromaticLandmarkRegions(in samples: PostcardSampleGrid) -> [PostcardSalientRegion] {
        guard samples.columns > 0,
              samples.rows > 0,
              samples.values.count == samples.columns * samples.rows else { return [] }
        let indices = samples.values.indices.filter { index in
            let sample = samples.values[index]
            let saturation = max(sample.red, sample.green, sample.blue)
                - min(sample.red, sample.green, sample.blue)
            let stronglyWarm = saturation >= 0.32
                && sample.red >= sample.green * 1.35
                && sample.red >= sample.blue * 1.35
            let mutedOrange = saturation >= 0.07
                && sample.red >= sample.green + 0.05
                && sample.red >= sample.blue + 0.05
                && sample.red >= 0.40
            let row = index / samples.columns
            return stronglyWarm || (mutedOrange && row < samples.rows / 2)
        }
        return connectedRegions(indices: indices, samples: samples, weight: 0.74)
    }

    private static func connectedRegions(
        indices: [Int],
        samples: PostcardSampleGrid,
        weight: Double
    ) -> [PostcardSalientRegion] {
        var remaining = Set(indices)
        var regions: [PostcardSalientRegion] = []
        while let seed = remaining.first {
            var component: [Int] = []
            var queue = [seed]
            remaining.remove(seed)
            while let index = queue.popLast() {
                component.append(index)
                let row = index / samples.columns
                let column = index % samples.columns
                let neighbors = [
                    (row - 1, column), (row + 1, column),
                    (row, column - 1), (row, column + 1),
                ]
                for (nextRow, nextColumn) in neighbors
                where nextRow >= 0 && nextRow < samples.rows
                    && nextColumn >= 0 && nextColumn < samples.columns {
                    let next = nextRow * samples.columns + nextColumn
                    if remaining.remove(next) != nil { queue.append(next) }
                }
            }
            guard component.count >= 3 else { continue }
            let rows = component.map { $0 / samples.columns }
            let columns = component.map { $0 % samples.columns }
            guard let minRow = rows.min(), let maxRow = rows.max(),
                  let minColumn = columns.min(), let maxColumn = columns.max() else { continue }
            let insetCells = 1
            let left = max(minColumn - insetCells, 0)
            let top = max(minRow - insetCells, 0)
            let right = min(maxColumn + insetCells + 1, samples.columns)
            let bottom = min(maxRow + insetCells + 1, samples.rows)
            regions.append(PostcardSalientRegion(
                rect: CGRect(
                    x: CGFloat(left) / CGFloat(samples.columns),
                    y: CGFloat(top) / CGFloat(samples.rows),
                    width: CGFloat(right - left) / CGFloat(samples.columns),
                    height: CGFloat(bottom - top) / CGFloat(samples.rows)
                ),
                weight: weight
            ))
        }
        return regions
    }

    static func salientRegion(
        fromVisionRect rect: CGRect,
        confidence: Float
    ) -> PostcardSalientRegion? {
        guard rect.origin.x.isFinite,
              rect.origin.y.isFinite,
              rect.size.width.isFinite,
              rect.size.height.isFinite else { return nil }

        let minX = quantized(unit(Double(rect.minX)))
        let minY = quantized(unit(1 - Double(rect.maxY)))
        let maxX = quantized(unit(Double(rect.maxX)))
        let maxY = quantized(unit(1 - Double(rect.minY)))
        guard maxX > minX, maxY > minY else { return nil }
        return PostcardSalientRegion(
            rect: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
            weight: quantized(unit(Double(confidence)))
        )
    }

    static func visionRegion(
        fromVisionRect rect: CGRect,
        confidence: Float,
        source: PostcardSaliencySource
    ) -> PostcardSalientRegion? {
        guard let region = salientRegion(fromVisionRect: rect, confidence: confidence) else {
            return nil
        }
        return PostcardSalientRegion(rect: region.rect, weight: region.weight, source: source)
    }

    private static func unit(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    private static func quantized(_ value: Double) -> Double {
        (value * 1_000_000).rounded() / 1_000_000
    }

    private struct CanonicalRegion: Comparable {
        let rect: CGRect
        let weight: Double
        let source: PostcardSaliencySource

        static func < (lhs: Self, rhs: Self) -> Bool {
            let lhsKey = [lhs.rect.minY, lhs.rect.minX, lhs.rect.width, lhs.rect.height, lhs.weight]
            let rhsKey = [rhs.rect.minY, rhs.rect.minX, rhs.rect.width, rhs.rect.height, rhs.weight]
            for (left, right) in zip(lhsKey, rhsKey) where left != right {
                return left < right
            }
            return false
        }
    }
}
