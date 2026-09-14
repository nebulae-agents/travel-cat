import AppKit
import SwiftUI

/// Owns desktop visibility independently of utility pages and travel state.
@MainActor
public final class DesktopPetController: ObservableObject {
    @Published public private(set) var isHidden: Bool
    public let windowController: PetWindowController
    private let defaults: UserDefaults
    private static let hiddenKey = "TravelCat.desktopPet.hidden"

    public init(content: AnyView, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isHidden = defaults.bool(forKey: Self.hiddenKey)
        windowController = PetWindowController(
            content: content, positionStore: WindowPositionStore(defaults: defaults)
        )
    }

    public func restoreVisibility() {
        guard !isHidden else { return }
        windowController.showPet()
    }

    public func hide() {
        isHidden = true
        defaults.set(true, forKey: Self.hiddenKey)
        windowController.window?.orderOut(nil)
    }

    public func show() {
        isHidden = false
        defaults.set(false, forKey: Self.hiddenKey)
        windowController.ensureWindowIsVisible()
        windowController.showPet()
    }
}
