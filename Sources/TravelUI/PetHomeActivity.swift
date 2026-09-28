import Foundation

/// Local animation only: these activities never mutate the trip or generate model requests.
public enum PetHomeActivity: String, CaseIterable, Sendable {
    case watching, dozing, stretching, greeting, strolling, playing

    public var title: String {
        switch self {
        case .watching: "在门口看风景"
        case .dozing: "眯着眼打个盹"
        case .stretching: "舒展一下身体"
        case .greeting: "抬爪打个招呼"
        case .strolling: "在门前溜达"
        case .playing: "自己玩一会儿"
        }
    }
    public var animation: PetAnimation {
        switch self {
        case .watching: PetAnimation(row: 9, frameCount: 8)
        case .dozing: PetAnimation(row: 0, frames: [4, 4, 4, 4, 4, 3, 4, 4])
        case .stretching: PetAnimation(row: 5, frames: [1, 2, 3, 3, 2, 1, 0, 0])
        case .greeting: PetAnimation(row: 3, frameCount: 4)
        case .strolling: PetAnimation(row: 1, frameCount: 8)
        case .playing: PetAnimation(row: 4, frameCount: 5)
        }
    }
    public func animation(facingLeft: Bool) -> PetAnimation {
        self == .strolling && facingLeft ? PetAnimation(row: 2, frameCount: 8) : animation
    }
    public var duration: Double {
        switch self {
        case .dozing: 65
        case .watching: 30
        case .stretching: 14
        case .greeting: 12
        case .strolling: 18
        case .playing: 16
        }
    }
    public var horizontalOffset: CGFloat { self == .strolling ? -14 : 0 }
    public static func initial(hour: Int) -> Self { isNight(hour) ? .dozing : .watching }
    public static func next(after previous: Self, hour: Int, seed: UInt64) -> Self {
        let choices: [Self] = isNight(hour)
            ? [.dozing, .dozing, .dozing, .watching, .stretching]
            : [.watching, .watching, .dozing, .stretching, .greeting, .strolling, .playing]
        let candidates = choices.filter { $0 != previous }
        return candidates[Int(seed % UInt64(candidates.count))]
    }
    private static func isNight(_ hour: Int) -> Bool { hour >= 22 || hour < 8 }
}
