import AppKit
import SwiftUI
import XCTest
import TravelCore
import TravelStorage
import TravelUI
@testable import TravelCatApp

@MainActor
final class PetTravelBubbleControllerTests: XCTestCase {
    func testLostMouseUpCancelsDragAndAllowsNextClickWithoutSaving() throws {
        let suite = "LostMouseUp-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let scheduler = ManualBubbleScheduler()
        var pressed = true
        let controller = PetTravelBubbleController(locator: StubBubbleLocator(selection: mascotSelection()).locate,
            scheduler: scheduler, collapseAnimator: nil, offsetStore: PetCompanionOffsetStore(defaults: defaults),
            primaryButtonPressed: { pressed })
        defer { controller.close() }
        var taps = 0
        XCTAssertTrue(controller.show(delivery: .prompt(postcardPrompt()), onTap: { taps += 1 }, onAvailableForReplacement: {}))
        let panel = try XCTUnwrap(controller.window as? PetTravelBubblePanel)
        func mouse(_ type: NSEvent.EventType, _ x: CGFloat = 30) throws {
            panel.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: 30), modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
        }
        try mouse(.leftMouseDown)
        try mouse(.leftMouseDragged, 50)
        let staleWatch = try XCTUnwrap(scheduler.activeTokens.first)
        pressed = false
        scheduler.advance(by: 0.25)
        XCTAssertNil(PetCompanionOffsetStore(defaults: defaults).load())
        XCTAssertEqual(scheduler.activeCount, 2)
        try mouse(.leftMouseUp)
        XCTAssertEqual(taps, 0)
        try mouse(.leftMouseDown)
        try mouse(.leftMouseUp)
        XCTAssertEqual(taps, 1)
        scheduler.fireEvenIfCancelled(staleWatch)
        XCTAssertEqual(scheduler.activeCount, 0)
        XCTAssertEqual(controller.presentation, .hidden)
        XCTAssertNil(PetCompanionOffsetStore(defaults: defaults).load())
    }
    func testInitialAutomaticOffsetFollowsAcrossMidpointWithoutBeingPersisted() throws {
        let suite = "InitialOffset-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let scheduler = ManualBubbleScheduler()
        let locator = StubBubbleLocator(selection: mascotSelection())
        let controller = PetTravelBubbleController(locator: locator.locate, scheduler: scheduler, collapseAnimator: nil,
            offsetStore: PetCompanionOffsetStore(defaults: defaults), screenFrames: { [CGRect(x: -1200, y: 0, width: 2400, height: 900)] })
        defer { controller.close() }
        XCTAssertTrue(controller.show(delivery: .prompt(postcardPrompt()), onTap: {}, onAvailableForReplacement: {}))
        let panel = try XCTUnwrap(controller.window)
        let initial = panel.frame
        locator.selection = mascotSelection(anchor: CGRect(x: 200, y: 420, width: 120, height: 120))
        scheduler.advance(by: 0.25)
        XCTAssertEqual(panel.frame, initial.offsetBy(dx: -500, dy: 0))
        scheduler.advance(by: 8)
        XCTAssertEqual(panel.frame.midX, initial.midX - 500)
        XCTAssertEqual(panel.frame.midY, initial.midY)
        XCTAssertNil(PetCompanionOffsetStore(defaults: defaults).load())
    }

    func testPanelClickDispatchUsesHostedPawHitRegion() throws {
        let scheduler = ManualBubbleScheduler()
        let controller = PetTravelBubbleController(locator: StubBubbleLocator(selection: mascotSelection()).locate, scheduler: scheduler)
        defer { controller.close() }
        var taps = 0
        XCTAssertTrue(controller.show(delivery: .prompt(postcardPrompt()), onTap: { taps += 1 }, onAvailableForReplacement: {}))
        scheduler.advance(by: 8)
        let panel = try XCTUnwrap(controller.window as? PetTravelBubblePanel)
        XCTAssertNotNil(panel.onClick)
        for point in [CGPoint(x: 1, y: 1), CGPoint(x: 33, y: 32)] {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                panel.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
            }
            XCTAssertEqual(taps, point.x == 1 ? 0 : 1)
        }
    }
    func testPanelRoutesThresholdDragAndCancellationWithoutClick() throws {
        let panel = PetTravelBubblePanel(contentRect: CGRect(x: 100, y: 100, width: 66, height: 64), styleMask: [.nonactivatingPanel], backing: .buffered, defer: false)
        defer { panel.close() }
        var starts = 0
        var completions: [Bool] = []
        var clicks = 0
        panel.onClick = { clicks += 1 }
        panel.onDragStarted = {
            starts += 1
            return { completions.append($0) }
        }
        func mouse(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: y), modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        panel.sendEvent(try mouse(.leftMouseDown, 20, 20))
        panel.sendEvent(try mouse(.leftMouseDragged, 22, 20))
        XCTAssertEqual(starts, 0)
        panel.sendEvent(try mouse(.leftMouseDragged, 40, 30))
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(panel.frame.origin, CGPoint(x: 120, y: 110))
        panel.sendEvent(try mouse(.leftMouseDragged, 30, 25))
        XCTAssertEqual(panel.frame.origin, CGPoint(x: 130, y: 115))
        XCTAssertTrue(completions.isEmpty)
        panel.sendEvent(try mouse(.leftMouseUp, 20, 20))
        XCTAssertEqual(completions, [true])
        panel.sendEvent(try mouse(.leftMouseDown, 20, 20))
        panel.sendEvent(try mouse(.leftMouseDragged, 40, 30))
        panel.orderOut(nil)
        XCTAssertEqual(completions, [true, false])
        XCTAssertEqual(clicks, 0)
        panel.sendEvent(try mouse(.leftMouseUp, 20, 20))
        XCTAssertEqual(completions, [true, false])
    }
    func testCompanionDragPersistsOffsetSuspendsTimersAndFollowsWithoutSnapback() throws {
        let suite = "DragOffset-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let scheduler = ManualBubbleScheduler()
        let locator = StubBubbleLocator(selection: mascotSelection())
        let controller = PetTravelBubbleController(locator: locator.locate, scheduler: scheduler,
            collapseAnimator: nil, offsetStore: PetCompanionOffsetStore(defaults: defaults),
            screenFrames: { [CGRect(x: -1200, y: 0, width: 2400, height: 900)] })
        defer { controller.close() }
        var taps = 0
        XCTAssertTrue(controller.show(delivery: .prompt(postcardPrompt()), onTap: { taps += 1 }, onAvailableForReplacement: {}))
        let panel = try XCTUnwrap(controller.window as? PetTravelBubblePanel)
        let oldTokens = scheduler.activeTokens
        let end = try XCTUnwrap(panel.onDragStarted?())
        panel.setFrameOrigin(CGPoint(x: -500, y: 200))
        scheduler.advance(by: 10)
        controller.performTap()
        XCTAssertEqual(taps, 0)
        XCTAssertEqual(controller.presentation, .slip)
        end(true)
        for token in oldTokens { scheduler.fireEvenIfCancelled(token) }
        XCTAssertEqual(controller.presentation, .slip)
        XCTAssertEqual(scheduler.activeCount, 2)
        let offset = try XCTUnwrap(PetCompanionOffsetStore(defaults: defaults).load())
        let dragged = panel.frame
        scheduler.advance(by: 0.25)
        XCTAssertEqual(panel.frame, dragged)
        locator.selection = mascotSelection(anchor: CGRect(x: 740, y: 400, width: 120, height: 120))
        scheduler.advance(by: 0.25)
        XCTAssertEqual(panel.frame, dragged.offsetBy(dx: 40, dy: -20))
        scheduler.advance(by: 8)
        XCTAssertEqual(controller.presentation, .paw)
        XCTAssertEqual(panel.frame.midX, dragged.midX + 40)
        XCTAssertEqual(panel.frame.midY, dragged.midY - 20)
        XCTAssertEqual(PetCompanionOffsetStore(defaults: defaults).load(), offset)
        let staleEnd = try XCTUnwrap(panel.onDragStarted?())
        controller.dismissPresentation()
        staleEnd(true)
        XCTAssertEqual(controller.presentation, .hidden)
        XCTAssertEqual(scheduler.activeCount, 0)
        XCTAssertEqual(PetCompanionOffsetStore(defaults: defaults).load(), offset)
    }
    func testJourneySlipAllowsReplacementAfterTwoSecondsWithoutChangingProductionDelay() {
        for isTest in [true, false] {
            let scheduler = ManualBubbleScheduler()
            let controller = PetTravelBubbleController(
                locator: StubBubbleLocator(selection: mascotSelection()).locate, scheduler: scheduler)
            var replacements = 0
            XCTAssertTrue(controller.show(delivery: .prompt(postcardPrompt()), isTestJourney: isTest,
                onTap: {}, onAvailableForReplacement: { replacements += 1 }))
            scheduler.advance(by: 2)
            XCTAssertEqual(replacements, isTest ? 1 : 0)
            XCTAssertEqual(controller.presentation, isTest ? .paw : .slip)
            if !isTest {
                scheduler.advance(by: 6)
                XCTAssertEqual(replacements, 1)
            }
            controller.close()
        }
    }

    func testSlipAndPawFollowOwnedWindowAndHideWithIt() throws {
        let suite = "OwnedPaperAnchor-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pet = DesktopPetController(content: AnyView(Color.red), defaults: defaults)
        defer { pet.windowController.close() }
        XCTAssertNil(DesktopPetAnchorProvider.current(controller: nil))
        XCTAssertNil(DesktopPetAnchorProvider.current(controller: pet))
        pet.show()
        let petWindow = try XCTUnwrap(pet.windowController.window)
        let screen = try XCTUnwrap(petWindow.screen).visibleFrame
        petWindow.setFrameOrigin(CGPoint(x: screen.midX, y: screen.midY - 140))
        let scheduler = ManualBubbleScheduler()
        let controller = PetTravelBubbleController(locator: {
            DesktopPetAnchorProvider.current(controller: pet)
        }, scheduler: scheduler)
        defer { controller.close() }
        XCTAssertTrue(controller.show(delivery: .prompt(postcardPrompt()), onTap: {}, onAvailableForReplacement: {}))
        let panel = try XCTUnwrap(controller.window)
        let initialFrame = panel.frame
        petWindow.setFrameOrigin(CGPoint(x: screen.midX - 100, y: screen.midY - 100))
        scheduler.advance(by: 0.25)
        XCTAssertNotEqual(panel.frame, initialFrame)
        XCTAssertEqual(panel.frame, try XCTUnwrap(PetCompanionLayout.place(
            anchor: petWindow.frame, companionSize: PetTravelBubbleController.slipSize,
            visibleFrame: screen)).frame)
        scheduler.advance(by: 8)
        XCTAssertEqual(controller.presentation, .paw)
        XCTAssertEqual(panel.frame.midX, initialFrame.midX - 100)
        XCTAssertEqual(panel.frame.midY, initialFrame.midY + 40)
        pet.hide()
        scheduler.advance(by: 0.25)
        XCTAssertFalse(panel.isVisible)
        XCTAssertNil(DesktopPetAnchorProvider.current(controller: pet))
        pet.show()
        XCTAssertTrue(controller.show(delivery: .prompt(postcardPrompt()), onTap: {}, onAvailableForReplacement: {}))
    }

    func testBubbleTestActionRequiresBothFastModeAndCallback() {
        XCTAssertFalse(PetTravelBubbleController.shouldIncludeTestAction(
            testActionsEnabled: false,
            hasCallback: true
        ))
        XCTAssertFalse(PetTravelBubbleController.shouldIncludeTestAction(
            testActionsEnabled: true,
            hasCallback: false
        ))
        XCTAssertTrue(PetTravelBubbleController.shouldIncludeTestAction(
            testActionsEnabled: true,
            hasCallback: true
        ))
    }

    func testContentMapsEveryTypedDeliveryAndUsesTravelUILocationResolution() {
        let eventID = UUID()
        let tripID = UUID()
        let aliasedLocation = Location(
            country: "Japan",
            city: "Otsu",
            place: "Otsu Port old pier"
        )

        XCTAssertEqual(
            PetTravelBubbleContent(
                delivery: .prompt(
                    .departed(
                        eventID: eventID,
                        tripID: tripID,
                        location: aliasedLocation,
                        summary: "背上小包，沿湖出发。"
                    )
                )
            ),
            PetTravelBubbleContent(
                eyebrow: "准备出发",
                title: "下一站 · 大津港旧栈桥",
                message: "背上小包，沿湖出发。"
            )
        )
        XCTAssertEqual(
            PetTravelBubbleContent(
                delivery: .prompt(
                    .postcardReady(
                        eventID: eventID,
                        tripID: tripID,
                        location: aliasedLocation,
                        mood: "惬意",
                        quote: "湖风把云吹得很慢。"
                    )
                )
            ),
            PetTravelBubbleContent(
                eyebrow: "明信片到了",
                title: "来自 大津港旧栈桥",
                message: "惬意 · 湖风把云吹得很慢。"
            )
        )
        XCTAssertEqual(
            PetTravelBubbleContent(
                delivery: .prompt(
                    .postcardReady(
                        eventID: eventID,
                        tripID: tripID,
                        location: nil,
                        mood: "",
                        quote: "在路上想你。"
                    )
                )
            ),
            PetTravelBubbleContent(
                eyebrow: "明信片到了",
                title: "来自旅途中",
                message: "在路上想你。"
            )
        )
        XCTAssertEqual(
            PetTravelBubbleContent(
                delivery: .prompt(.returned(eventID: eventID, tripID: tripID, mood: "满足"))
            ),
            PetTravelBubbleContent(
                eyebrow: "旅行归来",
                title: "我回家啦",
                message: "现在的心情：满足"
            )
        )
        XCTAssertEqual(
            PetTravelBubbleContent(
                delivery: .prompt(.returned(eventID: eventID, tripID: tripID, mood: ""))
            ),
            PetTravelBubbleContent(
                eyebrow: "旅行归来",
                title: "我回家啦",
                message: "这次也平安到家。"
            )
        )
        XCTAssertEqual(
            PetTravelBubbleContent(delivery: .summary(promptIDs: ["a", "b", "c"], count: 3)),
            PetTravelBubbleContent(
                eyebrow: "旅行动态",
                title: "黑猫带回了 3 条消息",
                message: "点开看看这段时间的旅程。"
            )
        )
        XCTAssertEqual(
            PetTravelBubbleContent(
                delivery: .prompt(
                    .departed(
                        eventID: eventID,
                        tripID: tripID,
                        location: nil,
                        summary: "出发。"
                    )
                )
            ).title,
            "新的旅程"
        )
    }

    func testPointerDirectionMapsEveryPlacementEdgeTowardTheMascot() {
        XCTAssertEqual(PetTravelBubblePointer.direction(for: .bottomTrailing), .trailing)
        XCTAssertEqual(PetTravelBubblePointer.direction(for: .trailing), .trailing)
        XCTAssertEqual(PetTravelBubblePointer.direction(for: .bottomLeading), .leading)
        XCTAssertEqual(PetTravelBubblePointer.direction(for: .leading), .leading)
    }

    func testSuccessfulShowCreatesExactReusableNonactivatingPanelAndPlacement() throws {
        let selection = mascotSelection()
        let locator = StubBubbleLocator(selection: selection)
        let scheduler = ManualBubbleScheduler()
        let controller = PetTravelBubbleController(locator: locator.locate, scheduler: scheduler)

        XCTAssertTrue(
            controller.show(
                delivery: .prompt(postcardPrompt()),
                onTap: {},
                onAvailableForReplacement: {}
            )
        )

        let window = try XCTUnwrap(controller.window)
        let expectedPlacement = try XCTUnwrap(
            PetCompanionLayout.place(
                anchor: selection.appKitBounds,
                companionSize: PetTravelBubbleController.slipSize,
                visibleFrame: selection.screenFrame
            )
        )
        XCTAssertEqual(window.frame, expectedPlacement.frame)
        XCTAssertEqual(window.contentView?.frame.size, PetTravelBubbleController.slipSize)
        XCTAssertTrue(window.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(window.styleMask.contains(.titled))
        XCTAssertFalse(window.styleMask.contains(.closable))
        XCTAssertTrue((window as? NSPanel)?.isFloatingPanel == true)
        XCTAssertEqual(window.level, .floating)
        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(window.backgroundColor, .clear)
        XCTAssertFalse(window.hasShadow)
        XCTAssertFalse(window.canBecomeKey)
        XCTAssertFalse(window.canBecomeMain)
        XCTAssertTrue(window.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertFalse(window.isReleasedWhenClosed)
        XCTAssertTrue(window.contentView is NSHostingView<AnyView>)
        XCTAssertEqual(controller.presentation, .slip)
        XCTAssertEqual(locator.locateCount, 1)
        XCTAssertEqual(scheduler.activeDelays.sorted(), [0.25, 8])

        let firstWindow = window
        XCTAssertTrue(
            controller.show(
                delivery: .prompt(returnPrompt()),
                onTap: {},
                onAvailableForReplacement: {}
            )
        )
        XCTAssertTrue(controller.window === firstWindow)
        XCTAssertEqual(controller.presentation, .slip)
    }

    func testUnavailableOrUnplaceableShowReturnsFalseWithoutAnySideEffect() {
        let scheduler = ManualBubbleScheduler()
        let locator = StubBubbleLocator(selection: nil)
        let controller = PetTravelBubbleController(locator: locator.locate, scheduler: scheduler)
        var taps = 0
        var replacements = 0

        XCTAssertFalse(
            controller.show(
                delivery: .prompt(postcardPrompt()),
                onTap: { taps += 1 },
                onAvailableForReplacement: { replacements += 1 }
            )
        )
        XCTAssertNil(controller.window)
        XCTAssertEqual(controller.presentation, .hidden)
        XCTAssertEqual(scheduler.activeCount, 0)
        XCTAssertEqual(taps, 0)
        XCTAssertEqual(replacements, 0)

        locator.selection = mascotSelection(
            anchor: CGRect(x: 10, y: 10, width: 80, height: 80),
            visibleFrame: CGRect(x: 0, y: 0, width: 120, height: 120)
        )
        XCTAssertFalse(
            controller.show(
                delivery: .prompt(postcardPrompt()),
                onTap: { taps += 1 },
                onAvailableForReplacement: { replacements += 1 }
            )
        )
        XCTAssertNil(controller.window)
        XCTAssertEqual(controller.presentation, .hidden)
        XCTAssertEqual(scheduler.activeCount, 0)
        XCTAssertEqual(taps, 0)
        XCTAssertEqual(replacements, 0)
    }

    func testFailedReplacementShowLeavesExistingPawAndLifecycleUntouched() throws {
        let scheduler = ManualBubbleScheduler()
        let locator = StubBubbleLocator(selection: mascotSelection())
        let controller = PetTravelBubbleController(locator: locator.locate, scheduler: scheduler)
        var originalTaps = 0

        XCTAssertTrue(
            controller.show(
                delivery: .prompt(postcardPrompt()),
                onTap: { originalTaps += 1 },
                onAvailableForReplacement: {}
            )
        )
        scheduler.advance(by: 8)
        let originalWindow = try XCTUnwrap(controller.window)
        let activeBefore = scheduler.activeCount
        locator.selection = nil

        XCTAssertFalse(
            controller.show(
                delivery: .prompt(returnPrompt()),
                onTap: { XCTFail("failed show installed a new tap") },
                onAvailableForReplacement: { XCTFail("failed show installed a new replacement callback") }
            )
        )
        XCTAssertTrue(controller.window === originalWindow)
        XCTAssertEqual(controller.presentation, .paw)
        XCTAssertEqual(scheduler.activeCount, activeBefore)

        controller.performTap()
        XCTAssertEqual(originalTaps, 1)
    }

    func testSlipCollapsesAtEightSecondsSignalsOnceAndPawPersistsWhileQueueIsEmpty() {
        let scheduler = ManualBubbleScheduler()
        let controller = PetTravelBubbleController(
            locator: StubBubbleLocator(selection: mascotSelection()).locate,
            scheduler: scheduler
        )
        var replacements = 0
        XCTAssertTrue(
            controller.show(
                delivery: .prompt(postcardPrompt()),
                onTap: {},
                onAvailableForReplacement: { replacements += 1 }
            )
        )

        scheduler.advance(by: 7.99)
        XCTAssertEqual(controller.presentation, .slip)
        XCTAssertEqual(replacements, 0)
        scheduler.advance(by: 0.01)
        XCTAssertEqual(controller.presentation, .paw)
        XCTAssertEqual(replacements, 1)
        XCTAssertEqual(scheduler.activeDelays, [0.25])

        scheduler.advance(by: 30)
        XCTAssertEqual(controller.presentation, .paw)
        XCTAssertEqual(replacements, 1)
        XCTAssertEqual(scheduler.activeDelays, [0.25])
    }

    func testAnimatedCollapseStartsAtEightSecondsDisablesHitsThenFinishesInSamePawPanel() throws {
        let scheduler = ManualBubbleScheduler()
        let animator = ManualBubbleCollapseAnimator()
        let selection = mascotSelection()
        let controller = PetTravelBubbleController(
            locator: StubBubbleLocator(selection: selection).locate,
            scheduler: scheduler,
            collapseAnimator: animator
        )
        var replacements = 0
        XCTAssertTrue(controller.show(
            delivery: .prompt(postcardPrompt()),
            onTap: {},
            onAvailableForReplacement: { replacements += 1 }
        ))
        let panel = try XCTUnwrap(controller.window as? PetTravelBubblePanel)

        scheduler.advance(by: 7.99)
        XCTAssertEqual(animator.tokens.count, 0)
        scheduler.advance(by: 0.01)

        XCTAssertEqual(controller.presentation, .collapsing)
        XCTAssertTrue(controller.window === panel)
        XCTAssertEqual(panel.frame.size, PetTravelBubbleController.slipSize)
        XCTAssertEqual(animator.tokens.count, 1)
        XCTAssertEqual(animator.tokens[0].edge, .trailing)
        XCTAssertEqual(replacements, 1)
        let hostingView = try XCTUnwrap(panel.contentView as? PetTravelBubbleHostingView)
        XCTAssertNil(hostingView.hitTest(NSPoint(x: hostingView.bounds.midX, y: hostingView.bounds.midY)))
        panel.updateMousePassthrough(
            atScreenPoint: panel.convertPoint(
                toScreen: NSPoint(x: hostingView.bounds.midX, y: hostingView.bounds.midY)
            )
        )
        XCTAssertTrue(panel.ignoresMouseEvents)

        animator.complete(animator.tokens[0])

        let pawPlacement = try XCTUnwrap(
            PetCompanionLayout.place(
                anchor: selection.appKitBounds,
                companionSize: PetTravelBubbleController.pawSize,
                visibleFrame: selection.screenFrame
            )
        )
        XCTAssertEqual(controller.presentation, .paw)
        XCTAssertTrue(controller.window === panel)
        XCTAssertEqual(panel.frame, pawPlacement.frame.offsetBy(dx: -110, dy: 0))
        XCTAssertEqual(replacements, 1)
        XCTAssertEqual(scheduler.activeDelays, [0.25])
    }

    func testTapDuringAnimatedCollapseCancelsTransitionAndStaleCompletionCannotMutateOrSignal() {
        let scheduler = ManualBubbleScheduler()
        let animator = ManualBubbleCollapseAnimator()
        let controller = PetTravelBubbleController(
            locator: StubBubbleLocator(selection: mascotSelection()).locate,
            scheduler: scheduler,
            collapseAnimator: animator
        )
        var taps = 0
        var replacements = 0
        XCTAssertTrue(controller.show(
            delivery: .prompt(postcardPrompt()),
            onTap: { taps += 1 },
            onAvailableForReplacement: { replacements += 1 }
        ))
        scheduler.advance(by: 8)
        let token = animator.tokens[0]

        controller.performTap()

        XCTAssertTrue(token.isCancelled)
        XCTAssertEqual(controller.presentation, .hidden)
        XCTAssertEqual(taps, 1)
        XCTAssertEqual(replacements, 1)
        animator.completeEvenIfCancelled(token)
        XCTAssertEqual(controller.presentation, .hidden)
        XCTAssertEqual(taps, 1)
        XCTAssertEqual(replacements, 1)
        XCTAssertEqual(scheduler.activeCount, 0)
    }

    func testReplacementCallbackCanReplaceAnimatedCollapseAndStaleCompletionCannotShrinkNewSlip() throws {
        let scheduler = ManualBubbleScheduler()
        let animator = ManualBubbleCollapseAnimator()
        let locator = StubBubbleLocator(selection: mascotSelection())
        let controller = PetTravelBubbleController(
            locator: locator.locate,
            scheduler: scheduler,
            collapseAnimator: animator
        )
        var firstReplacements = 0
        var secondReplacements = 0
        XCTAssertTrue(controller.show(
            delivery: .prompt(postcardPrompt()),
            onTap: {},
            onAvailableForReplacement: {
                firstReplacements += 1
                XCTAssertTrue(controller.show(
                    delivery: .prompt(returnPrompt()),
                    onTap: {},
                    onAvailableForReplacement: { secondReplacements += 1 }
                ))
            }
        ))
        let panel = try XCTUnwrap(controller.window)

        scheduler.advance(by: 8)
        let staleToken = animator.tokens[0]

        XCTAssertTrue(staleToken.isCancelled)
        XCTAssertEqual(controller.presentation, .slip)
        XCTAssertTrue(controller.window === panel)
        XCTAssertEqual(panel.frame.size, PetTravelBubbleController.slipSize)
        XCTAssertEqual(firstReplacements, 1)
        XCTAssertEqual(secondReplacements, 0)
        animator.completeEvenIfCancelled(staleToken)
        XCTAssertEqual(controller.presentation, .slip)
        XCTAssertEqual(panel.frame.size, PetTravelBubbleController.slipSize)
        XCTAssertEqual(firstReplacements, 1)
        XCTAssertEqual(secondReplacements, 0)
    }

    func testRuntimeCollapseGeometryScalesTowardPetWithoutGrowingTheSlip() {
        let bounds = NSRect(origin: .zero, size: PetTravelBubbleController.slipSize)
        XCTAssertEqual(AppKitBubbleCollapseAnimator.duration, 0.18)

        for edge in [
            PetCompanionEdge.bottomTrailing,
            .bottomLeading,
            .trailing,
            .leading,
        ] {
            let frame = PetTravelBubbleCollapseGeometry.scaledFrame(in: bounds, toward: edge)
            XCTAssertLessThan(frame.width, bounds.width)
            XCTAssertLessThan(frame.height, bounds.height)
            XCTAssertTrue(bounds.contains(frame))
            switch edge {
            case .bottomTrailing:
                XCTAssertEqual(frame.maxX, bounds.maxX, accuracy: 0.001)
                XCTAssertEqual(frame.minY, bounds.minY, accuracy: 0.001)
            case .bottomLeading:
                XCTAssertEqual(frame.minX, bounds.minX, accuracy: 0.001)
                XCTAssertEqual(frame.minY, bounds.minY, accuracy: 0.001)
            case .trailing:
                XCTAssertEqual(frame.maxX, bounds.maxX, accuracy: 0.001)
                XCTAssertEqual(frame.midY, bounds.midY, accuracy: 0.001)
            case .leading:
                XCTAssertEqual(frame.minX, bounds.minX, accuracy: 0.001)
                XCTAssertEqual(frame.midY, bounds.midY, accuracy: 0.001)
            }
        }
    }

    func testCollapseShrinksToPawHitAreaAndNextSlipRestoresSizeInSamePanel() throws {
        let scheduler = ManualBubbleScheduler()
        let selection = mascotSelection()
        let locator = StubBubbleLocator(selection: selection)
        let controller = PetTravelBubbleController(locator: locator.locate, scheduler: scheduler)
        XCTAssertTrue(
            controller.show(
                delivery: .prompt(postcardPrompt()),
                onTap: {},
                onAvailableForReplacement: {}
            )
        )
        let panel = try XCTUnwrap(controller.window)
        XCTAssertEqual(panel.frame.size, PetTravelBubbleController.slipSize)

        scheduler.advance(by: 8)

        let pawPlacement = try XCTUnwrap(
            PetCompanionLayout.place(
                anchor: selection.appKitBounds,
                companionSize: PetTravelBubbleController.pawSize,
                visibleFrame: selection.screenFrame
            )
        )
        XCTAssertTrue(controller.window === panel)
        XCTAssertEqual(controller.presentation, .paw)
        XCTAssertEqual(panel.frame, pawPlacement.frame.offsetBy(dx: -110, dy: 0))
        XCTAssertEqual(panel.frame.size, NSSize(width: 66, height: 64))
        XCTAssertEqual(panel.contentView?.frame.size, NSSize(width: 66, height: 64))
        XCTAssertTrue(selection.screenFrame.contains(panel.frame))
        XCTAssertFalse(panel.frame.intersects(selection.appKitBounds))

        XCTAssertTrue(
            controller.show(
                delivery: .prompt(returnPrompt()),
                onTap: {},
                onAvailableForReplacement: {}
            )
        )
        let slipPlacement = try XCTUnwrap(
            PetCompanionLayout.place(
                anchor: selection.appKitBounds,
                companionSize: PetTravelBubbleController.slipSize,
                visibleFrame: selection.screenFrame
            )
        )
        XCTAssertTrue(controller.window === panel)
        XCTAssertEqual(controller.presentation, .slip)
        XCTAssertEqual(panel.frame, slipPlacement.frame)
        XCTAssertEqual(panel.frame.size, NSSize(width: 286, height: 138))
        XCTAssertEqual(panel.contentView?.frame.size, NSSize(width: 286, height: 138))
    }

    func testCollapsedPawHitTestRejectsTransparentCornerAndAcceptsPawCenter() throws {
        let scheduler = ManualBubbleScheduler()
        let controller = PetTravelBubbleController(
            locator: StubBubbleLocator(selection: mascotSelection()).locate,
            scheduler: scheduler
        )
        XCTAssertTrue(
            controller.show(
                delivery: .prompt(postcardPrompt()),
                onTap: {},
                onAvailableForReplacement: {}
            )
        )
        scheduler.advance(by: 8)

        let panel = try XCTUnwrap(controller.window as? PetTravelBubblePanel)
        let hostingView = try XCTUnwrap(panel.contentView as? PetTravelBubbleHostingView)
        XCTAssertNil(hostingView.hitTest(NSPoint(x: 1, y: 1)))
        XCTAssertNil(hostingView.hitTest(NSPoint(x: 65, y: 63)))
        XCTAssertNotNil(hostingView.hitTest(NSPoint(x: 33, y: 32)))

        panel.updateMousePassthrough(
            atScreenPoint: panel.convertPoint(toScreen: NSPoint(x: 1, y: 1))
        )
        XCTAssertTrue(panel.ignoresMouseEvents)
        panel.updateMousePassthrough(
            atScreenPoint: panel.convertPoint(toScreen: NSPoint(x: 33, y: 32))
        )
        XCTAssertFalse(panel.ignoresMouseEvents)
    }

    func testTapBeforeCollapseRoutesOnceHidesCancelsTimersAndSignalsOnce() {
        let scheduler = ManualBubbleScheduler()
        let controller = PetTravelBubbleController(
            locator: StubBubbleLocator(selection: mascotSelection()).locate,
            scheduler: scheduler
        )
        var taps = 0
        var replacements = 0
        XCTAssertTrue(
            controller.show(
                delivery: .prompt(postcardPrompt()),
                onTap: { taps += 1 },
                onAvailableForReplacement: { replacements += 1 }
            )
        )

        controller.performTap()
        controller.performTap()
        scheduler.advance(by: 30)

        XCTAssertEqual(taps, 1)
        XCTAssertEqual(replacements, 1)
        XCTAssertEqual(controller.presentation, .hidden)
        XCTAssertFalse(controller.window?.isVisible == true)
        XCTAssertEqual(scheduler.activeCount, 0)
    }

    func testTapAfterCollapseDoesNotDoubleSignalReplacement() {
        let scheduler = ManualBubbleScheduler()
        let controller = PetTravelBubbleController(
            locator: StubBubbleLocator(selection: mascotSelection()).locate,
            scheduler: scheduler
        )
        var taps = 0
        var replacements = 0
        XCTAssertTrue(
            controller.show(
                delivery: .prompt(postcardPrompt()),
                onTap: { taps += 1 },
                onAvailableForReplacement: { replacements += 1 }
            )
        )

        scheduler.advance(by: 8)
        controller.performTap()
        scheduler.advance(by: 8)

        XCTAssertEqual(taps, 1)
        XCTAssertEqual(replacements, 1)
        XCTAssertEqual(controller.presentation, .hidden)
        XCTAssertEqual(scheduler.activeCount, 0)
    }

    func testDisablingFollowHidesActiveSlipAndReleasesReplacementExactlyOnce() {
        let scheduler = ManualBubbleScheduler()
        let controller = PetTravelBubbleController(
            locator: StubBubbleLocator(selection: mascotSelection()).locate,
            scheduler: scheduler
        )
        var taps = 0
        var replacements = 0
        XCTAssertTrue(controller.show(
            delivery: .prompt(postcardPrompt()),
            onTap: { taps += 1 },
            onAvailableForReplacement: { replacements += 1 }
        ))

        controller.settingsDidChange(followCodexPet: false)
        controller.settingsDidChange(followCodexPet: false)
        scheduler.advance(by: 30)

        XCTAssertEqual(controller.presentation, .hidden)
        XCTAssertFalse(controller.window?.isVisible == true)
        XCTAssertEqual(taps, 0)
        XCTAssertEqual(replacements, 1)
        XCTAssertEqual(scheduler.activeCount, 0)
    }

    func testDisablingFollowHidesReleasedPawWithoutRepeatingReplacement() {
        let scheduler = ManualBubbleScheduler()
        let controller = PetTravelBubbleController(
            locator: StubBubbleLocator(selection: mascotSelection()).locate,
            scheduler: scheduler
        )
        var replacements = 0
        XCTAssertTrue(controller.show(
            delivery: .prompt(postcardPrompt()),
            onTap: {},
            onAvailableForReplacement: { replacements += 1 }
        ))
        scheduler.advance(by: 8)
        XCTAssertEqual(controller.presentation, .paw)
        XCTAssertEqual(replacements, 1)

        controller.settingsDidChange(followCodexPet: false)
        scheduler.advance(by: 30)

        XCTAssertEqual(controller.presentation, .hidden)
        XCTAssertFalse(controller.window?.isVisible == true)
        XCTAssertEqual(replacements, 1)
        XCTAssertEqual(scheduler.activeCount, 0)
    }

    func testCollapseReplacementCallbackCanReentrantlyShowNextPromptInSamePanel() throws {
        let scheduler = ManualBubbleScheduler()
        let locator = StubBubbleLocator(selection: mascotSelection())
        let controller = PetTravelBubbleController(locator: locator.locate, scheduler: scheduler)
        var firstReplacementCount = 0
        var secondReplacementCount = 0
        XCTAssertTrue(
            controller.show(
                delivery: .prompt(postcardPrompt()),
                onTap: { XCTFail("first prompt was tapped") },
                onAvailableForReplacement: {
                    firstReplacementCount += 1
                    XCTAssertTrue(
                        controller.show(
                            delivery: .prompt(returnPrompt()),
                            onTap: {},
                            onAvailableForReplacement: { secondReplacementCount += 1 }
                        )
                    )
                }
            )
        )
        let firstWindow = try XCTUnwrap(controller.window)

        scheduler.advance(by: 8)

        XCTAssertEqual(firstReplacementCount, 1)
        XCTAssertEqual(secondReplacementCount, 0)
        XCTAssertEqual(controller.presentation, .slip)
        XCTAssertTrue(controller.window === firstWindow)
        XCTAssertEqual(scheduler.activeDelays.sorted(), [0.25, 8])
    }

    func testNewShowCancelsOldTimersAndStaleCallbacksCannotMutateOrSignal() {
        let scheduler = ManualBubbleScheduler()
        let controller = PetTravelBubbleController(
            locator: StubBubbleLocator(selection: mascotSelection()).locate,
            scheduler: scheduler
        )
        var oldTaps = 0
        var oldReplacements = 0
        var newTaps = 0
        var newReplacements = 0
        XCTAssertTrue(
            controller.show(
                delivery: .prompt(postcardPrompt()),
                onTap: { oldTaps += 1 },
                onAvailableForReplacement: { oldReplacements += 1 }
            )
        )
        let oldTokens = scheduler.activeTokens

        XCTAssertTrue(
            controller.show(
                delivery: .prompt(returnPrompt()),
                onTap: { newTaps += 1 },
                onAvailableForReplacement: { newReplacements += 1 }
            )
        )
        XCTAssertTrue(oldTokens.allSatisfy(\.isCancelled))
        oldTokens.forEach { scheduler.fireEvenIfCancelled($0) }

        XCTAssertEqual(controller.presentation, .slip)
        XCTAssertEqual(oldTaps, 0)
        XCTAssertEqual(oldReplacements, 0)
        XCTAssertEqual(newTaps, 0)
        XCTAssertEqual(newReplacements, 0)

        controller.performTap()
        XCTAssertEqual(newTaps, 1)
        XCTAssertEqual(newReplacements, 1)
        XCTAssertEqual(oldTaps, 0)
        XCTAssertEqual(oldReplacements, 0)
    }

    func testFollowRunsAtFourHertzMovesOnlyForChangedPlacementAndStopsWhenHidden() throws {
        let scheduler = ManualBubbleScheduler()
        let locator = StubBubbleLocator(selection: mascotSelection())
        let controller = PetTravelBubbleController(locator: locator.locate, scheduler: scheduler)
        XCTAssertTrue(
            controller.show(
                delivery: .prompt(postcardPrompt()),
                onTap: {},
                onAvailableForReplacement: {}
            )
        )
        let initialFrame = try XCTUnwrap(controller.window?.frame)
        let initialUpdates = controller.frameUpdateCount

        scheduler.advance(by: 0.25)
        XCTAssertEqual(locator.locateCount, 2)
        XCTAssertEqual(controller.frameUpdateCount, initialUpdates)
        XCTAssertEqual(controller.window?.frame, initialFrame)

        locator.selection = mascotSelection(
            anchor: CGRect(x: 540, y: 360, width: 120, height: 120),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_200, height: 900)
        )
        scheduler.advance(by: 0.25)
        XCTAssertNotEqual(controller.window?.frame, initialFrame)
        XCTAssertEqual(controller.frameUpdateCount, initialUpdates + 1)

        controller.performTap()
        let locateCountWhenHidden = locator.locateCount
        scheduler.advance(by: 5)
        XCTAssertEqual(locator.locateCount, locateCountWhenHidden)
        XCTAssertEqual(scheduler.activeCount, 0)
    }

    func testSlipFollowRetainsInitialSideInTheSamePanel() throws {
        let scheduler = ManualBubbleScheduler()
        let locator = StubBubbleLocator(selection: mascotSelection())
        let controller = PetTravelBubbleController(locator: locator.locate, scheduler: scheduler)
        XCTAssertTrue(
            controller.show(
                delivery: .prompt(postcardPrompt()),
                onTap: {},
                onAvailableForReplacement: {}
            )
        )
        let panel = try XCTUnwrap(controller.window)
        let initialInstallCount = controller.rootViewInstallCount
        XCTAssertEqual(controller.renderedEdge, .trailing)

        locator.selection = mascotSelection(
            anchor: CGRect(x: 100, y: 420, width: 120, height: 120),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_200, height: 900)
        )
        scheduler.advance(by: 0.25)

        XCTAssertTrue(controller.window === panel)
        XCTAssertEqual(controller.presentation, .slip)
        XCTAssertEqual(controller.renderedEdge, .trailing)
        XCTAssertEqual(controller.rootViewInstallCount, initialInstallCount)
    }

    func testPawFollowRecoversAtDisplayEdgeWithoutChangingRememberedSide() throws {
        let scheduler = ManualBubbleScheduler()
        let locator = StubBubbleLocator(selection: mascotSelection())
        let controller = PetTravelBubbleController(locator: locator.locate, scheduler: scheduler)
        XCTAssertTrue(
            controller.show(
                delivery: .prompt(postcardPrompt()),
                onTap: {},
                onAvailableForReplacement: {}
            )
        )
        scheduler.advance(by: 8)
        let panel = try XCTUnwrap(controller.window)
        let collapsedInstallCount = controller.rootViewInstallCount
        XCTAssertEqual(controller.presentation, .paw)
        XCTAssertEqual(controller.renderedEdge, .trailing)

        let movedSelection = mascotSelection(
            anchor: CGRect(x: 60, y: 420, width: 120, height: 120),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_200, height: 900)
        )
        locator.selection = movedSelection
        scheduler.advance(by: 0.25)

        XCTAssertTrue(controller.window === panel)
        XCTAssertEqual(controller.presentation, .paw)
        XCTAssertEqual(controller.renderedEdge, .trailing)
        XCTAssertEqual(controller.rootViewInstallCount, collapsedInstallCount)
        XCTAssertEqual(panel.frame, CGRect(x: 0, y: 448, width: 66, height: 64))
        XCTAssertTrue(movedSelection.screenFrame.contains(panel.frame))
    }

    func testFollowContinuesForPawAndFailsClosedWhenMascotBecomesUnavailable() {
        let scheduler = ManualBubbleScheduler()
        let locator = StubBubbleLocator(selection: mascotSelection())
        let controller = PetTravelBubbleController(locator: locator.locate, scheduler: scheduler)
        var replacements = 0
        XCTAssertTrue(
            controller.show(
                delivery: .prompt(postcardPrompt()),
                onTap: {},
                onAvailableForReplacement: { replacements += 1 }
            )
        )
        scheduler.advance(by: 8)
        XCTAssertEqual(controller.presentation, .paw)
        XCTAssertEqual(replacements, 1)

        let countBeforePawFollow = locator.locateCount
        scheduler.advance(by: 0.25)
        XCTAssertEqual(locator.locateCount, countBeforePawFollow + 1)

        locator.selection = nil
        scheduler.advance(by: 0.25)
        XCTAssertEqual(controller.presentation, .hidden)
        XCTAssertFalse(controller.window?.isVisible == true)
        XCTAssertEqual(replacements, 1)
        XCTAssertEqual(scheduler.activeCount, 0)
    }

    func testFollowPlacementFailureBeforeCollapseFailsClosedAndSignalsReplacementOnce() {
        let scheduler = ManualBubbleScheduler()
        let locator = StubBubbleLocator(selection: mascotSelection())
        let controller = PetTravelBubbleController(locator: locator.locate, scheduler: scheduler)
        var replacements = 0
        XCTAssertTrue(
            controller.show(
                delivery: .prompt(postcardPrompt()),
                onTap: {},
                onAvailableForReplacement: { replacements += 1 }
            )
        )
        locator.selection = mascotSelection(
            anchor: CGRect(x: 0, y: 0, width: 40, height: 40),
            visibleFrame: CGRect(x: 0, y: 0, width: 100, height: 100)
        )

        scheduler.advance(by: 0.25)
        scheduler.advance(by: 20)

        XCTAssertEqual(controller.presentation, .hidden)
        XCTAssertEqual(replacements, 1)
        XCTAssertEqual(scheduler.activeCount, 0)
    }
}

