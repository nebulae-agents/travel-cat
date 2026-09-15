import AppKit
import SwiftUI
import XCTest
import Combine
@testable import TravelUI

@MainActor
final class DesktopPetControllerTests: XCTestCase {
    func testVisibilitySourceForwardsControllerNotifications() throws {
        let suite = "DesktopPetControllerTests-notifications-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = DesktopPetController(content: AnyView(EmptyView()), defaults: defaults)
        defer { controller.windowController.close() }
        var notifications = 0
        let token = controller.objectWillChange.sink { notifications += 1 }
        controller.hide()
        XCTAssertTrue(controller.visibility.isHidden)
        controller.show()
        XCTAssertFalse(controller.visibility.isHidden)
        XCTAssertEqual(notifications, 2)
        withExtendedLifetime(token) {}
    }
    func testHiddenPreferenceSurvivesRecreationAndExplicitShowClearsIt() throws {
        let suite = "DesktopPetControllerTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = DesktopPetController(content: AnyView(EmptyView()), defaults: defaults)
        defer { first.windowController.close() }
        XCTAssertFalse(first.isHidden)
        first.hide()
        XCTAssertTrue(first.isHidden)
        XCTAssertFalse(first.windowController.window?.isVisible ?? true)
        let second = DesktopPetController(content: AnyView(EmptyView()), defaults: defaults)
        defer { second.windowController.close() }
        XCTAssertTrue(second.isHidden)
        second.restoreVisibility()
        XCTAssertFalse(second.windowController.window?.isVisible ?? true)
        second.show()
        XCTAssertFalse(second.isHidden)
        XCTAssertTrue(second.windowController.window?.isVisible ?? false)
        let third = DesktopPetController(content: AnyView(EmptyView()), defaults: defaults)
        defer { third.windowController.close() }
        XCTAssertFalse(third.isHidden)
    }

    func testHideAndShowPreserveWindowPositionAndContentSize() throws {
        let suite = "DesktopPetControllerTests-position-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = DesktopPetController(content: AnyView(EmptyView()), defaults: defaults)
        defer { controller.windowController.close() }
        controller.restoreVisibility()
        let window = try XCTUnwrap(controller.windowController.window)
        let original = window.frame
        controller.hide()
        controller.show()
        XCTAssertEqual(window.frame, original)
        XCTAssertEqual(window.frame.size, PetWindowController.compactSize)
    }
}
