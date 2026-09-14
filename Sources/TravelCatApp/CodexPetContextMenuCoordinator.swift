import AppKit
import CoreGraphics

@MainActor
final class CodexPetContextMenuCoordinator {
    private var monitor: CodexPetContextMenuMonitor?
    private let menuController: TravelCatPetMenuController

    var permissionState: CodexPetMenuPermissionState {
        monitor?.permissionState ?? .needsPermission
    }

    init(
        menuState: @escaping () -> TravelCatPetMenuState,
        locator: @escaping () -> CodexPetSelection?,
        showCurrentJourney: @escaping () -> Void,
        showLatestPostcard: @escaping () -> Void,
        showLatestAlbum: @escaping () -> Void,
        runTemporaryTest: @escaping () -> Void,
        closeBypass: @escaping () -> Void,
        closeDriver: CodexPetNativeMenuDriving,
        reportError: @escaping (String) -> Void,
        permissionStateChanged: @escaping (CodexPetMenuPermissionState) -> Void = { _ in }
    ) {
        var latestSelection: CodexPetSelection?

        let menuController = TravelCatPetMenuController { action in
            switch action {
            case .currentJourney:
                showCurrentJourney()
            case .latestPostcard:
                showLatestPostcard()
            case .album:
                showLatestAlbum()
            case .temporaryTest:
                runTemporaryTest()
            case .closePet:
                guard let selection = latestSelection,
                      let current = locator(),
                      current.ownerPID == selection.ownerPID else {
                    reportError("无法安全调用 Codex 的“关闭宠物”操作")
                    return
                }
                let closeForwarder = CodexPetCloseForwarder(
                    bypass: closeBypass,
                    driver: closeDriver
                )
                let success = closeForwarder.close(
                    selection: current,
                    clickPoint: CGPoint(x: current.inputBounds.midX, y: current.inputBounds.midY)
                )
                if !success {
                    reportError("无法安全调用 Codex 的“关闭宠物”操作")
                }
            }
        }
        self.menuController = menuController
        self.monitor = CodexPetContextMenuMonitor(
            locator: locator,
            onRightClick: { selection, point in
                DispatchQueue.main.async {
                    latestSelection = selection
                    menuController.present(
                        state: menuState(),
                        at: selection.appKitPoint(fromInput: point)
                    )
                }
            },
            permissionStateChanged: permissionStateChanged
        )
    }

    func start(requestPermission: Bool) {
        monitor?.start(requestPermission: requestPermission)
    }

    func requestPermissionAndStart() {
        monitor?.requestPermissionAndStart()
    }

    func stop() {
        monitor?.stop()
    }

    func bypassNextRightClick() {
        monitor?.bypassNextRightClick()
    }

}
