import CoreGraphics
import Foundation
import Vision
import TravelCore
import TravelStorage

/// Shared acceptance policy for generated transparent ink. Never rewrites the supplied PNG.
public enum PostcardHandwritingVerifier {
    public enum Rejection: Error, Equatable {
        case invalidImage, unsafeLayout, invalidText, ambiguousText, unreadableText, insufficientContrast, recognitionFailed
    }
    public struct Alternative: Sendable {
        public let text: String
        public let confidence: Float
        public init(text: String, confidence: Float) { self.text = text; self.confidence = confidence }
    }
    public struct Observation: Sendable {
        public let text: String
        public let confidence: Float
        /// Top-left normalized bounds in the original, uncropped ink image.
        public let bounds: CGRect
        public let alternatives: [Alternative]
        public init(text: String, confidence: Float, bounds: CGRect, alternatives: [Alternative] = []) {
            self.text = text; self.confidence = confidence; self.bounds = bounds; self.alternatives = alternatives
        }
    }
    public struct Selection: Sendable {
        public let safeArea: PostcardPresentationRect
        /// A generation prompt hint only; acceptance checks actual composited pixels.
        public let desiredInkColor: PostcardInkColor
        fileprivate let layout: PostcardOverlayLayout
        fileprivate let analysis: PostcardVisualAnalysis
    }
    public struct Verified: Sendable {
        public let pngData: Data
        public let viewport: PostcardPresentationRect
        public let placement: PostcardPresentationRect
    }

    public static func select(event: TripEvent, base: CGImage, analysis: PostcardVisualAnalysis? = nil) throws -> Selection {
        try Task.checkCancellation()
        try checkBase(base)
        let resolved: PostcardVisualAnalysis
        do { resolved = try analysis ?? PostcardVisualAnalyzer.analyze(base) }
        catch is CancellationError { throw CancellationError() }
        catch { throw Rejection.unsafeLayout }
        let analysis = resolved
        let layout = PostcardArtworkLayoutResolver.resolve(metadata: .init(event: event), analysis: analysis,
            profile: .detail, containerSize: CGSize(width: base.width, height: base.height))
        let safe = layout.resolvedNormalizedMessageRect(profile: .detail)
        guard layout.messagePlacement == .onImage, normalized(safe).isValid else { throw Rejection.unsafeLayout }
        try checkGeometry(safe, layout: layout, analysis: analysis)
        return Selection(safeArea: normalized(safe), desiredInkColor: layout.inkStyle.foreground, layout: layout, analysis: analysis)
    }

    public static func verify(event: TripEvent, base: CGImage, inkData: Data,
                              analysis: PostcardVisualAnalysis? = nil, observations: [Observation]? = nil) throws -> Verified {
        let selection = try select(event: event, base: base, analysis: analysis)
        let raster: PostcardPresentationStore.HandwritingRaster
        do { raster = try PostcardPresentationStore.inspectHandwriting(inkData) }
        catch is CancellationError { throw CancellationError() }
        catch { throw Rejection.invalidImage }
        let viewport = raster.paddedViewport
        let sourceWidth = viewport.width * Double(raster.width), sourceHeight = viewport.height * Double(raster.height)
        let safe = selection.safeArea
        let scale = min(safe.width * Double(base.width) / sourceWidth, safe.height * Double(base.height) / sourceHeight)
        let width = sourceWidth * scale / Double(base.width), height = sourceHeight * scale / Double(base.height)
        let frame = CGRect(x: safe.x + (safe.width - width) / 2, y: safe.y + (safe.height - height) / 2, width: width, height: height)
        try checkGeometry(frame, layout: selection.layout, analysis: selection.analysis)
        let lines = try observations ?? recognize(raster.image, background: selection.desiredInkColor.relativeLuminance < 0.5 ? 1 : 0)
        try validateText(event.mood.quote, observations: lines)
        let compactScale = Double(TripAlbumLayout.readableCompactArtworkWidth) / Double(base.width)
        let viewportRect = CGRect(x: viewport.x, y: viewport.y, width: viewport.width, height: viewport.height)
        for line in lines {
            let visibleBounds = viewportRect.intersection(line.bounds)
            // The alpha viewport already includes every ink pixel. OCR rectangles are
            // estimates; majority overlap on each axis is a geometric sanity policy,
            // not a claim about OCR accuracy. Only visible height counts as readable.
            let minimumAxisOverlapFraction = 0.5
            guard !visibleBounds.isNull, !visibleBounds.isEmpty,
                  visibleBounds.width > line.bounds.size.width * minimumAxisOverlapFraction,
                  visibleBounds.height > line.bounds.size.height * minimumAxisOverlapFraction,
                  visibleBounds.height * Double(raster.height) * scale * compactScale >= 12 else { throw Rejection.unreadableText }
        }
        try checkContrast(base: base, raster: raster, frame: frame)
        return Verified(pngData: inkData, viewport: viewport, placement: normalized(frame))
    }

