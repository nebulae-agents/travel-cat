import AppKit
import SwiftUI
import XCTest
@testable import TravelCatApp

@MainActor
final class TravelUtilityWindowMinimumTests: XCTestCase {
    func testShowingNearScreenCornerRestoresWholeWindow() throws {
        let controller = TravelUtilityWindowController()
        let window = try XCTUnwrap(controller.window)
        defer { window.orderOut(nil); window.close() }
        let screen = try XCTUnwrap(window.screen ?? NSScreen.main)
        let visible = screen.visibleFrame
        guard visible.width >= 420, visible.height >= window.frame.height else {
            throw XCTSkip("Display cannot contain the status window")
        }
        // Keep the majority on the original display even with adjacent monitors.
        window.setFrameOrigin(NSPoint(x: visible.maxX - window.frame.width + 25, y: visible.minY - 25))
        XCTAssertFalse(visible.contains(window.frame), "The fixture must start partly off screen")

        controller.show(content: AnyView(Text("visible recovery")), size: TravelUtilityWindowController.statusSize)

        XCTAssertGreaterThanOrEqual(window.frame.minX, visible.minX)
        XCTAssertGreaterThanOrEqual(window.frame.minY, visible.minY)
        XCTAssertLessThanOrEqual(window.frame.maxX, visible.maxX)
        XCTAssertLessThanOrEqual(window.frame.maxY, visible.maxY)
        XCTAssertEqual(window.contentView?.frame.size, TravelUtilityWindowController.statusSize)
    }

    func testResizingNearScreenCornerRestoresWholeWindow() throws {
        let controller = TravelUtilityWindowController()
        let window = try XCTUnwrap(controller.window)
        defer { window.orderOut(nil); window.close() }
        let screen = try XCTUnwrap(window.screen ?? NSScreen.main)
        let visible = screen.visibleFrame
        guard visible.width >= 420, visible.height >= window.frame.height else {
            throw XCTSkip("Display cannot contain the status window")
        }
        window.setFrameOrigin(NSPoint(x: visible.maxX - window.frame.width + 25, y: visible.minY - 25))
        XCTAssertFalse(visible.contains(window.frame), "The fixture must start partly off screen")

        controller.resize(to: TravelUtilityWindowController.statusSize)

        XCTAssertGreaterThanOrEqual(window.frame.minX, visible.minX)
        XCTAssertGreaterThanOrEqual(window.frame.minY, visible.minY)
        XCTAssertLessThanOrEqual(window.frame.maxX, visible.maxX)
        XCTAssertLessThanOrEqual(window.frame.maxY, visible.maxY)
        XCTAssertEqual(window.contentView?.frame.size, TravelUtilityWindowController.statusSize)
    }

    func testExternalFrameResizePreservesConfiguredContentMinimum() throws {
        let controller = TravelUtilityWindowController()
        let window = try XCTUnwrap(controller.window)
        defer { window.orderOut(nil); window.close() }
        let screen = try XCTUnwrap(window.screen ?? NSScreen.main)
        let available = window.contentRect(forFrameRect: screen.visibleFrame).size
        controller.show(content: AnyView(Text("custom minimum")), size: NSSize(width: 1000, height: 740),
                        minimumContentSize: NSSize(width: 760, height: 600))
        var frame = window.frame; frame.size = NSSize(width: 75, height: 39)

        window.setFrame(frame, display: false)

        let actual = window.contentRect(forFrameRect: window.frame).size
        XCTAssertGreaterThanOrEqual(actual.width, min(760, available.width))
        XCTAssertGreaterThanOrEqual(actual.height, min(600, available.height))
        XCTAssertEqual(window.contentMinSize, NSSize(width: 760, height: 600))
    }

