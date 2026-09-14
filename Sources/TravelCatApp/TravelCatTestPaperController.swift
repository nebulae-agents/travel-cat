import AppKit
import TravelStorage

enum TravelCatTestPaperRequest: Equatable {
    case allowed
    case fastTestRequired
    case followRequired
    case petUnavailable

    static func evaluate(
        isFastTestEnabled: Bool,
        followCodexPet: Bool,
        petAvailable: Bool
    ) -> Self {
        guard isFastTestEnabled else { return .fastTestRequired }
        guard followCodexPet else { return .followRequired }
        guard petAvailable else { return .petUnavailable }
        return .allowed
    }

    var message: String? {
        switch self {
        case .allowed: nil
        case .fastTestRequired: "请先开启快速测试。"
        case .followRequired: "请先开启“旅行纸条与状态变化提示”。"
        case .petUnavailable: "请先显示 Travel Cat 桌面小猫。"
        }
    }
}

@MainActor
final class TravelCatTestPaperController {
    private let bubbleController: PetTravelBubbleController
    private let locate: () -> PetCompanionAnchor?

    init(
        locator: @escaping () -> PetCompanionAnchor?,
        scheduler: BubbleScheduling? = nil
    ) {
        locate = locator
        if let scheduler {
            bubbleController = PetTravelBubbleController(
                locator: locator,
                scheduler: scheduler,
                tapMenuEnabled: false
            )
        } else {
            bubbleController = PetTravelBubbleController(locator: locator, tapMenuEnabled: false)
        }
    }

    var presentation: PetTravelBubbleController.Presentation { bubbleController.presentation }
    var isVisible: Bool { bubbleController.window?.isVisible == true }

    @discardableResult
    func request(isFastTestEnabled: Bool, followCodexPet: Bool) -> TravelCatTestPaperRequest {
        let result = TravelCatTestPaperRequest.evaluate(
            isFastTestEnabled: isFastTestEnabled,
            followCodexPet: followCodexPet,
            petAvailable: locate() != nil
        )
        guard result == .allowed else { return result }

        let shown = bubbleController.show(
            delivery: .summary(
                promptIDs: ["travel-cat-fast-test"],
                count: 1
            ),
            onTap: {},
            onAvailableForReplacement: {}
        )
        return shown ? .allowed : .petUnavailable
    }

    func dismiss() {
        bubbleController.dismissPresentation()
    }

    func settingsDidChange(isFastTestEnabled: Bool, followCodexPet: Bool) {
        guard isFastTestEnabled, followCodexPet else {
            dismiss()
            return
        }
    }
}
