import SwiftUI

struct PostcardPostageView: View {
    let postage: PostcardPostage
    let travelDate: Date?
    let scale: CGFloat
    private let ink = Color(red: 0.30, green: 0.29, blue: 0.27)

    var body: some View {
        let values: [Int?] = postage.denominations.isEmpty ? [nil] : postage.denominations.map { $0 }
        let layout = PostcardPostageLayout(stampCount: values.count)
        ZStack(alignment: .topLeading) {
            ForEach(values.indices, id: \.self) { index in
                let rect = layout.stamps[index]
                PostcardStampView(design: postage.design, value: values[index],
                    width: rect.width * scale, height: rect.height * scale,
                    underPostmark: index == 0 && travelDate != nil)
                    .rotationEffect(.degrees(index.isMultiple(of: 2) ? -1.5 : 1))
                    .position(x: rect.midX * scale, y: rect.midY * scale)
            }
            if let travelDate {
                let dateText = PostcardMessageFaceView.postmarkDate(travelDate)
                PostcardCancellationWaves(postmark: layout.postmark)
                    .stroke(ink.opacity(0.48), lineWidth: 0.65 * scale)
                    .frame(width: 120 * scale, height: 54 * scale)
                ZStack {
                    Circle().stroke(ink.opacity(0.85), lineWidth: 0.8 * scale)
                    Circle().inset(by: 2.3 * scale).stroke(ink.opacity(0.65), lineWidth: 0.45 * scale)
                    VStack(spacing: 1 * scale) {
                        Text(String(dateText.prefix(4)))
                            .font(.system(size: 7 * scale, weight: .bold, design: .monospaced))
                            .tracking(0.2 * scale)
                        Text(String(dateText.suffix(5)))
                            .font(.system(size: 8.3 * scale, weight: .bold, design: .monospaced))
                    }
                    .foregroundStyle(ink.opacity(0.95))
                    .fixedSize()
                }
                .frame(width: layout.postmark.width * scale, height: layout.postmark.height * scale)
                .rotationEffect(.degrees(-7))
                .position(x: layout.postmark.midX * scale, y: layout.postmark.midY * scale)
            }
        }
        .frame(width: 120 * scale, height: 54 * scale)
        .help(postage.accessibilityDescription)
        .accessibilityHidden(true)
    }
}

/// Positions are in the postage area's 120 by 54 point design space.
private struct PostcardPostageLayout {
    let stamps: [CGRect]
    let postmark: CGRect

    init(stampCount: Int) {
        let count = min(3, max(1, stampCount))
        let width: CGFloat = count == 1 ? 35 : 28
        let totalWidth = CGFloat(count) * width + CGFloat(count - 1) * 2
        stamps = (0..<count).map { index in
            CGRect(x: 119 - totalWidth + CGFloat(index) * (width + 2), y: 1, width: width, height: 50)
        }
        let firstCentre = 119 - totalWidth + width / 2
        let centre = min(102, firstCentre)
        postmark = CGRect(x: centre - 17, y: 3, width: 34, height: 34)
    }
}

private struct PostcardStampView: View {
    let design: PostcardPostage.Design
    let value: Int?
    let width: CGFloat
    let height: CGFloat
    let underPostmark: Bool

    private var tint: Color {
        switch design.palette {
        case 0: Color(red: 0.30, green: 0.45, blue: 0.39)
        case 1: Color(red: 0.54, green: 0.33, blue: 0.30)
        case 2: Color(red: 0.30, green: 0.42, blue: 0.54)
        case 3: Color(red: 0.52, green: 0.43, blue: 0.27)
        default: Color(red: 0.45, green: 0.36, blue: 0.51)
        }
    }

    var body: some View {
        let scale = height / 50
        ZStack {
            Text(design.countryMark)
                .font(.system(size: 5.3 * scale, weight: .bold, design: .serif))
                .tracking(0.7 * scale)
                .position(x: width / 2, y: 7 * scale)
            ZStack {
                Circle().fill(tint.opacity(0.09)).frame(width: 20 * scale, height: 20 * scale)
                Image(systemName: design.symbol)
                    .font(.system(size: 14 * scale, weight: .light))
                    .opacity(underPostmark ? 0.22 : 0.70)
            }
            .position(x: width / 2, y: 25 * scale)
            Group {
                if let value {
                    HStack(alignment: .firstTextBaseline, spacing: 1 * scale) {
                        Text("\(value)").font(.system(size: 9 * scale, weight: .semibold, design: .serif))
                        Text("猫邮币").font(.system(size: 3.8 * scale, weight: .medium))
                    }
                } else {
                    Text("纪念").font(.system(size: 5.5 * scale, weight: .medium))
                }
            }
            .position(x: width / 2, y: 43 * scale)
        }
        .foregroundStyle(tint)
        .frame(width: width, height: height)
        .background(Color(red: 0.97, green: 0.95, blue: 0.89))
        .overlay(Rectangle().inset(by: 3 * scale).stroke(tint.opacity(0.38), lineWidth: 0.45 * scale))
        .background(tint.opacity(0.07))
        .clipShape(PostcardStampPerforation(), style: FillStyle(eoFill: true))
    }
}

private struct PostcardStampPerforation: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = rect.height / 34
        let step = radius * 4
        return Path { path in
            path.addRect(rect)
            for x in stride(from: step / 2, to: rect.width, by: step) {
                for y in [rect.minY, rect.maxY] {
                    path.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                }
            }
            for y in stride(from: step / 2, to: rect.height, by: step) {
                for x in [rect.minX, rect.maxX] {
                    path.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                }
            }
        }
    }
}

private struct PostcardCancellationWaves: Shape {
    let postmark: CGRect

    func path(in rect: CGRect) -> Path {
        let scale = rect.width / 120
        return Path { path in
            let radius = postmark.width / 2
            for y in [CGFloat(12), 22, 32] {
                let delta = y - postmark.midY
                let halfChord = max(0, radius * radius - delta * delta).squareRoot()
                // Leave the dated centre clear. The waves continue over the other stamps.
                let left = max(0, postmark.midX - halfChord - 1.5)
                let right = min(120, postmark.midX + halfChord + 1.5)
                for (start, end) in [(8.0, left), (right, 120.0)] where end > start {
                    path.move(to: CGPoint(x: start * scale, y: y * scale))
                    path.addCurve(to: CGPoint(x: end * scale, y: y * scale),
                        control1: CGPoint(x: (start + (end - start) / 3) * scale, y: (y - 2.5) * scale),
                        control2: CGPoint(x: (start + (end - start) * 2 / 3) * scale, y: (y + 2.5) * scale))
                }
            }
        }
    }
}