@MainActor
private final class StubBubbleLocator {
    var selection: PetCompanionAnchor?
    private(set) var locateCount = 0

    init(selection: PetCompanionAnchor?) {
        self.selection = selection
    }

    func locate() -> PetCompanionAnchor? {
        locateCount += 1
        return selection
    }
}

@MainActor
private final class ManualBubbleScheduler: BubbleScheduling {
    final class Token: BubbleCancellation {
        let deadline: TimeInterval
        let delay: TimeInterval
        let sequence: Int
        let action: @MainActor () -> Void
        private(set) var isCancelled = false

        init(
            deadline: TimeInterval,
            delay: TimeInterval,
            sequence: Int,
            action: @escaping @MainActor () -> Void
        ) {
            self.deadline = deadline
            self.delay = delay
            self.sequence = sequence
            self.action = action
        }

        func cancel() {
            isCancelled = true
        }
    }

    private var now: TimeInterval = 0
    private var nextSequence = 0
    private var tokens: [Token] = []

    var activeTokens: [Token] {
        tokens.filter { !$0.isCancelled && $0.deadline >= now }
    }

    var activeCount: Int { activeTokens.count }
    var activeDelays: [TimeInterval] { activeTokens.map(\.delay) }

    func after(
        _ seconds: TimeInterval,
        _ action: @escaping @MainActor () -> Void
    ) -> BubbleCancellation {
        let token = Token(
            deadline: now + seconds,
            delay: seconds,
            sequence: nextSequence,
            action: action
        )
        nextSequence += 1
        tokens.append(token)
        return token
    }

