import Foundation
import TravelStorage
import TravelUI

/// All delivery acknowledgements and routes belong to this one test repository.
@MainActor
final class JourneyTestPresentation {
    let sessionID: UUID
    private let session: JourneyTestSession
    private let gate: JourneyTestRouteGate
    private let bubble: PetTravelBubbleController
    private var service: PetTravelPromptService?

    init(
        session: JourneyTestSession,
        model: AppModel,
        gate: JourneyTestRouteGate,
        petLocator: @escaping () -> PetCompanionAnchor?,
        showWindow: @escaping () -> Void
    ) throws {
        try session.validate()
        self.session = session
        sessionID = session.id
        self.gate = gate
        let bubble = PetTravelBubbleController(locator: petLocator)
        self.bubble = bubble
        let repository = try TravelRepository(root: session.root)
        service = PetTravelPromptService(
            coordinator: try PetTravelPromptCoordinator(repository: repository),
            showBubble: { [weak self, weak bubble] delivery, onTap, available in
                guard let self, self.isAllowed else { return false }
                return bubble?.show(
                    delivery: delivery,
                    isTestJourney: true,
                    onTap: { [weak self] in
                        guard self?.isAllowed == true else { return }
                        onTap()
                    },
                    onAvailableForReplacement: { [weak self] in
                        guard self?.isAllowed == true else { return }
                        available()
                    }
                ) ?? false
            },
            // Production system notifications have no test-session identity. Do not use them.
            postNotification: { _ in false },
            route: { [weak self, weak model] route in
                guard let self, self.isAllowed, let model,
                      gate.route(route, sessionID: session.id, model: model) else { return }
                showWindow()
            },
            preferBubble: { $0.followCodexPet },
            applyBubblePreference: { [weak bubble] enabled in
                bubble?.settingsDidChange(followCodexPet: enabled)
            }
        )
    }

    private var isAllowed: Bool {
        gate.permits(sessionID) && (try? session.validate()) != nil
    }

    func refresh(followCodexPet: Bool) {
        guard isAllowed else { dismiss(); return }
        bubble.settingsDidChange(followCodexPet: followCodexPet)
        // Tests must remain observable during quiet hours without changing saved settings.
        let settings = TravelSettings(mode: .fast, quietStart: 0, quietEnd: 0, followCodexPet: followCodexPet)
        service?.ingestCurrent(settings: settings, now: Date())
    }

    func dismiss() {
        bubble.dismissPresentation()
        service = nil
    }
}
