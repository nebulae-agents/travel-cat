import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// Diagnostics from synthetic fixtures only. The two crops deliberately exclude
/// recipient/sender names, addresses, quotes and the rest of the application.
enum PostcardRasterEvidence {
    static func postmark(_ image: CGImage) throws -> CGImage {
        try crop(image, rectangle: CGRect(x: 0.63, y: 0.055, width: 0.335, height: 0.25))
    }

    static func publicPlace(_ image: CGImage, paperBounds: CGRect) throws -> CGImage {
        // The detected paper bounds are already in bitmap row coordinates,
        // matching CGImage cropping. Only the public Kyoto place line is retained.
        let paper = paperBounds
        let rectangle = CGRect(x: paper.minX + paper.width * 0.05,
                               y: paper.minY + paper.height * 0.825,
                               width: paper.width * 0.47, height: paper.height * 0.115)
        return try XCTUnwrap(image.cropping(to: rectangle.integral))
    }

    static func write(_ crop: CGImage, tag: String) throws {
        // Fixed test tags; never serialize whole frames or a failed-crop fallback.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        guard !tag.isEmpty, tag.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let root = URL(fileURLWithPath: "/tmp/travelcat-raster-diagnostics", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            root.appendingPathComponent(tag).appendingPathExtension("png") as CFURL,
            UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, crop, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private static func crop(_ image: CGImage, rectangle: CGRect) throws -> CGImage {
        let pixels = CGRect(x: rectangle.minX * CGFloat(image.width),
                            y: rectangle.minY * CGFloat(image.height),
                            width: rectangle.width * CGFloat(image.width),
                            height: rectangle.height * CGFloat(image.height))
        return try XCTUnwrap(image.cropping(to: pixels.integral))
    }
}
