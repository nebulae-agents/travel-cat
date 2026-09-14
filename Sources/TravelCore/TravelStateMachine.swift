public struct TravelStateMachine: Sendable {
    public enum Violation: Error, Equatable {
        case illegal(TravelPhase, TravelPhase)
    }

    public init() {}

    public func requireTransition(from current: TravelPhase, to next: TravelPhase) throws {
        guard Self.isAllowedTransition(from: current, to: next) else {
            throw Violation.illegal(current, next)
        }
    }

    private static func isAllowedTransition(from current: TravelPhase, to next: TravelPhase) -> Bool {
        switch current {
        case .resting:
            next == .preparing
        case .preparing:
            next == .transit || next == .resting
        case .transit:
            next == .exploring || next == .returning
        case .exploring:
            next == .postcardReady || next == .transit || next == .returning
        case .postcardReady:
            next == .exploring || next == .returning
        case .returning:
            next == .resting
        }
    }
}
