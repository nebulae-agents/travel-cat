import TravelCore

/// Actions verified against the bundled version 2 sheet only.
enum HomePetAction: CaseIterable, Equatable, Sendable {
    case standingBlink, raisedPaw, crouchJumpLand, headTilt, sittingRaisedPaw

    var animation: PetAnimation {
        switch self {
        case .standingBlink: PetAnimation(row: 0, frameCount: 6)
        case .raisedPaw: PetAnimation(row: 3, frameCount: 4)
        case .crouchJumpLand: PetAnimation(row: 4, frameCount: 5)
        case .headTilt: PetAnimation(row: 6, frameCount: 6)
        case .sittingRaisedPaw: PetAnimation(row: 8, frameCount: 6)
        }
    }

    static func select(after previous: Self?, choice: Int) -> Self {
        let candidates = allCases.filter { $0 != previous }
        let remainder = choice % candidates.count
        return candidates[remainder < 0 ? remainder + candidates.count : remainder]
    }
}

struct PetPlaybackState: Equatable {
    private(set) var animation = PetAnimation.animation(for: .resting)
    private(set) var frameIndex = 0
    private(set) var homeAction: HomePetAction?
    private var enabled = false

    mutating func reset(phase: TravelPhase, profile: CharacterProfile, enabled: Bool = true) {
        self.enabled = enabled
        homeAction = phase == .resting && profile == .defaultBlackCat ? .standingBlink : nil
        animation = homeAction?.animation ?? PetAnimation.animation(for: phase)
        frameIndex = 0
    }

    mutating func advance(choice: Int) {
        guard enabled else { return }
        if frameIndex + 1 < animation.frameCount {
            frameIndex += 1
        } else {
            if let previous = homeAction {
                let next = HomePetAction.select(after: previous, choice: choice)
                homeAction = next
                animation = next.animation
            }
            frameIndex = 0
        }
    }
}
