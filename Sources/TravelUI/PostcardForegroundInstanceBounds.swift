import CoreGraphics
import Foundation

enum PostcardForegroundInstanceBounds {
    private struct PixelBounds {
        var minimumX: Int
        var minimumY: Int
        var maximumX: Int
        var maximumY: Int

        mutating func include(x: Int, y: Int) {
            minimumX = min(minimumX, x)
            minimumY = min(minimumY, y)
            maximumX = max(maximumX, x)
            maximumY = max(maximumY, y)
        }
    }

    static func normalizedRects(
        labels: [UInt8],
        width: Int,
        height: Int,
        bytesPerRow: Int,
        maximumInstanceCount: Int = 64,
        cancellationCheck: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> [CGRect] {
        guard width > 0, height > 0,
              width <= 4_096, height <= 4_096,
              bytesPerRow >= width,
              height <= Int.max / bytesPerRow,
              labels.count >= bytesPerRow * height,
              maximumInstanceCount > 0 else { return [] }

        var bounds: [UInt8: PixelBounds] = [:]
        for y in 0..<height {
            try cancellationCheck()
            let rowOffset = y * bytesPerRow
            for x in 0..<width {
                let label = labels[rowOffset + x]
                guard label != 0 else { continue }
                if var existing = bounds[label] {
                    existing.include(x: x, y: y)
                    bounds[label] = existing
                } else {
                    bounds[label] = PixelBounds(
                        minimumX: x,
                        minimumY: y,
                        maximumX: x,
                        maximumY: y
                    )
                    if bounds.count > maximumInstanceCount {
                        return [CGRect(x: 0, y: 0, width: 1, height: 1)]
                    }
                }
            }
        }

        return bounds.keys.sorted().compactMap { label in
            guard let bound = bounds[label] else { return nil }
            return CGRect(
                x: CGFloat(bound.minimumX) / CGFloat(width),
                y: CGFloat(bound.minimumY) / CGFloat(height),
                width: CGFloat(bound.maximumX - bound.minimumX + 1) / CGFloat(width),
                height: CGFloat(bound.maximumY - bound.minimumY + 1) / CGFloat(height)
            )
        }
    }
}
