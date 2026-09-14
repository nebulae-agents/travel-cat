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
    private let center: UNUserNotificationCenter
    private let calendar: Calendar
    private var coordinator: NotificationCoordinator!
    private var summaryTimer: Timer?
    private(set) var authorizationDenied = false
    private var isAuthorized = false
    var promptRouteHandler: ((PetTravelRoute) -> Void)?

    init(
        center: UNUserNotificationCenter = .current(),
        defaults: UserDefaults = .standard,
        calendar: Calendar = .current
    ) {
        self.center = center
        self.calendar = calendar
        super.init()
        center.delegate = self
        coordinator = NotificationCoordinator(defaults: defaults) { [weak self] delivery in
            Task { @MainActor in await self?.deliver(delivery) }
        }
    }

    func postTravelPromptFallback(_ delivery: PetTravelPromptDelivery) async -> Bool {
        guard isAuthorized,
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
            try await center.add(
                UNNotificationRequest(
                    identifier: payload.identifier,
                    content: content,
                    trigger: nil
                )
            )
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
        await MainActor.run { self.promptRouteHandler?(route) }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        PetTravelForegroundNotificationPolicy.options(
            categoryIdentifier: notification.request.content.categoryIdentifier
        )
    }

    func requestAuthorization() async {
        do {
            isAuthorized = try await center.requestAuthorization(options: [.alert, .sound])
            authorizationDenied = !isAuthorized
        } catch {
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
        guard isAuthorized else { return }
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
        guard isAuthorized else { return }
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
        guard isAuthorized else { return }
        coordinator.process(
            [],
            policy: NotificationPolicy(quietStart: settings.quietStart, quietEnd: settings.quietEnd),
            hour: calendar.component(.hour, from: now)
        )
        scheduleQuietEnd(settings: settings, now: now)
    }

    private func deliver(_ delivery: NotificationDelivery) async {
        guard !authorizationDenied else { return }
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
            try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
            coordinator.deliverySucceeded(delivery)
        } catch {
            coordinator.deliveryFailed(delivery)
            log("notification delivery failed: \(error)")
        }
    }

    private func scheduleQuietEnd(settings: TravelSettings, now: Date) {
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
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.coordinator.process([], policy: policy, hour: policy.quietEnd)
                self.summaryTimer = nil
            }
        }
    }

    private func log(_ message: String) {
        try? FileHandle.standardError.write(contentsOf: Data("TravelCat: \(message)\n".utf8))
    }
}
