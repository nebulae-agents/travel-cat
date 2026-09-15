import AppKit
import SwiftUI
import Combine

@MainActor
final class DesktopPetVisibility: ObservableObject {
    @Published var isHidden: Bool
    init(isHidden: Bool) { self.isHidden = isHidden }
}

@MainActor
private struct DesktopPetPlaybackRoot: View {
    @ObservedObject var visibility: DesktopPetVisibility
    let content: AnyView
    var body: some View {
        content.environment(\.petPlaybackEnabled, !visibility.isHidden)
    }
}

/// Owns desktop visibility independently of utility pages and travel state.
@MainActor
public final class DesktopPetController: ObservableObject {
    public var isHidden: Bool { visibility.isHidden }
    let visibility: DesktopPetVisibility
    private var visibilitySubscription: AnyCancellable?
    public let windowController: PetWindowController
    private let defaults: UserDefaults
    private static let hiddenKey = "TravelCat.desktopPet.hidden"

    public init(content: AnyView, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let visibility = DesktopPetVisibility(isHidden: defaults.bool(forKey: Self.hiddenKey))
        self.visibility = visibility
        windowController = PetWindowController(
            content: AnyView(DesktopPetPlaybackRoot(visibility: visibility, content: content)),
            positionStore: WindowPositionStore(defaults: defaults)
        )
        visibilitySubscription = visibility.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    public func restoreVisibility() {
        guard !isHidden else { return }
        windowController.showPet()
    }

    public func hide() {
        visibility.isHidden = true
        defaults.set(true, forKey: Self.hiddenKey)
        windowController.window?.orderOut(nil)
    }

    public func show() {
        visibility.isHidden = false
        defaults.set(false, forKey: Self.hiddenKey)
        windowController.ensureWindowIsVisible()
        windowController.showPet()
    }
}
