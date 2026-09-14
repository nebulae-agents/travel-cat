import AppKit
import SwiftUI
import XCTest
@testable import TravelUI

@MainActor
final class PetWindowControllerTests: XCTestCase {
    func testPetWindowHasExactNonactivatingTransparentFloatingPolicy() {
        let window = PetWindowController.makeWindow(content: AnyView(EmptyView()))

        XCTAssertEqual(ObjectIdentifier(type(of: window)), ObjectIdentifier(PetPanel.self))
        XCTAssertEqual(window.frame.size, CGSize(width: 240, height: 280))
        XCTAssertTrue(window.styleMask.contains(.borderless))
        XCTAssertTrue(window.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(window.backgroundColor, .clear)
        XCTAssertFalse(window.hasShadow)
        XCTAssertEqual(window.level, .floating)
        XCTAssertTrue(window.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(window.collectionBehavior.contains(.stationary))
        XCTAssertTrue(window.collectionBehavior.contains(.ignoresCycle))
        XCTAssertFalse(window.hidesOnDeactivate)
        XCTAssertFalse(window.ignoresMouseEvents)
        XCTAssertTrue(window.isMovableByWindowBackground)
        XCTAssertTrue(window.contentView is NSHostingView<AnyView>)
        XCTAssertEqual(window.contentView?.layer?.backgroundColor, NSColor.clear.cgColor)
        XCTAssertTrue(window.canBecomeKey)
        XCTAssertTrue((window.contentView as? TransparentHostingView)?.sizingOptions.isEmpty == true)
    }

    func testTransparentHostingViewPassesThroughClearPixelsButKeepsVisibleContentInteractive() throws {
        let content = AnyView(
            ZStack {
                Color.clear
                Rectangle().fill(.red).frame(width: 80, height: 80)
            }.frame(width: 240, height: 280)
        )
        let window = PetWindowController.makeWindow(content: content)
        let view = try XCTUnwrap(window.contentView)
        view.frame = CGRect(x: 0, y: 0, width: 240, height: 280)
        view.layoutSubtreeIfNeeded()

        XCTAssertNil(view.hitTest(CGPoint(x: 5, y: 5)))
        XCTAssertNotNil(view.hitTest(CGPoint(x: 120, y: 140)))

        let panel = window
        panel.updateMousePassthrough(atScreenPoint: panel.convertPoint(toScreen: CGPoint(x: 5, y: 5)))
        XCTAssertTrue(panel.ignoresMouseEvents)
        panel.updateMousePassthrough(atScreenPoint: panel.convertPoint(toScreen: CGPoint(x: 120, y: 140)))
        XCTAssertFalse(panel.ignoresMouseEvents)
    }

    func testPositionStoreKeysOriginsByDisplayAndClampsToVisibleFrame() throws {
        let suite = "WindowPositionStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WindowPositionStore(defaults: defaults)
        let size = CGSize(width: 240, height: 280)
        let screen = CGRect(x: 0, y: 0, width: 1_000, height: 800)

        store.save(origin: CGPoint(x: 900, y: 700), displayID: "42")
        XCTAssertEqual(store.lastDisplayIdentifier, "42")
        XCTAssertEqual(
            store.restoredFrame(size: size, displayID: "42", visibleFrames: [screen]),
            CGRect(x: 760, y: 520, width: 240, height: 280)
        )
        XCTAssertNil(store.restoredFrame(size: size, displayID: "other", visibleFrames: [screen]))
    }

    func testClampingMovesLostWindowToNearestVisibleDisplay() {
        let proposed = CGRect(x: 9_000, y: 9_000, width: 240, height: 280)
        let first = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let second = CGRect(x: 1_000, y: 0, width: 1_000, height: 800)

        XCTAssertEqual(
            WindowPositionStore.clamp(proposed, to: [first, second]),
            CGRect(x: 1_760, y: 520, width: 240, height: 280)
        )
    }

    func testPositionStoreRejectsNonfiniteCoordinates() throws {
        let suite = "WindowPositionStoreTests-nonfinite-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WindowPositionStore(defaults: defaults)

        store.save(origin: CGPoint(x: CGFloat.nan, y: CGFloat.infinity), displayID: "bad")

        XCTAssertNil(
            store.restoredFrame(
                size: CGSize(width: 240, height: 280),
                displayID: "bad",
                visibleFrames: [CGRect(x: 0, y: 0, width: 1_000, height: 800)]
            )
        )
    }

    func testStableDisplayIdentifierPrefersUUIDAndHasStableFallback() {
        XCTAssertEqual(
            PetWindowController.stableDisplayIdentifier(
                displayID: 42,
                uuidString: "A1B2-C3D4"
            ),
            "display-uuid.A1B2-C3D4"
        )
        let fallback = PetWindowController.stableDisplayIdentifier(displayID: 42, uuidString: nil)
        XCTAssertEqual(fallback, PetWindowController.stableDisplayIdentifier(displayID: 42, uuidString: ""))
        XCTAssertEqual(fallback, "display-id.42")
        XCTAssertFalse(fallback.isEmpty)
    }

    func testStartupErrorContentUsesStableNativeView() {
        let controller = PetWindowController(content: AnyView(EmptyView()))
        controller.resize(for: .status)
        controller.setStartupErrorContent(message: "broken repository")

        XCTAssertFalse(controller.window?.contentView is NSHostingView<AnyView>)
        XCTAssertEqual(controller.window?.contentView?.accessibilityLabel(), "旅行数据暂时无法读取")
        XCTAssertEqual(controller.window?.contentView?.accessibilityHelp(), "broken repository")
        XCTAssertNil(controller.window?.contentView?.hitTest(CGPoint(x: 2, y: 2)))
        XCTAssertNotNil(controller.window?.contentView?.hitTest(CGPoint(x: 160, y: 180)))
    }
}
