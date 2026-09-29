import AppKit
import SwiftUI
import TravelCore

public struct PetHouseStatus: Equatable, Sendable {
    public let phase: TravelPhase
    public let showsLetter: Bool
    public init(phase: TravelPhase, hasUnreadPostcard: Bool) {
        self.phase = phase
        showsLetter = hasUnreadPostcard || phase == .postcardReady
    }
    public var showsCat: Bool { phase == .resting || phase == .preparing }
    public var title: String {
        switch phase {
        case .resting: "在家休息"
        case .preparing: "收拾行囊"
        case .transit: "正在路上"
        case .exploring: "探索远方"
        case .postcardReady: "远方来信"
        case .returning: "正在回家"
        }
    }
    public var symbol: String {
        switch phase {
        case .resting: "moon.zzz.fill"
        case .preparing: "suitcase.fill"
        case .transit: "tram.fill"
        case .exploring: "leaf.fill"
        case .postcardReady: "envelope.fill"
        case .returning: "house.fill"
        }
    }
}

/// The desktop always keeps the same little home, independent of journey navigation.
@MainActor
public struct PetHouseView: View {
    private let status: PetHouseStatus
    private let isActive: Bool
    private let reaction: HomeCareVisit?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isReacting = false
    @State private var facingLeft = false
    @State private var strollOffset: CGFloat = 0
    @State private var activity: PetHomeActivity = .initial(hour: Calendar.current.component(.hour, from: Date()))
    private static let cottage = TravelUIResources.bundle.url(forResource: "pet-home-cottage", withExtension: "png").flatMap(NSImage.init(contentsOf:))
    public init(phase: TravelPhase, hasUnreadPostcard: Bool, isActive: Bool = true, reaction: HomeCareVisit? = nil) {
        self.reaction = reaction
        self.isActive = isActive
        status = PetHouseStatus(phase: phase, hasUnreadPostcard: hasUnreadPostcard)
    }
    public var body: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 8)
            ZStack {
                if let cottage = Self.cottage {
                    Image(nsImage: cottage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 220, height: 207)
                    .accessibilityHidden(true)
                }
                if status.showsCat {
                    PetSpriteView(animation: status.phase == .resting || isReacting ? activity.animation(facingLeft: facingLeft) : PetAnimation.animation(for: status.phase),
                                  isAnimating: isActive, frameDuration: status.phase == .resting ? (activity == .dozing ? 0.7 : activity == .watching ? 0.45 : 0.22) : 0.18)
                        .scaleEffect(0.70)
                        .shadow(color: .black.opacity(0.22), radius: 2, x: 0, y: 2)
                        .offset(x: 28 + (status.phase == .resting && !reduceMotion ? strollOffset : 0), y: 53)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 4), value: strollOffset)
                }
                if status.showsLetter {
                    Image(systemName: "envelope.badge.fill")
                        .font(.system(size: 20)).symbolRenderingMode(.palette)
                        .foregroundStyle(Color(red: 0.77, green: 0.29, blue: 0.19), Color(red: 0.99, green: 0.94, blue: 0.78))
                        .padding(7)
                        .background(.regularMaterial, in: Circle())
                        .shadow(color: .black.opacity(0.2), radius: 3, y: 2)
                        .rotationEffect(.degrees(-9)).offset(x: 80, y: 61)
                }
            }.frame(width: 220, height: 207)
            VStack(spacing: 2) {
                Text("小黑的家")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.45, green: 0.37, blue: 0.27))
                Label(status.phase == .resting || isReacting ? activity.title : status.title, systemImage: status.symbol)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.26, green: 0.28, blue: 0.22))
            }
            .padding(.horizontal, 13).padding(.vertical, 6)
            .background(Color(red: 0.98, green: 0.95, blue: 0.87).opacity(0.96), in: RoundedRectangle(cornerRadius: 14))
            Spacer(minLength: 12)
        }
        .frame(width: 240, height: 280)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("小黑的家，\(status.phase == .resting || isReacting ? activity.title : status.title)\(status.showsLetter ? "，有来信" : "")")
        .accessibilityHint("点击查看当前旅程，右键打开菜单")
        .task(id: "\(status.phase.rawValue)-\(isActive)-\(reduceMotion)-\(reaction?.id.uuidString ?? "none")") {
            strollOffset = 0
            isReacting = false
            guard status.showsCat, isActive else { return }
            if let reaction, (0..<10).contains(Date().timeIntervalSince(reaction.occurredAt)) {
                isReacting = true
                switch reaction.action {
                case .snack: activity = .greeting
                case .play: activity = .playing
                case .brush: activity = .stretching
                case .blanket: activity = .dozing
                }
                do { try await Task.sleep(for: .seconds(6)) } catch { return }
            }
            isReacting = false
            guard status.phase == .resting else { return }
            activity = .initial(hour: Calendar.current.component(.hour, from: Date()))
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                do {
                    if activity == .strolling {
                        for offset: CGFloat in [-14, 10, 0] {
                            facingLeft = offset < strollOffset
                            strollOffset = offset
                            try await Task.sleep(for: .seconds(6))
                        }
                    } else {
                        strollOffset = 0
                        try await Task.sleep(for: .seconds(activity.duration))
                    }
                } catch { return }
                guard !Task.isCancelled else { return }
                activity = .next(after: activity, hour: Calendar.current.component(.hour, from: Date()),
                                 seed: UInt64.random(in: .min ... .max))
            }
        }
    }
}
