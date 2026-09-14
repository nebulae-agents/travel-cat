import CryptoKit
import Foundation
import TravelStorage
import UserNotifications

enum PetTravelRoute: Codable, Equatable, Sendable {
    case status
    case postcard(eventID: UUID, tripID: UUID)
    case album(UUID)
}

extension PetTravelPromptDelivery {
    var route: PetTravelRoute {
        switch self {
        case let .prompt(.postcardReady(eventID, tripID, _, _, _)):
            .postcard(eventID: eventID, tripID: tripID)
        case let .prompt(.returned(_, tripID, _)):
            .album(tripID)
        case .prompt(.departed), .summary:
            .status
        }
    }
}

enum PetTravelNotificationPayloadError: Error, Equatable {
    case invalidDelivery
}

struct PetTravelNotificationPayload {
    let identifier: String
    let title: String
    let body: String
    let route: PetTravelRoute
    let userInfo: [AnyHashable: Any]

    init(delivery: PetTravelPromptDelivery) throws {
        guard !delivery.identifiers.isEmpty,
              delivery.identifiers.allSatisfy({ !$0.isEmpty }) else {
            throw PetTravelNotificationPayloadError.invalidDelivery
        }
        if case let .summary(promptIDs, count) = delivery,
           count <= 0 || promptIDs.count != count {
            throw PetTravelNotificationPayloadError.invalidDelivery
        }

        let content = PetTravelBubbleContent(delivery: delivery)
        identifier = try Self.identifier(for: delivery)
        title = content.title
        body = content.message
        route = delivery.route
        userInfo = Self.userInfo(for: route)
    }

    static func route(userInfo: [AnyHashable: Any]) -> PetTravelRoute? {
        guard let values = strictStringDictionary(userInfo),
              let tag = values["route"] else {
            return nil
        }
        switch tag {
        case "status":
            guard Set(values.keys) == ["route"] else { return nil }
            return .status
        case "postcard":
            guard Set(values.keys) == ["route", "eventID", "tripID"],
                  let eventID = canonicalUUID(values["eventID"]),
                  let tripID = canonicalUUID(values["tripID"]) else {
                return nil
            }
            return .postcard(eventID: eventID, tripID: tripID)
        case "album":
            guard Set(values.keys) == ["route", "tripID"],
                  let tripID = canonicalUUID(values["tripID"]) else {
                return nil
            }
            return .album(tripID)
        default:
            return nil
        }
    }

    private static func userInfo(for route: PetTravelRoute) -> [AnyHashable: Any] {
        switch route {
        case .status:
            ["route": "status"]
        case let .postcard(eventID, tripID):
            [
                "route": "postcard",
                "eventID": eventID.uuidString.lowercased(),
                "tripID": tripID.uuidString.lowercased(),
            ]
        case let .album(tripID):
            [
                "route": "album",
                "tripID": tripID.uuidString.lowercased(),
            ]
        }
    }

    private static func identifier(
        for delivery: PetTravelPromptDelivery
    ) throws -> String {
        let domain: String
        switch delivery {
        case .prompt:
            domain = "event"
        case .summary:
            domain = "batch"
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let payload = try? encoder.encode(delivery) else {
            throw PetTravelNotificationPayloadError.invalidDelivery
        }
        var material = Data("travel-cat-pet-prompt-id/v1/\(domain)\u{0}".utf8)
        material.append(payload)
        let digest = SHA256.hash(data: material)
            .map { String(format: "%02x", $0) }
            .joined()
        return "travel-cat-pet-v1-\(domain)-\(digest)"
    }

    private static func strictStringDictionary(
        _ userInfo: [AnyHashable: Any]
    ) -> [String: String]? {
        var result: [String: String] = [:]
        for (rawKey, rawValue) in userInfo {
            guard let key = rawKey as? String,
                  let value = rawValue as? String,
                  result.updateValue(value, forKey: key) == nil else {
                return nil
            }
        }
        return result
    }

    private static func canonicalUUID(_ text: String?) -> UUID? {
        guard let text,
              let value = UUID(uuidString: text),
              value.uuidString.lowercased() == text else {
            return nil
        }
        return value
    }
}

enum PetTravelNotificationActionRouter {
    static func route(
        actionIdentifier: String,
        userInfo: [AnyHashable: Any]
    ) -> PetTravelRoute? {
        guard actionIdentifier == UNNotificationDefaultActionIdentifier else { return nil }
        return PetTravelNotificationPayload.route(userInfo: userInfo)
    }
}

@MainActor
final class PetTravelPromptService {
    typealias ShowBubble = (
        PetTravelPromptDelivery,
        @escaping () -> Void,
        @escaping () -> Void
    ) -> Bool
    typealias PostNotification = (PetTravelPromptDelivery) async -> Bool
    typealias ApplyBubblePreference = (Bool) -> Void

