import Foundation
import TravelUI

/// A retained paper callback must not open a replaced session or a production model.
@MainActor
final class JourneyTestRouteGate {
    private let isEnabled: () -> Bool
    private let currentSessionID: () -> UUID?

    init(isEnabled: @escaping () -> Bool, currentSessionID: @escaping () -> UUID?) {
        self.isEnabled = isEnabled
        self.currentSessionID = currentSessionID
    }

    func permits(_ sessionID: UUID) -> Bool {
        isEnabled() && currentSessionID() == sessionID
    }

    @discardableResult
    func route(_ route: PetTravelRoute, sessionID: UUID, model: AppModel) -> Bool {
        guard permits(sessionID) else { return false }
        switch route {
        case .status:
            model.openStatusFromMenu()
        case let .postcard(eventID, tripID):
            guard model.openPostcardFromPrompt(eventID: eventID, tripID: tripID) else { return false }
        case let .album(tripID):
            guard model.openAlbumFromPrompt(tripID: tripID) else { return false }
        }
        return true
    }
}
