import CoreGraphics
import SwiftUI
import XCTest
@testable import TravelUI

/// Reusable real-glyph assertion for postcard fixture acceptance tests.
@MainActor
enum PostcardPawRasterAssertions {
    static func assertClearance(
        message: String,
        layout: PostcardOverlayLayout,
        profile: PostcardOverlayProfile,
        canvasSize: CGSize,
        minimumGap: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let textLayout = layout.messageTextLayout(
            message: message,
            profile: profile,
            containerSize: canvasSize
        )
        XCTAssertEqual(textLayout.lines.map(\.text).joined(),
                       message.replacingOccurrences(of: "\r\n", with: "\n")
                           .replacingOccurrences(of: "\r", with: "\n")
                           .replacingOccurrences(of: "\n", with: ""), file: file, line: line)
        let text = try mask(PostcardMessageTextView(layout: textLayout, color: .black,
            shadowColor: .black.opacity(layout.inkStyle.shadowOpacity),
            shadowRadius: layout.inkStyle.shadowRadius, shadowYOffset: 1), size: canvasSize)
        let textInk = try inkPixels(text)
        XCTAssertFalse(textInk.isEmpty, "text raster must contain glyph ink", file: file, line: line)
        try assertLinesUnclipped(
            textLayout: textLayout,
            shadowOpacity: layout.inkStyle.shadowOpacity,
            shadowRadius: layout.inkStyle.shadowRadius,
            file: file,
            line: line
        )
        print("paw-raster: canvas=\(canvasSize) font=\(layout.messageFontSize) region=\(layout.messageRegion) mode=\(layout.pawSignature.placement.mode) frame=\(textLayout.frame) lines=\(textLayout.lines.map(\.width)) fit=\(textLayout.fits)")
        guard layout.pawSignature.placement.mode != .omitted else { return }

        let paw = try mask(PostcardPawSignatureView(signature: layout.pawSignature), size: canvasSize)
        let pawInk = try inkPixels(paw)
        XCTAssertFalse(pawInk.isEmpty, "paw raster must contain ink", file: file, line: line)
        XCTAssertTrue(textInk.isDisjoint(with: pawInk), "text and paw ink overlap", file: file, line: line)
        XCTAssertGreaterThanOrEqual(distance(textInk, pawInk, width: text.width), minimumGap,
                                    file: file, line: line)
    }

    static func assertLinesUnclipped(
        textLayout: PostcardMessageLineLayout,
        shadowOpacity: Double,
        shadowRadius: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        for sourceLine in textLayout.lines where !sourceLine.text.isEmpty {
            let localFrame = CGRect(x: 0, y: 0, width: textLayout.frame.width,
                                    height: textLayout.lineHeight)
            let localLine = PostcardMessageLine(text: sourceLine.text, width: sourceLine.width,
                                                frame: localFrame)
            let isolated = PostcardMessageLineLayout(
                message: sourceLine.text,
                lines: [localLine],
                frame: localFrame,
                font: textLayout.font,
                lineHeight: textLayout.lineHeight,
                lineLimit: 1,
                fits: sourceLine.width <= localFrame.width
            )
            let margin = ceil(shadowRadius * 3 + 4)
            let referenceSize = CGSize(width: ceil(max(sourceLine.width, localFrame.width)) + margin * 2,
                                       height: ceil(textLayout.lineHeight) + margin * 2)
            let production = PostcardMessageTextView(
                layout: isolated,
                color: .black,
                shadowColor: .black.opacity(shadowOpacity),
                shadowRadius: shadowRadius,
                shadowYOffset: 1
            ).padding(margin)
            let reference = Text(sourceLine.text)
                .font(Font(textLayout.font))
                .foregroundStyle(.black)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: true)
                .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius, y: 1)
                .padding(margin)
                .frame(width: referenceSize.width, height: referenceSize.height, alignment: .topLeading)
            let productionInk = try inkPixels(try mask(production, size: referenceSize))
            let referenceInk = try inkPixels(try mask(reference, size: referenceSize))
            XCTAssertFalse(referenceInk.isEmpty, "reference line must contain glyph ink", file: file, line: line)
            XCTAssertEqual(productionInk.count, referenceInk.count,
                           "rendered line lost or clipped glyph pixels: \(sourceLine.text)", file: file, line: line)
            XCTAssertEqual(bounds(productionInk, width: Int(referenceSize.width)),
                           bounds(referenceInk, width: Int(referenceSize.width)),
                           "rendered line bounds differ from unclipped reference: \(sourceLine.text)",
                           file: file, line: line)
        }
    }

    private static func mask<V: View>(_ view: V, size: CGSize) throws -> CGImage {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height,
                                                          alignment: .topLeading))
        renderer.scale = 1
        return try XCTUnwrap(renderer.cgImage)
    }

    private static func inkPixels(_ image: CGImage) throws -> Set<Int> {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: image.width,
                height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return Set((0..<(image.width * image.height)).filter { bytes[$0 * 4 + 3] > 24 })
    }

    private static func bounds(_ pixels: Set<Int>, width: Int) -> CGRect {
        guard !pixels.isEmpty else { return .null }
        let xs = pixels.map { $0 % width }, ys = pixels.map { $0 / width }
        return CGRect(x: xs.min()!, y: ys.min()!,
                      width: xs.max()! - xs.min()! + 1, height: ys.max()! - ys.min()! + 1)
    }

    private static func distance(_ lhs: Set<Int>, _ rhs: Set<Int>, width: Int) -> CGFloat {
        var result = CGFloat.greatestFiniteMagnitude
        for a in lhs {
            for b in rhs {
                result = min(result, hypot(CGFloat(a % width - b % width), CGFloat(a / width - b / width)))
            }
        }
        return result
    }
}
