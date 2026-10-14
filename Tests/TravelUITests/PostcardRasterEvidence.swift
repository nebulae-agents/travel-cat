import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import TravelUI

/// Diagnostics from synthetic fixtures only. The two crops deliberately exclude
/// recipient/sender names, addresses, quotes and the rest of the application.
@MainActor
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

    static func pixels(_ image: CGImage) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress,
                width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return Data(bytes)
    }

    static func maximumPixelDifference(_ first: CGImage, _ second: CGImage,
                                       file: StaticString = #filePath, line: UInt = #line) throws -> Int {
        XCTAssertEqual(first.width, second.width, file: file, line: line)
        XCTAssertEqual(first.height, second.height, file: file, line: line)
        guard first.width == second.width, first.height == second.height else { return .max }
        let a = try pixels(first), b = try pixels(second)
        XCTAssertEqual(a.count, b.count, file: file, line: line)
        guard a.count == b.count else { return .max }
        // ImageRenderer dithers the paper gradient by at most two channel levels.
        // Every channel is checked; text/layout differences must exceed that same bound.
        return zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 0
    }

    static func assertRecordedDay(_ image: CGImage, date: Date,
                                  render: (Date?) throws -> CGImage,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(PostcardMessageFaceView.postmarkDate(date), "2026.10.01", file: file, line: line)
        let original = try postmark(image)
        XCTAssertLessThanOrEqual(try maximumPixelDifference(original, postmark(render(date))), 2,
                       "Repeated date rendering must be stable", file: file, line: line)
        for days in [1, 3] {
            let other = date.addingTimeInterval(TimeInterval(days * 86_400))
            XCTAssertGreaterThan(try maximumPixelDifference(original, postmark(render(other))), 2,
                              "Recorded day glyphs must differ from 10.02/10.04", file: file, line: line)
        }
        XCTAssertGreaterThan(try maximumPixelDifference(original, postmark(render(nil))), 2,
                          "A recorded date must differ from an absent postmark", file: file, line: line)
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
