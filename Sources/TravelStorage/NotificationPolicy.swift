import Foundation
import TravelCore

public enum NotificationDecision: Equatable, Sendable {
    case deliver
    case `defer`
    case deliverSummary
}

public struct NotificationPolicy: Equatable, Sendable {
    public let quietStart: Int
    public let quietEnd: Int

    public init(quietStart: Int, quietEnd: Int) {
        self.quietStart = TravelSettings.canonicalHour(quietStart)
        self.quietEnd = TravelSettings.canonicalHour(quietEnd)
    }

    public func isQuiet(hour: Int) -> Bool {
        let hour = TravelSettings.canonicalHour(hour)
        guard quietStart != quietEnd else { return false }
        if quietStart < quietEnd {
            return hour >= quietStart && hour < quietEnd
        }
        return hour >= quietStart || hour < quietEnd
    }
}

public enum NotificationEvent: Codable, Equatable, Sendable {
    case postcard(id: UUID, place: String?, mood: String)
    case returned(tripID: UUID, mood: String)

    public var identifier: String {
        switch self {
        case let .postcard(id, _, _): "postcard-\(id.uuidString.lowercased())"
        case let .returned(tripID, _): "returned-\(tripID.uuidString.lowercased())"
        }
    }

    public var category: String {
        switch self {
        case .postcard: "postcard"
        case .returned: "returned-home"
        }
    }

    public var title: String {
        switch self {
        case .postcard: "黑猫寄来一张明信片"
        case .returned: "黑猫旅行归来"
        }
    }

    public var body: String {
        switch self {
        case let .postcard(_, place, mood):
            [place, mood].compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }.joined(separator: " · ")
        case let .returned(_, mood):
            mood.isEmpty ? "黑猫已经平安到家。" : "现在的心情：\(mood)"
        }
    }
}

public enum NotificationDelivery: Equatable, Sendable {
    case event(NotificationEvent)
    case summary(count: Int)
}

public enum NotificationDetector {
    public static func detect(
        previous: RepositoryContents,
        current: RepositoryContents
    ) -> [NotificationEvent] {
        let oldByID = Dictionary(uniqueKeysWithValues: previous.events.map { ($0.id, $0) })
        var result = current.events.compactMap { event -> NotificationEvent? in
            guard event.postcardStatus == .ready || event.postcardStatus == .imageUnavailable else {
                return nil
            }
            if let old = oldByID[event.id], old.postcardStatus == .ready || old.postcardStatus == .imageUnavailable {
                return nil
            }
            return .postcard(id: event.id, place: event.location?.place, mood: event.mood.label)
        }
        let wasResting = previous.snapshot.phase == .resting
        if !wasResting, current.snapshot.phase == .resting, let tripID = current.snapshot.tripID {
            result.append(.returned(tripID: tripID, mood: current.snapshot.mood.label))
        }
        return result
    }

    public static func detectUnavailable(
        previous: RepositoryContents,
        current: RepositoryContents
    ) -> [NotificationEvent] {
        let oldByID = Dictionary(uniqueKeysWithValues: previous.events.map { ($0.id, $0) })
        return current.events.compactMap { event in
            guard event.postcardStatus == .imageUnavailable,
                  oldByID[event.id]?.postcardStatus != .imageUnavailable else {
                return nil
            }
            return .postcard(
                id: event.id,
                place: event.location?.place,
                mood: event.mood.label
            )
        }
    }
}

public final class NotificationCoordinator: @unchecked Sendable {
    public typealias Deliver = (NotificationDelivery) -> Void
    private let defaults: UserDefaults
    private let deliver: Deliver
    private let lock = NSLock()
    private let deliveredKey = "travel-cat.notification-delivered-ids"
    private let deferredKey = "travel-cat.notification-deferred-ids"
    private let summaryPendingKey = "travel-cat.notification-summary-pending-ids"
    private let notificationPendingKey = "travel-cat.notification-pending-events"
    private var inFlightSummaryIDs: Set<String>?
    private var inFlightNotificationIDs: Set<String> = []

    private struct PendingSummary: Codable, Equatable {
        let ids: [String]
        let count: Int
        let category: String
    }

    private struct PendingNotification: Codable, Equatable {
        let identifier: String
        let category: String
        let title: String
        let body: String
        let event: NotificationEvent

        init(event: NotificationEvent) {
            identifier = event.identifier
            category = event.category
            title = event.title
            body = event.body
            self.event = event
        }
    }

    public init(defaults: UserDefaults = .standard, deliver: @escaping Deliver) {
        self.defaults = defaults
        self.deliver = deliver
    }

