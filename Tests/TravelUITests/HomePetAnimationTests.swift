import XCTest
import TravelCore
@testable import TravelUI

final class HomePetAnimationTests: XCTestCase {
    func testPlaybackIdentityIncludesEveryLifecycleInput() {
        let original = CharacterProfile.defaultBlackCat
        let custom = CharacterProfile(id: original.id, displayName: "Other", description: original.description,
            spriteVersionNumber: 2, sprite: original.sprite, referenceImages: [], source: original.source)
        let baseline = PetPlaybackIdentity(phase: .resting, profile: original, reduceMotion: false,
            visible: true, available: true, dataRoot: nil)
        let variants = [
            PetPlaybackIdentity(phase: .transit, profile: original, reduceMotion: false, visible: true, available: true, dataRoot: nil),
            PetPlaybackIdentity(phase: .resting, profile: custom, reduceMotion: false, visible: true, available: true, dataRoot: nil),
            PetPlaybackIdentity(phase: .resting, profile: original, reduceMotion: true, visible: true, available: true, dataRoot: nil),
            PetPlaybackIdentity(phase: .resting, profile: original, reduceMotion: false, visible: false, available: true, dataRoot: nil),
            PetPlaybackIdentity(phase: .resting, profile: original, reduceMotion: false, visible: true, available: false, dataRoot: nil),
            PetPlaybackIdentity(phase: .resting, profile: original, reduceMotion: false, visible: true, available: true, dataRoot: URL(fileURLWithPath: "/tmp/pet-fixture"))
        ]
        for variant in variants { XCTAssertNotEqual(variant, baseline) }
        XCTAssertTrue(baseline.enabled)
        for variant in variants[2...4] { XCTAssertFalse(variant.enabled) }
    }

    func testSameIDCustomProfileKeepsBaselineAnimation() {
        let original = CharacterProfile.defaultBlackCat
        let custom = CharacterProfile(id: original.id, displayName: "Other", description: original.description,
            spriteVersionNumber: 2, sprite: original.sprite, referenceImages: [], source: original.source)
        var playback = PetPlaybackState()
        playback.reset(phase: .resting, profile: custom)
        for _ in 0..<100 { playback.advance(choice: 2) }
        XCTAssertNil(playback.homeAction)
        XCTAssertEqual(playback.animation, PetAnimation.animation(for: .resting))
    }
    func testSelectorExcludesPreviousAndHandlesAllIntegers() {
        for previous in HomePetAction.allCases {
            for choice in [Int.min, -1, 0, 1, Int.max] {
                let next = HomePetAction.select(after: previous, choice: choice)
                XCTAssertNotEqual(next, previous)
                XCTAssertNotNil(PetSpriteLayout.version2.frameRect(row: next.animation.row, frame: next.animation.frameCount - 1))
            }
        }
    }

    func testPlaybackCompletesActionBeforeSelectingNext() {
        var playback = PetPlaybackState()
        playback.reset(phase: .resting, profile: .defaultBlackCat)
        let first = playback.animation
        for frame in 1..<first.frameCount {
            playback.advance(choice: Int.min)
            XCTAssertEqual(playback.animation, first)
            XCTAssertEqual(playback.frameIndex, frame)
        }
        playback.advance(choice: Int.min)
        XCTAssertNotEqual(playback.animation, first)
        XCTAssertEqual(playback.frameIndex, 0)
    }

    func testDisabledPlaybackAndResetStayOnFirstFrame() {
        var playback = PetPlaybackState()
        playback.reset(phase: .resting, profile: .defaultBlackCat, enabled: false)
        for _ in 0..<30 { playback.advance(choice: 2) }
        XCTAssertEqual(playback.frameIndex, 0)
        playback.reset(phase: .transit, profile: .defaultBlackCat)
        for _ in 0..<19 { playback.advance(choice: 2) }
        XCTAssertEqual(playback.animation, PetAnimation.animation(for: .transit))
        XCTAssertEqual(playback.frameIndex, 3)
    }
}