    func testMinimumRecoveryCannotExceedVisibleScreen() throws {
        let controller = TravelUtilityWindowController()
        let window = try XCTUnwrap(controller.window)
        defer { window.orderOut(nil); window.close() }
        let screen = try XCTUnwrap(window.screen ?? NSScreen.main)
        let available = window.contentRect(forFrameRect: screen.visibleFrame).size
        let configured = NSSize(width: available.width + 100, height: available.height + 100)
        controller.show(content: AnyView(Text("screen-bounded recovery")), size: TravelUtilityWindowController.statusSize,
                        minimumContentSize: configured)
        for _ in 0..<2 {
            window.contentMinSize = .zero
            var frame = window.frame; frame.size = NSSize(width: 75, height: 39)
            window.setFrame(frame, display: false)

            let actual = window.contentRect(forFrameRect: window.frame).size
            XCTAssertEqual(actual.width, available.width, accuracy: 0.5)
            XCTAssertEqual(actual.height, available.height, accuracy: 0.5)
            XCTAssertTrue(screen.visibleFrame.insetBy(dx: -0.5, dy: -0.5).contains(window.frame))
            XCTAssertEqual(window.contentMinSize, configured, "Screen fitting must preserve the configured minimum")
        }
    }

    func testSwitchingFromAlbumToStatusUsesSmallerRouteMinimum() throws {
        let controller = TravelUtilityWindowController()
        let window = try XCTUnwrap(controller.window)
        defer { window.orderOut(nil); window.close() }
        controller.show(content: AnyView(Text("album")), size: TravelUtilityWindowController.albumSize)
        controller.show(content: AnyView(Text("status")), size: TravelUtilityWindowController.statusSize)
        XCTAssertEqual(window.contentView?.frame.size, TravelUtilityWindowController.statusSize)
        XCTAssertEqual(window.contentMinSize, TravelUtilityWindowController.statusSize)
        controller.resize(to: TravelUtilityWindowController.albumSize)
        controller.resize(to: TravelUtilityWindowController.statusSize)
        XCTAssertEqual(window.contentView?.frame.size, TravelUtilityWindowController.statusSize)
        XCTAssertEqual(window.contentMinSize, TravelUtilityWindowController.statusSize)
    }

    func testHostingMinimumResetDoesNotEraseRouteContract() throws {
        let controller = TravelUtilityWindowController()
        let window = try XCTUnwrap(controller.window)
        defer { window.orderOut(nil); window.close() }
        controller.show(content: AnyView(Text("updating host")), size: TravelUtilityWindowController.albumSize)
        let configured = window.contentMinSize
        let screen = try XCTUnwrap(window.screen ?? NSScreen.main)
        let available = window.contentRect(forFrameRect: screen.visibleFrame).size
        // Live draft/disclosure edits in the native fixture cleared this property.
        window.contentMinSize = .zero
        var frame = window.frame; frame.size = NSSize(width: 75, height: 39)

        window.setFrame(frame, display: false)

        let actual = window.contentRect(forFrameRect: window.frame).size
        XCTAssertGreaterThanOrEqual(actual.width, min(configured.width, available.width))
        XCTAssertGreaterThanOrEqual(actual.height, min(configured.height, available.height))
        XCTAssertEqual(window.contentMinSize, configured)
    }

    func testOrdinaryResizeAboveMinimumKeepsRequestedSize() throws {
        let controller = TravelUtilityWindowController()
        let window = try XCTUnwrap(controller.window)
        defer { window.orderOut(nil); window.close() }
        controller.show(content: AnyView(Text("ordinary resize")), size: NSSize(width: 1000, height: 740),
                        minimumContentSize: NSSize(width: 760, height: 600))
        let screen = try XCTUnwrap(window.screen ?? NSScreen.main)
        let available = window.contentRect(forFrameRect: screen.visibleFrame).size
        var content = window.contentRect(forFrameRect: window.frame)
        content.size = NSSize(width: min(900, available.width), height: min(680, available.height))
        let requested = window.frameRect(forContentRect: content)

        window.setFrame(requested, display: false)

        XCTAssertEqual(window.frame, requested)
        XCTAssertEqual(window.contentMinSize, NSSize(width: 760, height: 600))
    }
}
