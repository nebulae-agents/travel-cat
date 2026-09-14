import CoreGraphics
import Darwin
import Foundation
import TravelCore
import TravelStorage

/// Each request validates the accepted repository reference afresh. No path-only
/// decoded cache participates in presentation selection or fallback reads.
enum PostcardPresentationLoader {
    struct Result: Sendable {
        let image: CGImage
        let handwriting: CGImage?
        let manifest: PostcardPresentationManifest?
        let showsFallbackIndicator: Bool
    }

    static func load(event: TripEvent, rootURL: URL, reference: PostcardPresentationReference?) async throws -> Result {
        let work = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard let path = event.postcardRelativePath else { throw PostcardImageLoaderError.invalidPath }
            if let reference {
                do {
                    // The configured root is trusted, but store traversal requires its
                    // physical POSIX path (Foundation may retain /var aliases).
                    guard let resolved = realpath(rootURL.path, nil) else { throw PostcardImageLoaderError.ioFailure(errno) }
                    defer { free(resolved) }
                    let root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
                    let value = try PostcardPresentationStore(root: root).load(reference: reference, event: event, expectedSourceRelativePath: path)
                    let image = try PostcardImageDecoder.decodeThumbnail(data: value.landscapeData)
                    let ink = try value.handwritingData.map { try decodeHandwriting(data: $0, viewport: value.manifest.handwritingViewport) }
                    try Task.checkCancellation()
                    return Result(image: image, handwriting: ink, manifest: value.manifest, showsFallbackIndicator: ink == nil)
                } catch {
                    try Task.checkCancellation()
                    // Invalid accepted artifacts never activate through discovery.
                }
            }
            let data = try PostcardImageLoader.loadData(relativePath: path, rootURL: rootURL)
            return Result(image: try PostcardImageDecoder.decodeThumbnail(data: data), handwriting: nil, manifest: nil, showsFallbackIndicator: reference != nil)
        }
        return try await withTaskCancellationHandler {
            let result = try await work.value
            try Task.checkCancellation()
            return result
        } onCancel: { work.cancel() }
    }

    /// Crop in original logical pixels, then redraw into independent bounded
    /// storage. A small CGImage crop alone can retain its enormous parent raster.
    static func decodeHandwriting(data: Data, viewport: PostcardPresentationRect?) throws -> CGImage {
        let raster = try PostcardPresentationStore.inspectHandwriting(data)
        let rect: CGRect
        if let viewport {
            guard viewport.isValid else { throw PostcardImageDecoderError.invalidImage }
            let left = (viewport.x * Double(raster.width)).rounded()
            let top = (viewport.y * Double(raster.height)).rounded()
            let right = ((viewport.x + viewport.width) * Double(raster.width)).rounded()
            let bottom = ((viewport.y + viewport.height) * Double(raster.height)).rounded()
            rect = CGRect(x: left, y: top, width: right - left, height: bottom - top)
        } else { rect = CGRect(x: 0, y: 0, width: raster.width, height: raster.height) }
        guard let crop = raster.image.cropping(to: rect), crop.width > 0, crop.height > 0 else { throw PostcardImageDecoderError.invalidImage }
        let scale = min(1, Double(PostcardImageDecoder.maximumPixelSize) / Double(max(crop.width, crop.height)))
        let width = max(1, Int((Double(crop.width) * scale).rounded()))
        let height = max(1, Int((Double(crop.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw PostcardImageDecoderError.thumbnailCreationFailed }
        context.interpolationQuality = .high
        context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        try Task.checkCancellation()
        guard let image = context.makeImage() else { throw PostcardImageDecoderError.thumbnailCreationFailed }
        return image
    }
}
