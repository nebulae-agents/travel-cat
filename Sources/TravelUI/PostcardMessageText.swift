import AppKit
import CoreGraphics
import CoreText
import Foundation
import SwiftUI

public struct PostcardMessageLine: Equatable {
    public let text: String
    public let width: CGFloat
    public let frame: CGRect
}

/// The authoritative line fragments shared by postcard rendering and paw placement.
public struct PostcardMessageLineLayout {
    public let message: String
    public let lines: [PostcardMessageLine]
    public let frame: CGRect
    public let font: NSFont
    public let lineHeight: CGFloat
    public let lineLimit: Int
    public let fits: Bool

    public static func resolve(message: String, frame: CGRect, fontSize: CGFloat,
                               typography: PostcardHandwritingStyle, lineLimit: Int) -> Self {
        let safeFrame = frame.standardized
        let normalized = message.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let font = PostcardOverlayTypography.measurementFont(fontSize: fontSize, handwriting: typography)!
        let lineHeight = PostcardOverlayTypography.renderedLineHeight(fontSize: fontSize, handwriting: typography)
        var fragments: [(String, CGFloat)] = []
        for paragraph in normalized.components(separatedBy: "\n") {
            guard !paragraph.isEmpty else { fragments.append(("", 0)); continue }
            let attributed = CFAttributedStringCreate(nil, paragraph as CFString,
                [kCTFontAttributeName: font as CTFont] as CFDictionary)!
            let typesetter = CTTypesetterCreateWithAttributedString(attributed)
            let source = paragraph as NSString
            var index = 0
            while index < source.length {
                let suggested = safeFrame.width > 0
                    ? CTTypesetterSuggestLineBreak(typesetter, index, Double(safeFrame.width)) : 0
                let count = suggested > 0 ? suggested : source.length - index
                let range = NSRange(location: index, length: count)
                let line = CTTypesetterCreateLine(typesetter, CFRange(location: index, length: count))
                fragments.append((source.substring(with: range),
                                  CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))))
                index += count
            }
        }
        if fragments.isEmpty { fragments = [("", 0)] }
        let lines = fragments.enumerated().map { index, fragment in
            PostcardMessageLine(text: fragment.0, width: fragment.1,
                frame: CGRect(x: safeFrame.minX, y: safeFrame.minY + CGFloat(index) * lineHeight,
                              width: fragment.1, height: lineHeight))
        }
        let validFrame = safeFrame.width > 0 && safeFrame.height > 0
        return Self(message: normalized, lines: lines, frame: safeFrame, font: font,
                    lineHeight: lineHeight, lineLimit: lineLimit,
                    fits: validFrame && lines.count <= lineLimit
                        && !lines.contains { $0.width > safeFrame.width + 0.001 }
                        && CGFloat(lines.count) * lineHeight <= safeFrame.height + 0.001)
    }
}

public struct PostcardMessageTextView: View {
    public let layout: PostcardMessageLineLayout
    public let color: Color
    public var shadowColor: Color
    public var shadowRadius: CGFloat
    public var shadowYOffset: CGFloat

    public init(layout: PostcardMessageLineLayout, color: Color, shadowColor: Color = .clear,
                shadowRadius: CGFloat = 0, shadowYOffset: CGFloat = 0) {
        self.layout = layout; self.color = color; self.shadowColor = shadowColor
        self.shadowRadius = shadowRadius; self.shadowYOffset = shadowYOffset
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(layout.lines.enumerated()), id: \.offset) { _, line in
                Text(line.text).font(Font(layout.font)).foregroundStyle(color).lineLimit(1)
                    .fixedSize(horizontal: true, vertical: true)
                    .shadow(color: shadowColor, radius: shadowRadius, y: shadowYOffset)
                    .frame(width: layout.frame.width, height: layout.lineHeight, alignment: .topLeading)
                    .position(x: layout.frame.midX, y: line.frame.minY + layout.lineHeight / 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore).accessibilityLabel(layout.message)
    }
}

public extension PostcardOverlayLayout {
    func messageTextLayout(message: String, profile: PostcardOverlayProfile,
                           containerSize: CGSize) -> PostcardMessageLineLayout {
        let padding = PostcardOverlayTypography.messagePadding(profile: profile,
            frame: messageFrame(profile: profile, containerSize: containerSize))
        let frame = messageFrame(profile: profile, containerSize: containerSize)
            .insetBy(dx: padding, dy: padding)
        return .resolve(message: message, frame: frame, fontSize: messageFontSize,
                        typography: handwritingStyle, lineLimit: messageLineLimit)
    }
}
