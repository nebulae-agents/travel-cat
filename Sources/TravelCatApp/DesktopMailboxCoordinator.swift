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
    private var contentBinding: DesktopMailboxContentBinding?

    init(desktop: DesktopPetController, pet: AppModel, agents: AgentWorkbenchModel?,
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
        contentBinding = DesktopMailboxContentBinding(pet: pet, agents: agents) { [weak mailbox] model in
            mailbox?.update(model: model)
        }
        subscriptions.append(desktop.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.updatePresentation() }
        })
        updatePresentation()
    }

    func updateAgents(_ model: AgentWorkbenchModel?) { contentBinding?.updateAgents(model) }

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
        contentBinding?.shutdown(); contentBinding = nil
    }
}

/// Rebinds only the workbench side of the shared inbox; pet observation lives independently.
@MainActor
final class DesktopMailboxContentBinding {
    private weak var agents: AgentWorkbenchModel?
    private var petSubscription: AnyCancellable?
    private var agentSubscription: AnyCancellable?
    private var generation = UUID()
    private var initialized = false
    private var stopped = false
    private let update: (AgentWorkbenchModel?) -> Void

    init(pet: AppModel, agents: AgentWorkbenchModel?, update: @escaping (AgentWorkbenchModel?) -> Void) {
        self.update = update
        petSubscription = pet.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.stopped else { return }
                self.update(self.agents)
            }
        }
        updateAgents(agents)
    }
    func updateAgents(_ model: AgentWorkbenchModel?) {
        guard !stopped, !initialized || agents !== model else { return }
        initialized = true
        generation = UUID()
        let current = generation
        agentSubscription = nil
        agents = model
        update(model)
        if let model {
            agentSubscription = model.objectWillChange.sink { [weak self, weak model] _ in
                Task { @MainActor in
                    guard let self, !self.stopped, self.generation == current,
                          let model, self.agents === model else { return }
                    self.update(model)
                }
            }
        }
    }
    func shutdown() {
        stopped = true; generation = UUID()
        petSubscription = nil; agentSubscription = nil; agents = nil
    }
}