    private let coordinator: PetTravelPromptCoordinator
    private let showBubble: ShowBubble
    private let postNotification: PostNotification
    private let routeHandler: (PetTravelRoute) -> Void
    private let stateChanged: () -> Void
    private let calendar: Calendar
    private let scheduler: BubbleScheduling
    private let clock: () -> Date
    private let preferBubble: (TravelSettings) -> Bool
    private let applyBubblePreference: ApplyBubblePreference
    private var queue: [PetTravelPromptDelivery] = []
    private var isDelivering = false
    private var bubbleEnabled = true
    private var latestSettings = TravelSettings()
    private var quietEndToken: BubbleCancellation?
    private var unavailableRetryToken: BubbleCancellation?
    private var unavailableRetryScheduleID = UUID()
    private var unavailableRetryAttempt = 0
    private var quietEndScheduleID = UUID()
    private var attemptID: UUID?
    private var retryAfterAttemptID: UUID?
    private var repositoryObservationRetryPending = false
    private static let unavailableRetryDelays: [TimeInterval] = [1, 2, 4, 8, 16]
    private(set) var storageError: PetTravelPromptCoordinatorError?

    init(
        coordinator: PetTravelPromptCoordinator,
        showBubble: @escaping ShowBubble,
        postNotification: @escaping PostNotification,
        route: @escaping (PetTravelRoute) -> Void,
        stateChanged: @escaping () -> Void = {},
        calendar: Calendar = .current,
        scheduler: BubbleScheduling = TimerBubbleScheduler(),
        clock: @escaping () -> Date = Date.init,
        preferBubble: @escaping (TravelSettings) -> Bool = { _ in true },
        applyBubblePreference: @escaping ApplyBubblePreference = { _ in }
    ) {
        self.coordinator = coordinator
        self.showBubble = showBubble
        self.postNotification = postNotification
        routeHandler = route
        self.stateChanged = stateChanged
        self.calendar = calendar
        self.scheduler = scheduler
        self.clock = clock
        self.preferBubble = preferBubble
        self.applyBubblePreference = applyBubblePreference
    }

    var hasPendingOrStorageError: Bool {
        if storageError != nil || isDelivering || !queue.isEmpty { return true }
        do {
            return try coordinator.pendingCount > 0
        } catch {
            return true
        }
    }

    func ingestCurrent(settings: TravelSettings, now: Date = Date()) {
        updateContext(settings: settings, now: now)
        do {
            let policy = policy(for: settings)
            try coordinator.ingestCurrent(
                policy: policy,
                hour: calendar.component(.hour, from: now)
            )
            repositoryObservationRetryPending = false
            try appendNext(policy: policy, now: now)
            storageError = nil
        } catch let error as PetTravelPromptCoordinatorError {
            if error.isRepositoryFailure {
                repositoryObservationRetryPending = true
            }
            storageError = error
            stateChanged()
            return
        } catch {
            preconditionFailure("unexpected prompt coordinator error: \(error)")
        }
        deliverNextIfNeeded()
        stateChanged()
    }

    func retry(settings: TravelSettings, now: Date = Date()) {
        updateContext(settings: settings, now: now)
        do {
            let policy = policy(for: settings)
            if repositoryObservationRetryPending {
                try coordinator.ingestCurrent(
                    policy: policy,
                    hour: calendar.component(.hour, from: now)
                )
                repositoryObservationRetryPending = false
            }
            try appendNext(policy: policy, now: now)
            storageError = nil
        } catch let error as PetTravelPromptCoordinatorError {
            if error.isRepositoryFailure {
                repositoryObservationRetryPending = true
            }
            storageError = error
            stateChanged()
            return
        } catch {
            preconditionFailure("unexpected prompt coordinator error: \(error)")
        }
        deliverNextIfNeeded()
        stateChanged()
    }

    func settingsDidChange(settings: TravelSettings, now: Date = Date()) {
        updateContext(settings: settings, now: now)
        let activeAttempt = attemptID
        if let activeAttempt {
            retryAfterAttemptID = activeAttempt
        }
        applyBubblePreference(bubbleEnabled)

        if activeAttempt == nil {
            retry(settings: settings, now: now)
        } else if attemptID == activeAttempt {
            stateChanged()
        }
    }

    private func updateContext(settings: TravelSettings, now: Date) {
        latestSettings = settings
        bubbleEnabled = preferBubble(settings)
        if !bubbleEnabled {
            cancelUnavailableRetry()
        }
        scheduleQuietEnd(settings: settings, now: now)
    }

    private func appendNext(policy: NotificationPolicy, now: Date) throws {
        guard queue.isEmpty else { return }
        queue.append(contentsOf: try coordinator.nextDelivery(
            policy: policy,
            hour: calendar.component(.hour, from: now)
        ))
    }

