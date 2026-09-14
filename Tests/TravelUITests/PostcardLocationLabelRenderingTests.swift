import CoreGraphics
import SwiftUI
import XCTest
@testable import TravelUI

final class PostcardLocationLabelRenderingTests: XCTestCase {
    func testLocationInkStyleDoesNotPublishTheoreticalForegroundVersusShadowContrast() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/TravelUI/PostcardInkStyle.swift"))

        XCTAssertFalse(source.contains("minimumEdgeContrastRatio"))
    }

    @MainActor
    func testDualToneLocationLabelHasRendererBackedContrastAtTwoXWithoutLeavingSafetyFrame() throws {
        for (profile, size) in [
            (PostcardOverlayProfile.compact, CGSize(width: 190, height: 36)),
            (.detail, CGSize(width: 230, height: 44)),
        ] {
            let ink = PostcardLocationInkStyle(
                foreground: .init(red: 0.02, green: 0.02, blue: 0.02),
                shadow: .init(red: 1, green: 1, blue: 1),
                shadowOpacity: 0.68,
                opacity: profile == .compact ? 0.74 : 0.78,
                minimumContrastRatio: 1,
                usesContrastEdgeFallback: true
            )

            let black = try render(
                profile: profile, ink: ink, size: size,
                background: .init(red: 0, green: 0, blue: 0)
            )
            let white = try render(
                profile: profile, ink: ink, size: size,
                background: .init(red: 1, green: 1, blue: 1)
            )
            let transparent = try render(profile: profile, ink: ink, size: size, background: nil)

            let blackProof = rendererProof(in: black, backgroundLuminance: 0) { pixel in
                pixel.red >= 230 && pixel.green >= 230 && pixel.blue >= 230
            }
            let whiteProof = rendererProof(in: white, backgroundLuminance: 1) { pixel in
                pixel.red <= 80 && pixel.green <= 80 && pixel.blue <= 80
            }

            XCTAssertGreaterThan(blackProof.supportedPixelCount, 80, "\(profile) white edge core")
            XCTAssertGreaterThan(whiteProof.supportedPixelCount, 80, "\(profile) dark fill core")
            XCTAssertGreaterThanOrEqual(blackProof.minimumContrastRatio, 4.5, "\(profile) black")
            XCTAssertGreaterThanOrEqual(whiteProof.minimumContrastRatio, 4.5, "\(profile) white")

            let bounds = try XCTUnwrap(alphaBounds(in: transparent, threshold: 8))
            let scale = CGFloat(transparent.width) / size.width
            let requiredOutset = PostcardOverlayTypography.locationSafetyOutset.width * scale
            XCTAssertGreaterThanOrEqual(bounds.minX, requiredOutset - 1, "\(profile) left safety")
            XCTAssertGreaterThanOrEqual(bounds.minY, requiredOutset - 1, "\(profile) top safety")
            XCTAssertLessThanOrEqual(
                bounds.maxX,
                CGFloat(transparent.width) - requiredOutset + 1,
                "\(profile) right safety"
            )
            XCTAssertLessThanOrEqual(
                bounds.maxY,
                CGFloat(transparent.height) - requiredOutset + 1,
                "\(profile) bottom safety"
            )
        }
    }

    @MainActor
    private func render(
        profile: PostcardOverlayProfile,
        ink: PostcardLocationInkStyle,
        size: CGSize,
        background: PostcardInkColor?
    ) throws -> CGImage {
        let outset = PostcardOverlayTypography.locationSafetyOutset
        let content = ZStack {
            if let background {
                Color(red: background.red, green: background.green, blue: background.blue)
            }
            PostcardLocationLabelView(
                label: "上高地河童桥",
                profile: profile,
                minimumScaleFactor: 1,
                ink: ink
            )
            .frame(
                width: size.width - 2 * outset.width,
                height: size.height - 2 * outset.height,
                alignment: .leading
            )
        }
        .frame(width: size.width, height: size.height)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(size)
        return try XCTUnwrap(renderer.cgImage)
    }

    private func rendererProof(
        in image: CGImage,
        backgroundLuminance: Double,
        supports: (Pixel) -> Bool
    ) -> (supportedPixelCount: Int, minimumContrastRatio: Double) {
        let pixels = rgbaPixels(in: image)
        let supported = pixels.filter(supports)
        let minimum = supported.map { pixel in
            PostcardTextContrast.contrastRatio(
                foregroundLuminance: PostcardTextContrast.relativeLuminance(
                    red: Double(pixel.red) / 255,
                    green: Double(pixel.green) / 255,
                    blue: Double(pixel.blue) / 255
                ),
                backgroundLuminance: backgroundLuminance
            )
        }.min() ?? 0
        return (supported.count, minimum)
    }

    private func alphaBounds(in image: CGImage, threshold: UInt8) -> CGRect? {
        let pixels = rgbaPixels(in: image)
        var minX = image.width
        var minY = image.height
        var maxX = -1
        var maxY = -1
        for y in 0..<image.height {
            for x in 0..<image.width where pixels[y * image.width + x].alpha > threshold {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private func rgbaPixels(in image: CGImage) -> [Pixel] {
        var storage = [UInt8](repeating: 0, count: image.width * image.height * 4)
        storage.withUnsafeMutableBytes { bytes in
            let context = CGContext(
                data: bytes.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return stride(from: 0, to: storage.count, by: 4).map {
            Pixel(red: storage[$0], green: storage[$0 + 1], blue: storage[$0 + 2], alpha: storage[$0 + 3])
        }
    }

    private struct Pixel {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let alpha: UInt8
    }
}
