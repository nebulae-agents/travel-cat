import AppKit
import Combine
import TravelUI

/// Keeps the separate mailbox beside the installed app's current desktop pet window.
@MainActor
final class DesktopMailboxCoordinator {
    private let desktop: DesktopPetController
    private let mailbox: AgentLauncherController
    private var notifications: [NSObjectProtocol] = []
    private var subscriptions: [AnyCancellable] = []

    init(desktop: DesktopPetController, pet: AppModel, agents: AgentWorkbenchModel,
         openPostcard: @escaping (UUID) -> Void, openAlbum: @escaping () -> Void,
         openAgents: @escaping () -> Void) {
        self.desktop = desktop
        mailbox = AgentLauncherController(model: agents, petModel: pet,
            openPostcard: openPostcard, openAlbum: openAlbum, action: openAgents)

        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            notifications.append(NotificationCenter.default.addObserver(forName: name,
                object: desktop.windowController.window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updatePresentation() }
            })
        }
        notifications.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePresentation() }
        })
        subscriptions.append(pet.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.mailbox.refresh() }
        })
        subscriptions.append(agents.objectWillChange.sink { [weak self, weak agents] _ in
            Task { @MainActor in
                guard let agents else { return }
                self?.mailbox.update(model: agents)
            }
        })
        subscriptions.append(desktop.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.updatePresentation() }
        })
        updatePresentation()
    }

    func updatePresentation() {
        guard !desktop.isHidden, let window = desktop.windowController.window, window.isVisible else {
            mailbox.hide()
            return
        }
        mailbox.show(beside: window.frame)
    }

    func shutdown() {
        mailbox.hide()
        notifications.forEach(NotificationCenter.default.removeObserver)
        notifications.removeAll()
        subscriptions.removeAll()
    }
}