    static func validateText(_ quote: String, observations: [Observation]) throws {
        try Task.checkCancellation()
        guard !observations.isEmpty, observations.count <= 128, !textBytes(quote).isEmpty else { throw Rejection.invalidText }
        for line in observations {
            guard line.confidence.isFinite, line.confidence >= 0.9, line.confidence <= 1,
                  line.bounds.origin.x.isFinite, line.bounds.origin.y.isFinite,
                  line.bounds.size.width.isFinite, line.bounds.size.height.isFinite,
                  line.bounds.size.width > 0, line.bounds.size.height > 0,
                  normalized(line.bounds).isValid, !textBytes(line.text).isEmpty else { throw Rejection.invalidText }
            for alternative in line.alternatives {
                guard alternative.confidence.isFinite, alternative.confidence >= 0, alternative.confidence <= 1 else { throw Rejection.invalidText }
                if textBytes(alternative.text) != textBytes(line.text), line.confidence - alternative.confidence < 0.1 {
                    throw Rejection.ambiguousText
                }
            }
        }
        // A fixed top-to-bottom then left-to-right order, independent of Vision result order.
        let sorted = observations.sorted {
            if $0.bounds.minY != $1.bounds.minY { return $0.bounds.minY < $1.bounds.minY }
            return $0.bounds.minX < $1.bounds.minX
        }
        guard textBytes(sorted.map(\.text).joined()) == textBytes(quote) else { throw Rejection.invalidText }
    }

