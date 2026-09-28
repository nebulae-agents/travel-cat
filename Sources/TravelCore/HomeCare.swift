import Foundation

public enum HomeCareAction: String, Codable, CaseIterable, Sendable {
    case snack, play, brush, blanket
    public var title: String {
        switch self { case .snack: "喂点零食"; case .play: "逗猫玩耍"; case .brush: "轻轻梳毛"; case .blanket: "铺好小毯" }
    }
    public var symbol: String {
        switch self { case .snack: "fish.fill"; case .play: "tennisball.fill"; case .brush: "sparkles"; case .blanket: "moon.zzz.fill" }
    }
    public var response: String {
        switch self {
        case .snack: "小黑吃完零食，抬起爪子向你道谢。"
        case .play: "小黑扑向玩具，开心地追着你的手转。"
        case .brush: "梳子轻轻滑过，小黑舒服地伸了个懒腰。"
        case .blanket: "小黑窝进柔软的小毯，眯着眼打起了盹。"
        }
    }
}

public struct HomeCareVisit: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let action: HomeCareAction
    public let occurredAt: Date
    public init(action: HomeCareAction, occurredAt: Date) {
        id = UUID(); self.action = action; self.occurredAt = occurredAt
    }
}

public enum HomeCareError: Error, Equatable, Sendable { case catIsAway, coolingDown }

public struct HomeCareState: Codable, Equatable, Sendable {
    public static let cooldown: TimeInterval = 5
    public private(set) var history: [HomeCareVisit]
    public init(history: [HomeCareVisit] = []) { self.history = history }
    public var latest: HomeCareVisit? { history.last }
    public func isCoolingDown(at now: Date) -> Bool {
        guard let latest else { return false }
        let elapsed = now.timeIntervalSince(latest.occurredAt)
        return elapsed >= 0 && elapsed < Self.cooldown
    }
    public mutating func perform(_ action: HomeCareAction, phase: TravelPhase, now: Date) throws {
        guard phase == .resting || phase == .preparing else { throw HomeCareError.catIsAway }
        guard !isCoolingDown(at: now) else { throw HomeCareError.coolingDown }
        history.append(HomeCareVisit(action: action, occurredAt: now))
        history = Array(history.suffix(30))
    }
}
