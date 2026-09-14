import Foundation
import TravelCore

public struct CurrentPetStatus: Equatable, Sendable {
    public enum Scene: Equatable, Sendable { case home, packing, away, unknown }
    public let title: String
    public let scene: Scene
    public let location: String?
    public let transport: String?
    public let summary: String?
    public let updatedAt: Date?
    public let codexActivityNotice = "Travel Cat 任务活动暂未接入；动画仅示意旅行阶段。"

    public var desktopSpritePhase: TravelPhase? {
        switch scene {
        case .home: .resting
        case .packing: .preparing
        case .away, .unknown: nil
        }
    }

    public init(snapshot: TripSnapshot, events: [TripEvent], now: Date) {
        guard snapshot.lastUpdatedAt <= now else {
            title = "当前状态暂不可用"
            scene = .unknown
            location = nil
            transport = nil
            summary = nil
            updatedAt = nil
            return
        }
        switch snapshot.phase {
        case .resting: (title, scene) = ("在家", .home)
        case .preparing: (title, scene) = ("准备出游", .packing)
        case .transit: (title, scene) = ("正在途中", .away)
        case .exploring: (title, scene) = ("正在探索", .away)
        case .postcardReady: (title, scene) = ("旅行中 · 明信片时刻", .away)
        case .returning: (title, scene) = ("正在返程", .away)
        }
        let matches = events.filter { $0.id == snapshot.lastEventID }
        let event = matches.count == 1 ? matches.first : nil
        let bound = event.flatMap { event -> TripEvent? in
            guard event.tripID == snapshot.tripID, event.phase == snapshot.phase,
                  event.occurredAt <= snapshot.lastUpdatedAt, event.occurredAt <= now else { return nil }
            return event
        }
        location = scene == .away ? bound?.location.map { PostcardDisplayLocation().resolveCompact($0) } : nil
        transport = scene == .away ? Self.nonempty(bound?.transport) : nil
        summary = Self.nonempty(bound?.summary)
        updatedAt = snapshot.lastUpdatedAt
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