    func advance(by interval: TimeInterval) {
        let target = now + interval
        while let next = tokens
            .filter({ !$0.isCancelled && $0.deadline <= target })
            .min(by: {
                $0.deadline == $1.deadline
                    ? $0.sequence < $1.sequence
                    : $0.deadline < $1.deadline
            }) {
            now = next.deadline
            next.cancel()
            next.action()
        }
        now = target
    }

    func fireEvenIfCancelled(_ token: Token) {
        token.action()
    }
}

@MainActor
private final class ManualBubbleCollapseAnimator: BubbleCollapseAnimating {
    final class Token: BubbleCancellation {
        let edge: PetCompanionEdge
        let completion: @MainActor () -> Void
        private(set) var isCancelled = false

        init(edge: PetCompanionEdge, completion: @escaping @MainActor () -> Void) {
            self.edge = edge
            self.completion = completion
        }

        func cancel() {
            isCancelled = true
        }
    }

    private(set) var tokens: [Token] = []

    func animateSlip(
        _ view: NSView,
        toward edge: PetCompanionEdge,
        completion: @escaping @MainActor () -> Void
    ) -> BubbleCancellation {
        let token = Token(edge: edge, completion: completion)
        tokens.append(token)
        return token
    }

    func complete(_ token: Token) {
        guard !token.isCancelled else { return }
        token.cancel()
        token.completion()
    }

    func completeEvenIfCancelled(_ token: Token) {
        token.completion()
    }
}

private func mascotSelection(
    anchor: CGRect = CGRect(x: 700, y: 420, width: 120, height: 120),
    visibleFrame: CGRect = CGRect(x: 0, y: 0, width: 1_200, height: 900)
) -> PetCompanionAnchor {
    PetCompanionAnchor(
        appKitBounds: anchor,
        screenFrame: visibleFrame
    )
}

private func postcardPrompt() -> PetTravelPrompt {
    .postcardReady(
        eventID: UUID(),
        tripID: UUID(),
        location: Location(country: "中国", city: "杭州", place: "西湖"),
        mood: "开心",
        quote: "给你寄来一阵湖风。"
    )
}

private func returnPrompt() -> PetTravelPrompt {
    .returned(eventID: UUID(), tripID: UUID(), mood: "满足")
}
