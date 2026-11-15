import Foundation
import TravelStorage
import UserNotifications

enum PetTravelForegroundNotificationPolicy {
    static func options(
        categoryIdentifier: String
    ) -> UNNotificationPresentationOptions {
        guard categoryIdentifier == "travel-cat-pet-prompt" else { return [] }
        return [.banner, .list, .sound]
    }
}

@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter?
    private let send: (UNNotificationRequest) async throws -> Void
    private let authorize: () async throws -> Bool
    private let calendar: Calendar
    private var coordinator: NotificationCoordinator!
    private var summaryTimer: Timer?
    private var summaryGeneration = UUID()
    private(set) var authorizationDenied = false
    private var isAuthorized = false
    private let operations = AgentXOwnedTaskScope()
    var hasOwnedOperations: Bool { !operations.isIdle }
    func fence() { summaryGeneration = UUID(); operations.fence(); summaryTimer?.invalidate(); summaryTimer = nil }
    func suspendAndWait() async { fence(); await operations.suspendAndWait() }
    @discardableResult func resumeWithoutRunning() -> Bool { operations.resumeWithoutRunning() }
    var promptRouteHandler: ((PetTravelRoute) -> Void)?

    init(
        center: UNUserNotificationCenter? = .current(),
        send: ((UNNotificationRequest) async throws -> Void)? = nil,
        authorized: Bool = false,
        authorize: (() async throws -> Bool)? = nil,
        defaults: UserDefaults = .standard,
        calendar: Calendar = .current
    ) {
        self.center = center
        self.send = send ?? { request in guard let center else { throw CancellationError() }; try await center.add(request) }
        self.authorize = authorize ?? { try await center?.requestAuthorization(options: [.alert, .sound]) ?? false }
        self.isAuthorized = authorized
        self.calendar = calendar
        super.init()
        center?.delegate = self
        coordinator = NotificationCoordinator(defaults: defaults) { [weak self] delivery in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.operations.start({ await self.deliver(delivery) }) == nil { self.coordinator.deliveryFailed(delivery) }
            }
        }
    }

    func postTravelPromptFallback(_ delivery: PetTravelPromptDelivery) async -> Bool {
        var result = false
        guard let task = operations.start({ result = await self.deliverPrompt(delivery) }) else { return false }
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        return result
    }

    private func deliverPrompt(_ delivery: PetTravelPromptDelivery) async -> Bool {
        guard operations.isEnabled, !Task.isCancelled, isAuthorized,
              let payload = try? PetTravelNotificationPayload(delivery: delivery) else {
            return false
        }
        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.body = payload.body
        content.categoryIdentifier = "travel-cat-pet-prompt"
        content.sound = .default
        content.userInfo = payload.userInfo
        do {
            try await send(
                UNNotificationRequest(
                    identifier: payload.identifier,
                    content: content,
                    trigger: nil
                )
            )
            guard operations.isEnabled, !Task.isCancelled else {
                center?.removePendingNotificationRequests(withIdentifiers: [payload.identifier])
                center?.removeDeliveredNotifications(withIdentifiers: [payload.identifier])
                return false
            }
            return true
        } catch {
            log("pet prompt notification failed: \(error)")
            return false
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let route = PetTravelNotificationActionRouter.route(
            actionIdentifier: response.actionIdentifier,
            userInfo: response.notification.request.content.userInfo
        ) else {
            return
        }
        await MainActor.run { if self.operations.isEnabled { self.promptRouteHandler?(route) } }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let category = notification.request.content.categoryIdentifier
        return await MainActor.run {
            guard self.operations.isEnabled else { return [] }
            return PetTravelForegroundNotificationPolicy.options(categoryIdentifier: category)
        }
    }

    /// Refresh permission only. Persisted pending notifications are not replayed here.
    func refreshAuthorizationForExplicitOpen() async { await requestAuthorization() }

    func requestAuthorization() async {
        guard operations.isEnabled, !Task.isCancelled else { return }
        guard let task = operations.start({ await self.performAuthorization() }) else { return }
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private func performAuthorization() async {
        guard operations.isEnabled, !Task.isCancelled else { return }
        do {
            let authorized = try await authorize()
            guard operations.isEnabled, !Task.isCancelled else { return }
            isAuthorized = authorized
            authorizationDenied = !authorized
        } catch {
            guard operations.isEnabled, !Task.isCancelled else { return }
            authorizationDenied = true
            log("notification authorization failed: \(error)")
        }
    }

    func process(
        previous: RepositoryContents?,
        current: RepositoryContents,
        settings: TravelSettings,
        now: Date = Date()
    ) {
        guard operations.isEnabled, isAuthorized else { return }
        let events = previous.map { NotificationDetector.detect(previous: $0, current: current) } ?? []
        coordinator.process(
            events,
            policy: NotificationPolicy(quietStart: settings.quietStart, quietEnd: settings.quietEnd),
            hour: calendar.component(.hour, from: now)
        )
        scheduleQuietEnd(settings: settings, now: now)
    }

    func processUnavailable(
        previous: RepositoryContents?,
        current: RepositoryContents,
        settings: TravelSettings,
        now: Date = Date()
    ) {
        guard operations.isEnabled, isAuthorized else { return }
        let events = previous.map {
            NotificationDetector.detectUnavailable(previous: $0, current: current)
        } ?? []
        coordinator.process(
            events,
            policy: NotificationPolicy(quietStart: settings.quietStart, quietEnd: settings.quietEnd),
            hour: calendar.component(.hour, from: now)
        )
        scheduleQuietEnd(settings: settings, now: now)
    }

    func settingsDidChange(_ settings: TravelSettings, now: Date = Date()) {
        guard operations.isEnabled, isAuthorized else { return }
        coordinator.process(
            [],
            policy: NotificationPolicy(quietStart: settings.quietStart, quietEnd: settings.quietEnd),
            hour: calendar.component(.hour, from: now)
        )
        scheduleQuietEnd(settings: settings, now: now)
    }

    private func deliver(_ delivery: NotificationDelivery) async {
        guard operations.isEnabled, !Task.isCancelled, !authorizationDenied else { coordinator.deliveryFailed(delivery); return }
        let content = UNMutableNotificationContent()
        switch delivery {
        case let .event(event):
            content.title = event.title
            content.body = event.body
            content.categoryIdentifier = event.category
        case let .summary(count):
            content.title = "黑猫旅行动态"
            content.body = "安静时段有 \(count) 条新动态。"
        }
        do {
            let identifier: String
            switch delivery {
            case let .event(event): identifier = event.identifier
            case .summary: identifier = "travel-cat-quiet-summary"
            }
            try await send(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
            guard operations.isEnabled, !Task.isCancelled else {
                center?.removePendingNotificationRequests(withIdentifiers: [identifier])
                center?.removeDeliveredNotifications(withIdentifiers: [identifier])
                coordinator.deliveryFailed(delivery)
                return
            }
            coordinator.deliverySucceeded(delivery)
        } catch {
            coordinator.deliveryFailed(delivery)
            log("notification delivery failed: \(error)")
        }
    }

    private func scheduleQuietEnd(settings: TravelSettings, now: Date) {
        let generation = UUID(); summaryGeneration = generation
        summaryTimer?.invalidate()
        summaryTimer = nil
        let policy = NotificationPolicy(quietStart: settings.quietStart, quietEnd: settings.quietEnd)
        let hour = calendar.component(.hour, from: now)
        guard policy.isQuiet(hour: hour),
              let quietEnd = calendar.nextDate(
                after: now,
                matching: DateComponents(hour: policy.quietEnd, minute: 0, second: 0),
                matchingPolicy: .nextTime
              ) else { return }
        summaryTimer = Timer.scheduledTimer(withTimeInterval: max(1, quietEnd.timeIntervalSince(now)), repeats: false) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.operations.isEnabled, self.summaryGeneration == generation else { return }
                self.coordinator.process([], policy: policy, hour: policy.quietEnd)
                self.summaryTimer = nil
            }
        }
    }

    private func log(_ message: String) {
        try? FileHandle.standardError.write(contentsOf: Data("TravelCat: \(message)\n".utf8))
    }
}
