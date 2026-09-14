import XCTest
import AppKit
import TravelStorage
@testable import TravelCatApp

@MainActor
final class TravelCatTestPaperControllerTests: XCTestCase {
    func testUnavailableAndDisabledGuidanceRefersOnlyToOwnedPet() {
        XCTAssertEqual(TravelCatTestPaperRequest.petUnavailable.message, "请先显示 Travel Cat 桌面小猫。")
        XCTAssertEqual(TravelCatTestPaperRequest.followRequired.message, "请先开启“旅行纸条与状态变化提示”。")
    }
    func testRequestRequiresPersistedFastModeAndFollowPreference() {
        XCTAssertEqual(
            TravelCatTestPaperRequest.evaluate(
                isFastTestEnabled: false,
                followCodexPet: true,
                petAvailable: true
            ),
            .fastTestRequired
        )
        XCTAssertEqual(
            TravelCatTestPaperRequest.evaluate(
                isFastTestEnabled: true,
                followCodexPet: false,
                petAvailable: true
            ),
            .followRequired
        )
    }

    func testRequestReportsUnavailablePetAndAllowsOnlyVisiblePet() {
        XCTAssertEqual(
            TravelCatTestPaperRequest.evaluate(
                isFastTestEnabled: true,
                followCodexPet: true,
                petAvailable: false
            ),
            .petUnavailable
        )
        XCTAssertEqual(
            TravelCatTestPaperRequest.evaluate(
                isFastTestEnabled: true,
                followCodexPet: true,
                petAvailable: true
            ),
            .allowed
        )
    }

    func testTestDeliveryRendersAsAnExplicitNonPersistentTestPaper() {
        XCTAssertEqual(
            PetTravelBubbleContent(
                delivery: .summary(promptIDs: ["travel-cat-fast-test"], count: 1)
            ),
            PetTravelBubbleContent(
                eyebrow: "快速测试",
                title: "测试纸条",
                message: "这是临时测试，不会写入旅行数据。"
            )
        )
    }

    func testRepeatedAllowedRequestsReplaceTheVisibleTransientPaper() throws {
        let scheduler = TestBubbleScheduler()
        let controller = TravelCatTestPaperController(
            locator: { testSelection() },
            scheduler: scheduler
        )
        defer { controller.dismiss() }

        XCTAssertEqual(controller.request(isFastTestEnabled: true, followCodexPet: true), .allowed)
        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(controller.presentation, .slip)

        XCTAssertEqual(controller.request(isFastTestEnabled: true, followCodexPet: true), .allowed)
        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(controller.presentation, .slip)

        scheduler.advance(by: 7.9)
        XCTAssertEqual(controller.presentation, .slip)
        scheduler.advance(by: 0.2)
        XCTAssertEqual(controller.presentation, .paw)
    }

    func testModeOffOrFollowOffDismissesVisibleTestPaper() {
        let controller = TravelCatTestPaperController(
            locator: { testSelection() },
            scheduler: TestBubbleScheduler()
        )
        defer { controller.dismiss() }
        XCTAssertEqual(controller.request(isFastTestEnabled: true, followCodexPet: true), .allowed)
        XCTAssertTrue(controller.isVisible)

        controller.settingsDidChange(isFastTestEnabled: true, followCodexPet: false)
        XCTAssertFalse(controller.isVisible)

        XCTAssertEqual(controller.request(isFastTestEnabled: true, followCodexPet: true), .allowed)
        controller.settingsDidChange(isFastTestEnabled: false, followCodexPet: true)
        XCTAssertFalse(controller.isVisible)
    }

    func testUnavailableLocatorNeverCreatesVisibleTestPaper() {
        let controller = TravelCatTestPaperController(
            locator: { nil },
            scheduler: TestBubbleScheduler()
        )

        XCTAssertEqual(controller.request(isFastTestEnabled: true, followCodexPet: true), .petUnavailable)
        XCTAssertFalse(controller.isVisible)
    }

    func testDisabledRequestDoesNotPresentAndPersistedDailyStateWinsOverFastDraft() {
        let controller = TravelCatTestPaperController(
            locator: { testSelection() },
            scheduler: TestBubbleScheduler()
        )
        defer { controller.dismiss() }

        let lifecycle = TravelSettingsLifecycle(
            initialSettings: TravelSettings(mode: .daily),
            persist: { _ in throw TestSettingsError.denied },
            apply: { _ in }
        )
        _ = lifecycle.save(TravelSettings(mode: .fast))

        XCTAssertFalse(lifecycle.effectiveSettings.isFastTestEnabled)
        XCTAssertEqual(
            controller.request(
                isFastTestEnabled: lifecycle.effectiveSettings.isFastTestEnabled,
                followCodexPet: lifecycle.effectiveSettings.followCodexPet
            ),
            .fastTestRequired
        )
        XCTAssertFalse(controller.isVisible)
    }
}

private enum TestSettingsError: Error { case denied }

@MainActor
private final class TestBubbleScheduler: BubbleScheduling {
    private final class Token: BubbleCancellation {
        let deadline: TimeInterval
        let action: @MainActor () -> Void
        var isCancelled = false

        init(deadline: TimeInterval, action: @escaping @MainActor () -> Void) {
            self.deadline = deadline
            self.action = action
        }

        func cancel() { isCancelled = true }
    }

    private var now: TimeInterval = 0
    private var tokens: [Token] = []

    func after(_ seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> BubbleCancellation {
        let token = Token(deadline: now + seconds, action: action)
        tokens.append(token)
        return token
    }

    func advance(by interval: TimeInterval) {
        let target = now + interval
        while let next = tokens
            .filter({ !$0.isCancelled && $0.deadline <= target })
            .min(by: { $0.deadline < $1.deadline }) {
            now = next.deadline
            next.cancel()
            next.action()
        }
        now = target
    }
}

private func testSelection() -> PetCompanionAnchor {
    let bounds = CGRect(x: 700, y: 420, width: 120, height: 120)
    return PetCompanionAnchor(
        appKitBounds: bounds,
        screenFrame: CGRect(x: 0, y: 0, width: 1_200, height: 900)
    )
}