    private func deliverNextIfNeeded() {
        guard !isDelivering, let next = queue.first else { return }
        isDelivering = true
        let currentAttempt = UUID()
        attemptID = currentAttempt

        if bubbleEnabled, showBubble(
            next,
            { [weak self] in self?.routeHandler(next.route) },
            { [weak self] in self?.finishCurrent(attemptID: currentAttempt) }
        ) {
            cancelUnavailableRetry()
            acknowledgeSuccessfulDelivery(next, attemptID: currentAttempt)
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let succeeded = await postNotification(next)
            guard attemptID == currentAttempt else { return }
            let shouldRetryAfterCurrent = retryAfterAttemptID == currentAttempt
            if succeeded {
                cancelUnavailableRetry()
                let acknowledged = acknowledgeSuccessfulDelivery(next, attemptID: currentAttempt)
                if acknowledged {
                    finishCurrent(attemptID: currentAttempt)
                }
            } else {
                abandonCurrent(next, attemptID: currentAttempt)
                if shouldRetryAfterCurrent {
                    retryAfterAttemptID = nil
                    retry(settings: latestSettings, now: clock())
                } else if bubbleEnabled {
                    scheduleUnavailableRetry()
                }
            }
            stateChanged()
        }
    }

    @discardableResult
    private func acknowledgeSuccessfulDelivery(
        _ delivery: PetTravelPromptDelivery,
        attemptID expectedAttempt: UUID
    ) -> Bool {
        guard attemptID == expectedAttempt, queue.first == delivery else { return false }
        do {
            try coordinator.deliverySucceeded(delivery)
            queue.removeFirst()
            storageError = nil
            stateChanged()
            return true
        } catch let error as PetTravelPromptCoordinatorError {
            // The coordinator may have durably COMMITted and released ownership
            // before a final validation throws. Best-effort release is safe, but
            // its secondary invalidAcknowledgement must never replace `error`.
            try? coordinator.deliveryFailed(delivery)
            queue.removeAll()
            storageError = error
            isDelivering = false
            attemptID = nil
            if retryAfterAttemptID == expectedAttempt {
                retryAfterAttemptID = nil
            }
            stateChanged()
            return false
        } catch {
            preconditionFailure("unexpected prompt coordinator error: \(error)")
        }
    }

    private func abandonCurrent(
        _ delivery: PetTravelPromptDelivery,
        attemptID expectedAttempt: UUID
    ) {
        guard attemptID == expectedAttempt, queue.first == delivery else { return }
        do {
            try coordinator.deliveryFailed(delivery)
        } catch let error as PetTravelPromptCoordinatorError {
            storageError = error
        } catch {
            preconditionFailure("unexpected prompt coordinator error: \(error)")
        }
        queue.removeAll()
        isDelivering = false
        attemptID = nil
    }

    private func scheduleQuietEnd(settings: TravelSettings, now: Date) {
        let scheduleID = UUID()
        quietEndScheduleID = scheduleID
        quietEndToken?.cancel()
        quietEndToken = nil
        let policy = policy(for: settings)
        guard policy.isQuiet(hour: calendar.component(.hour, from: now)),
              let quietEnd = calendar.nextDate(
                after: now,
                matching: DateComponents(hour: policy.quietEnd, minute: 0, second: 0),
                matchingPolicy: .nextTime
              ) else {
            return
        }
        quietEndToken = scheduler.after(max(1, quietEnd.timeIntervalSince(now))) { [weak self] in
            guard let self, quietEndScheduleID == scheduleID else { return }
            quietEndToken = nil
            retry(settings: latestSettings, now: clock())
        }
    }

    private func scheduleUnavailableRetry() {
        guard unavailableRetryToken == nil,
              unavailableRetryAttempt < Self.unavailableRetryDelays.count
        else { return }
        let scheduleID = UUID()
        unavailableRetryScheduleID = scheduleID
        let delay = Self.unavailableRetryDelays[unavailableRetryAttempt]
        unavailableRetryAttempt += 1
        unavailableRetryToken = scheduler.after(delay) { [weak self] in
            guard let self, unavailableRetryScheduleID == scheduleID else { return }
            unavailableRetryToken = nil
            retry(settings: latestSettings, now: clock())
        }
    }

    private func cancelUnavailableRetry() {
        unavailableRetryScheduleID = UUID()
        unavailableRetryToken?.cancel()
        unavailableRetryToken = nil
        unavailableRetryAttempt = 0
    }

    private func finishCurrent(attemptID expectedAttempt: UUID) {
        guard attemptID == expectedAttempt, isDelivering else { return }
        isDelivering = false
        attemptID = nil
        if retryAfterAttemptID == expectedAttempt {
            retryAfterAttemptID = nil
        }
        retry(settings: latestSettings, now: clock())
    }

    private func policy(for settings: TravelSettings) -> NotificationPolicy {
        NotificationPolicy(quietStart: settings.quietStart, quietEnd: settings.quietEnd)
    }
}

private extension PetTravelPromptCoordinatorError {
    var isRepositoryFailure: Bool {
        switch self {
        case .repositoryUnavailable, .repositoryInvalid:
            true
        case .corruptValue, .encodingFailed, .persistenceFailed, .invalidAcknowledgement:
            false
        }
    }
}