    private static func textBytes(_ text: String) -> [UInt8] {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { !$0.properties.isWhitespace })).utf8.map { $0 }
    }
    private static func normalized(_ rect: CGRect) -> PostcardPresentationRect {
        .init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }
    private static func checkBase(_ image: CGImage) throws {
        guard image.width > 0, image.height > 0, image.width <= PostcardGenerationContract.maximumAxis,
              image.height <= PostcardGenerationContract.maximumAxis,
              image.width <= PostcardGenerationContract.maximumPixels / image.height,
              PostcardGenerationContract.accepts(width: image.width, height: image.height) else { throw Rejection.invalidImage }
    }
    static func checkGeometry(_ frame: CGRect, layout: PostcardOverlayLayout, analysis: PostcardVisualAnalysis) throws {
        guard normalized(frame).isValid,
              !(analysis.protectedRegions + analysis.foregroundRegions).contains(where: { frame.intersects($0.insetBy(dx: -0.015, dy: -0.015)) }),
              !layout.showsLocationLabel || !frame.intersects(layout.locationSafetyRect) else { throw Rejection.unsafeLayout }
    }
    private static func context(width: Int, height: Int) throws -> CGContext {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { throw Rejection.invalidImage }
        context.interpolationQuality = .high
        return context
    }

    static func recognize(_ image: CGImage, background: CGFloat) throws -> [Observation] {
        try Task.checkCancellation()
        // OCR inspection is bounded and in memory; the immutable PNG is never reencoded.
        let scale = min(1, 2048.0 / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        let inspection = try context(width: width, height: height)
        inspection.setFillColor(CGColor(gray: background, alpha: 1))
        inspection.fill(CGRect(x: 0, y: 0, width: width, height: height))
        inspection.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let opaque = inspection.makeImage() else { throw Rejection.invalidImage }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        try Task.checkCancellation()
        // Synchronous Vision may finish before cancellation is observed; callers must also
        // recheck their event/lease before publishing. No late result is accepted here.
        do { try VNImageRequestHandler(cgImage: opaque, orientation: .up).perform([request]) }
        catch { try Task.checkCancellation(); throw Rejection.recognitionFailed }
        try Task.checkCancellation()
        return (request.results ?? []).compactMap { observation in
            let candidates = observation.topCandidates(5)
            guard let first = candidates.first else { return nil }
            let box = observation.boundingBox
            return Observation(text: first.string, confidence: first.confidence,
                bounds: CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height),
                alternatives: candidates.dropFirst().map { Alternative(text: $0.string, confidence: $0.confidence) })
        }
    }

    private static func checkContrast(base: CGImage, raster: PostcardPresentationStore.HandwritingRaster, frame: CGRect) throws {
        try Task.checkCancellation()
        // Interpolation can overshoot source alpha. It cannot manufacture a stroke interior.
        guard raster.maximumAlpha >= 204 else { throw Rejection.insufficientContrast }
        let support = SourceInkSupport(image: raster.image)
        // A faint thin component is not an antialiased edge unless a real core is nearby.
        for y in 0..<raster.height {
            if y.isMultiple(of: 64) { try Task.checkCancellation() }
            try support.prepare(y: y)
            for x in 0..<raster.width where support.alpha(x: x, y: y) > 0 {
                if x.isMultiple(of: 4096) { try Task.checkCancellation() }
                guard (-1...1).contains(where: { dy in
                    (-1...1).contains(where: { dx in support.isCore(x: x + dx, y: y + dy) })
                }) else { throw Rejection.insufficientContrast }
            }
        }
        try checkContrast(base: base, raster: raster, support: support, frame: frame, width: Int(TripAlbumLayout.readableCompactArtworkWidth))
        try checkContrast(base: base, raster: raster, support: support, frame: frame, width: base.width)
    }

    /// Alpha-only source tiles keep geometric stroke interiors independent of opacity and
    /// resampling fringes. The two-row halo supports both erosion and edge coverage.
    private final class SourceInkSupport {
        let image: CGImage
        var tile: CGContext?
        var firstRow = 0
        var lastRow = 0
        var block = -1

        init(image: CGImage) { self.image = image }

        func prepare(y: Int) throws {
            let next = max(0, min(image.height - 1, y)) / 64
            guard next != block else { return }
            firstRow = max(0, next * 64 - 2)
            lastRow = min(image.height, (next + 1) * 64 + 2)
            tile = nil
            guard let context = CGContext(data: nil, width: image.width, height: lastRow - firstRow,
                bitsPerComponent: 8, bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { throw Rejection.invalidImage }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: lastRow - image.height, width: image.width, height: image.height))
            tile = context
            block = next
        }

        func alpha(x: Int, y: Int) -> UInt8 {
            guard x >= 0, x < image.width, y >= firstRow, y < lastRow,
                  let tile, let pixels = tile.data?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            return pixels[(y - firstRow) * tile.bytesPerRow + x]
        }

        func isCore(x: Int, y: Int) -> Bool {
            alpha(x: x, y: y) >= 204 || isGeometricInterior(x: x, y: y)
        }

        func isGeometricInterior(x: Int, y: Int) -> Bool {
            return (-1...1).allSatisfy { dy in
                (-1...1).allSatisfy { dx in alpha(x: x + dx, y: y + dy) > 0 }
            }
        }
    }

    private static func checkContrast(base: CGImage, raster: PostcardPresentationStore.HandwritingRaster, support: SourceInkSupport, frame: CGRect, width: Int) throws {
        let height = max(1, Int((Double(width) * Double(base.height) / Double(base.width)).rounded()))
        let viewport = raster.paddedViewport
        let drawWidth = frame.width * Double(width) / viewport.width
        let drawHeight = frame.height * Double(height) / viewport.height
        let drawX = frame.minX * Double(width) - viewport.x * drawWidth
        let drawTop = frame.minY * Double(height) - viewport.y * drawHeight
        let left = max(0, Int(floor(frame.minX * Double(width)))), top = max(0, Int(floor(frame.minY * Double(height))))
        let right = min(width, Int(ceil(frame.maxX * Double(width)))), bottom = min(height, Int(ceil(frame.maxY * Double(height))))
        var interiors = 0
        // Native resolution catches isolated low-contrast pixels hidden by compact averaging.
        // Placed ink uses 64-row tiles (at most 16 MiB), plus one source alpha tile
        // of at most 68 rows (2.125 MiB at the maximum supported source width).
        for row in stride(from: top, to: bottom, by: 64) {
            try Task.checkCancellation()
            let tileWidth = right - left, tileHeight = min(64, bottom - row)
            let scene = try context(width: tileWidth, height: tileHeight), ink = try context(width: tileWidth, height: tileHeight)
            scene.draw(base, in: CGRect(x: -left, y: tileHeight + row - height, width: width, height: height))
            // CGContext's bottom-left drawing origin is converted from the top-left viewport.
            ink.draw(raster.image, in: CGRect(x: drawX - Double(left), y: Double(tileHeight + row) - drawTop - drawHeight, width: drawWidth, height: drawHeight))
            guard let background = scene.data?.assumingMemoryBound(to: UInt8.self), let pixels = ink.data?.assumingMemoryBound(to: UInt8.self) else { throw Rejection.invalidImage }
            for pixel in 0..<(tileWidth * tileHeight) {
                if pixel.isMultiple(of: 4096) { try Task.checkCancellation() }
                let i = pixel * 4, alpha = Double(pixels[i + 3]) / 255
                let sourceX = Int(floor((Double(left + pixel % tileWidth) + 0.5 - drawX) / drawWidth * Double(raster.width)))
                let sourceY = Int(floor((Double(row + pixel / tileWidth) + 0.5 - drawTop) / drawHeight * Double(raster.height)))
                try support.prepare(y: sourceY)
                guard alpha >= 0.8 || support.isGeometricInterior(x: sourceX, y: sourceY) else { continue }
                interiors += 1
                guard background[i + 3] == 255 else { throw Rejection.insufficientContrast }
                let r = Double(background[i]) / 255, g = Double(background[i + 1]) / 255, b = Double(background[i + 2]) / 255
                let luminance = PostcardTextContrast.relativeLuminance(red: r, green: g, blue: b)
                let composite = PostcardTextContrast.relativeLuminance(red: Double(pixels[i]) / 255 + r * (1 - alpha),
                    green: Double(pixels[i + 1]) / 255 + g * (1 - alpha), blue: Double(pixels[i + 2]) / 255 + b * (1 - alpha))
                guard PostcardTextContrast.contrastRatio(foregroundLuminance: composite, backgroundLuminance: luminance) >= 4.5 else { throw Rejection.insufficientContrast }
            }
        }
        guard interiors > 0 else { throw Rejection.insufficientContrast }
    }
}
