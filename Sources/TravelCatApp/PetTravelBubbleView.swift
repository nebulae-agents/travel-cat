import SwiftUI
import TravelStorage
import TravelUI

struct PetTravelBubbleContent: Equatable {
    var markedAsTestJourney: Self {
        Self(eyebrow: "测试旅程 · \(eyebrow)", title: title, message: message)
    }

    let eyebrow: String
    let title: String
    let message: String

    init(eyebrow: String, title: String, message: String) {
        self.eyebrow = eyebrow
        self.title = title
        self.message = message
    }

    init(delivery: PetTravelPromptDelivery) {
        let displayLocation = PostcardDisplayLocation()
        switch delivery {
        case let .prompt(.departed(_, _, location, summary)):
            eyebrow = "准备出发"
            if let location {
                title = "下一站 · \(displayLocation.resolve(location))"
            } else {
                title = "新的旅程"
            }
            message = summary
        case let .prompt(.postcardReady(_, _, location, mood, quote)):
            eyebrow = "明信片到了"
            if let location {
                title = "来自 \(displayLocation.resolve(location))"
            } else {
                title = "来自旅途中"
            }
            message = mood.isEmpty ? quote : "\(mood) · \(quote)"
        case let .prompt(.returned(_, _, mood)):
            eyebrow = "旅行归来"
            title = "我回家啦"
            message = mood.isEmpty ? "这次也平安到家。" : "现在的心情：\(mood)"
        case let .summary(promptIDs, count):
            if promptIDs == ["travel-cat-fast-test"] {
                eyebrow = "快速测试"
                title = "测试纸条"
                message = "这是临时测试，不会写入旅行数据。"
            } else {
                eyebrow = "旅行动态"
                title = "黑猫带回了 \(count) 条消息"
                message = "点开看看这段时间的旅程。"
            }
        }
    }
}

struct PetTravelPawView: View {
    var body: some View {
        Canvas { context, size in
            let ink = Color(red: 0.24, green: 0.15, blue: 0.10).opacity(0.48)
            let pad = CGRect(
                x: size.width * 0.28,
                y: size.height * 0.42,
                width: size.width * 0.44,
                height: size.height * 0.42
            )
            context.fill(Path(ellipseIn: pad), with: .color(ink))
            for center in [
                CGPoint(x: 0.20, y: 0.30),
                CGPoint(x: 0.40, y: 0.16),
                CGPoint(x: 0.62, y: 0.16),
                CGPoint(x: 0.82, y: 0.30),
            ] {
                let toe = CGRect(
                    x: size.width * center.x - 4,
                    y: size.height * center.y - 5,
                    width: 8,
                    height: 10
                )
                context.fill(Path(ellipseIn: toe), with: .color(ink))
            }
        }
        .accessibilityHidden(true)
    }
}

struct PetTravelBubblePointer: Shape {
    enum Direction: Equatable {
        case leading
        case trailing
    }

    let direction: Direction

    static func direction(for edge: PetCompanionEdge) -> Direction {
        switch edge {
        case .bottomLeading, .leading:
            .leading
        case .bottomTrailing, .trailing:
            .trailing
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch direction {
        case .leading:
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        case .trailing:
            path.move(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        path.closeSubpath()
        return path
    }
}

struct PetTravelBubbleView: View {
    let content: PetTravelBubbleContent
    let isCollapsed: Bool
    let edge: PetCompanionEdge
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: pointerAlignment) {
                if isCollapsed {
                    pawBadge
                } else {
                    paperSlip
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: pointerAlignment)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isCollapsed ? "打开旅行动态" : "\(content.eyebrow)，\(content.title)，\(content.message)")
    }

    private var paperSlip: some View {
        ZStack(alignment: pointerAlignment) {
            VStack(alignment: .leading, spacing: 5) {
                Text(content.eyebrow)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(red: 0.58, green: 0.31, blue: 0.18))
                    .textCase(.uppercase)
                Text(content.title)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.22, green: 0.16, blue: 0.12))
                    .lineLimit(1)
                Text(content.message)
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(Color(red: 0.34, green: 0.27, blue: 0.22))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(Color(red: 1.0, green: 0.96, blue: 0.85).opacity(0.98))
                    .overlay(alignment: .bottomTrailing) {
                        PetTravelPawView()
                            .frame(width: 34, height: 30)
                            .padding(10)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .stroke(Color(red: 0.72, green: 0.53, blue: 0.34).opacity(0.24), lineWidth: 1)
                    }
            )

            PetTravelBubblePointer(direction: pointerDirection)
                .fill(Color(red: 1.0, green: 0.96, blue: 0.85).opacity(0.98))
                .frame(width: 10, height: 18)
                .offset(x: pointerDirection == .trailing ? 5 : -5)
        }
        .padding(8)
    }

    private var pawBadge: some View {
        PetTravelPawView()
            .frame(width: 30, height: 28)
            .padding(10)
            .background(
                Circle()
                    .fill(Color(red: 1.0, green: 0.96, blue: 0.85).opacity(0.98))
                    .overlay {
                        Circle()
                            .stroke(Color(red: 0.72, green: 0.53, blue: 0.34).opacity(0.24), lineWidth: 1)
                    }
            )
            .padding(8)
    }

    private var pointerAlignment: Alignment {
        switch edge {
        case .bottomTrailing:
            .bottomTrailing
        case .bottomLeading:
            .bottomLeading
        case .trailing:
            .trailing
        case .leading:
            .leading
        }
    }

    private var pointerDirection: PetTravelBubblePointer.Direction {
        PetTravelBubblePointer.direction(for: edge)
    }
}
