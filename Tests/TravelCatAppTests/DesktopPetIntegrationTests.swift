import SwiftUI
import XCTest
import TravelCore
import TravelUI
@testable import TravelCatApp

@MainActor
final class DesktopPetIntegrationTests: XCTestCase {
    func testMailboxRemainsAvailableWithoutLiveWorkbench() async throws {
        _ = NSApplication.shared
        let suite = "MailboxWithoutWorkbench-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "TravelCat.desktopPet.hidden")
        let delegate = TravelCatAppDelegate()
        let model = AppModel(snapshot: .empty(now: Date()), defaults: defaults)
        delegate.installDesktopPet(model: model, defaults: defaults)
        defer {
            delegate.desktopPetController?.windowController.close()
            NSApp.windows.filter { $0.title == "小黑的邮筒" }.forEach { $0.orderOut(nil) }
        }
        let mailbox = try XCTUnwrap(NSApp.windows.first { $0.title == "小黑的邮筒" && $0.isVisible },
            "A read-only workbench must not remove the independent postcard mailbox")
        delegate.toggleDesktopPet()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(mailbox.isVisible)
        delegate.toggleDesktopPet()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(mailbox.isVisible)
    }

    func testAppOwnsPetAndMenuTogglePersistsWithoutStartingCodexMenuMonitor() throws {
        let suite = "DesktopPetIntegrationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "TravelCat.desktopPet.hidden")
        let delegate = TravelCatAppDelegate()
        let model = AppModel(snapshot: .empty(now: Date()), defaults: defaults)
        delegate.installDesktopPet(model: model, defaults: defaults)
        let pet = try XCTUnwrap(delegate.desktopPetController)
        defer { pet.windowController.close() }
        XCTAssertTrue(pet.isHidden)
        XCTAssertNil(delegate.desktopPetAnchor)
        XCTAssertFalse(pet.windowController.window?.isVisible ?? true)
        delegate.toggleDesktopPet()
        XCTAssertFalse(pet.isHidden)
        XCTAssertTrue(pet.windowController.window?.isVisible ?? false)
        XCTAssertEqual(delegate.desktopPetAnchor?.appKitBounds, pet.windowController.window?.frame)
        delegate.toggleDesktopPet()
        XCTAssertTrue(pet.isHidden)
        XCTAssertTrue(defaults.bool(forKey: "TravelCat.desktopPet.hidden"))
    }
}