    @discardableResult
    public func process(
        _ events: [NotificationEvent],
        policy: NotificationPolicy,
        hour: Int
    ) -> NotificationDecision {
        var planned: [NotificationDelivery] = []
        let decision: NotificationDecision = lock.withLock {
            let deliveredIDs = Set(defaults.stringArray(forKey: deliveredKey) ?? [])
            var deferredIDs = Set(defaults.stringArray(forKey: deferredKey) ?? [])
            var pendingNotifications = loadPendingNotifications()
            let pendingIDs = Set(pendingNotifications.map(\.identifier))
            let fresh = events.filter {
                !deliveredIDs.contains($0.identifier)
                    && !deferredIDs.contains($0.identifier)
                    && !pendingIDs.contains($0.identifier)
            }
            if policy.isQuiet(hour: hour) {
                deferredIDs.formUnion(fresh.map(\.identifier))
                defaults.set(deferredIDs.sorted(), forKey: deferredKey)
                return .defer
            }

            for pending in pendingNotifications where !inFlightNotificationIDs.contains(pending.identifier) {
                inFlightNotificationIDs.insert(pending.identifier)
                planned.append(.event(pending.event))
            }

            if let pending = loadPendingSummary() {
                deferredIDs.formUnion(fresh.map(\.identifier))
                defaults.set(deferredIDs.sorted(), forKey: deferredKey)
                let pendingIDs = Set(pending.ids)
                if inFlightSummaryIDs != pendingIDs {
                    inFlightSummaryIDs = pendingIDs
                    planned.append(.summary(count: pending.count))
                }
                return .deliverSummary
            }

            if !deferredIDs.isEmpty {
                deferredIDs.formUnion(fresh.map(\.identifier))
                let ids = deferredIDs.sorted()
                let pending = PendingSummary(ids: ids, count: ids.count, category: "quiet-summary")
                savePendingSummary(pending)
                defaults.set(ids, forKey: deferredKey)
                inFlightSummaryIDs = Set(ids)
                planned.append(.summary(count: pending.count))
                return .deliverSummary
            }

            for event in fresh {
                let pending = PendingNotification(event: event)
                pendingNotifications.append(pending)
                inFlightNotificationIDs.insert(pending.identifier)
                planned.append(.event(event))
            }
            savePendingNotifications(pendingNotifications)
            return .deliver
        }
        planned.forEach(deliver)
        return decision
    }

    public func deliverySucceeded(_ delivery: NotificationDelivery) {
        lock.withLock {
            if case let .event(event) = delivery {
                var deliveredIDs = Set(defaults.stringArray(forKey: deliveredKey) ?? [])
                var pending = loadPendingNotifications()
                guard pending.contains(where: { $0.identifier == event.identifier }) else {
                    inFlightNotificationIDs.remove(event.identifier)
                    return
                }
                deliveredIDs.insert(event.identifier)
                pending.removeAll(where: { $0.identifier == event.identifier })
                defaults.set(deliveredIDs.sorted(), forKey: deliveredKey)
                savePendingNotifications(pending)
                inFlightNotificationIDs.remove(event.identifier)
                return
            }
            guard case let .summary(deliveredCount) = delivery else { return }
            guard let pending = loadPendingSummary(), pending.count == deliveredCount else {
                inFlightSummaryIDs = nil
                return
            }
            var deliveredIDs = Set(defaults.stringArray(forKey: deliveredKey) ?? [])
            var deferredIDs = Set(defaults.stringArray(forKey: deferredKey) ?? [])
            deliveredIDs.formUnion(pending.ids)
            deferredIDs.subtract(pending.ids)
            defaults.set(deliveredIDs.sorted(), forKey: deliveredKey)
            defaults.set(deferredIDs.sorted(), forKey: deferredKey)
            defaults.removeObject(forKey: summaryPendingKey)
            inFlightSummaryIDs = nil
        }
    }

    public func deliveryFailed(_ delivery: NotificationDelivery) {
        lock.withLock {
            switch delivery {
            case let .event(event):
                inFlightNotificationIDs.remove(event.identifier)
            case .summary:
                inFlightSummaryIDs = nil
            }
        }
    }

    private func loadPendingSummary() -> PendingSummary? {
        if let data = defaults.data(forKey: summaryPendingKey),
           let pending = try? JSONDecoder().decode(PendingSummary.self, from: data) {
            return pending
        }
        if let legacyIDs = defaults.stringArray(forKey: summaryPendingKey), !legacyIDs.isEmpty {
            let ids = legacyIDs.sorted()
            return PendingSummary(ids: ids, count: ids.count, category: "quiet-summary")
        }
        return nil
    }

    private func savePendingSummary(_ pending: PendingSummary) {
        if let data = try? JSONEncoder().encode(pending) {
            defaults.set(data, forKey: summaryPendingKey)
        }
    }


    private func loadPendingNotifications() -> [PendingNotification] {
        guard let data = defaults.data(forKey: notificationPendingKey) else { return [] }
        return (try? JSONDecoder().decode([PendingNotification].self, from: data)) ?? []
    }

    private func savePendingNotifications(_ pending: [PendingNotification]) {
        if pending.isEmpty {
            defaults.removeObject(forKey: notificationPendingKey)
        } else if let data = try? JSONEncoder().encode(pending) {
            defaults.set(data, forKey: notificationPendingKey)
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
