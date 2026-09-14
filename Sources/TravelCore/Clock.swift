import Foundation

public protocol TravelClock: Sendable {
    var now: Date { get }
}

public struct SystemClock: TravelClock {
    public init() {}

    public var now: Date {
        Date()
    }
}

public struct FixedClock: TravelClock {
    public let now: Date

    public init(now: Date) {
        self.now = now
    }
}
