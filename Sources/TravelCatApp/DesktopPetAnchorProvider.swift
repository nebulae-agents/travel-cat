import AppKit
import TravelUI

/// Geometry in AppKit screen coordinates; no external process/window identity.
struct PetCompanionAnchor: Equatable {
    let appKitBounds: CGRect
    let screenFrame: CGRect
}

@MainActor
enum DesktopPetAnchorProvider {
    static func current(controller: DesktopPetController?) -> PetCompanionAnchor? {
        guard let controller, !controller.isHidden,
              let window = controller.windowController.window, window.isVisible,
              let screen = window.screen else { return nil }
        return PetCompanionAnchor(appKitBounds: window.frame, screenFrame: screen.visibleFrame)
    }
}
