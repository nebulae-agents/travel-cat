import AppKit
import SwiftUI
import XCTest
import TravelCore
@testable import TravelUI

@MainActor
final class DesktopPetSceneRenderTests: XCTestCase {
    func testHomePlaybackRendersActionsAndResumesAfterReveal() async throws {
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                      "Animation intentionally stays static while system Reduce Motion is enabled.")
        let suite = "DesktopPetSceneRenderTests-playback-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = PlaybackSettings()
        let controller = DesktopPetController(content: AnyView(PlaybackFixture(settings: settings)), defaults: defaults)
        defer { controller.windowController.close() }
        controller.show()
        let hosting = try XCTUnwrap(controller.windowController.window?.contentView)
        try await Task.sleep(for: .milliseconds(40))
        let initial = try capture(hosting, name: "home-standing")
        // Six 180 ms frames finish the standing action before a different action starts.
        try await Task.sleep(for: .milliseconds(1100))
        let secondAction = try capture(hosting, name: "home-next-action")
        XCTAssertNotEqual(initial, secondAction)

        controller.hide()
        try await Task.sleep(for: .milliseconds(240))
        controller.show()
        try await Task.sleep(for: .milliseconds(60))
        let revealed = try capture(hosting, name: "home-revealed")
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertNotEqual(revealed, try capture(hosting, name: "home-revealed-next-action"))
    }

    func testHomePlaybackStaysStaticWhileHiddenAndWithReducedMotion() async throws {
        let suite = "DesktopPetSceneRenderTests-static-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = PlaybackSettings()
        let controller = DesktopPetController(content: AnyView(PlaybackFixture(settings: settings)), defaults: defaults)
        defer { controller.windowController.close() }
        controller.show()
        let hosting = try XCTUnwrap(controller.windowController.window?.contentView)
        try await Task.sleep(for: .milliseconds(240))
        controller.hide()
        try await Task.sleep(for: .milliseconds(60))
        let hidden = try capture(hosting, name: "home-hidden-static")
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(hidden, try capture(hosting))

        settings.reduceMotion = true
        controller.show()
        try await Task.sleep(for: .milliseconds(60))
        let reduced = try capture(hosting, name: "home-reduced-motion")
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(reduced, try capture(hosting))
        XCTAssertEqual(hidden, reduced)
    }

    private func capture(_ hosting: NSView, name: String? = nil) throws -> Data {
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        if let name, let directory = ProcessInfo.processInfo.environment["TRAVEL_CAT_DESKTOP_PREVIEW_DIR"] {
            let root = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try png.write(to: root.appendingPathComponent("\(name).png"))
        }
        return png
    }

    func testDesktopScenesRenderDistinctArtworkAtCompactSize() throws {
        let now = Date()
        let suite = "DesktopPetSceneRenderTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var scenes = Set<Data>()
        for phase in [TravelPhase.resting, .preparing, .exploring, .returning] {
            var snapshot = TripSnapshot.empty(now: now)
            snapshot.phase = phase
            let model = AppModel(snapshot: snapshot, defaults: defaults)
            let view = DesktopPetSceneView(model: model, showStatus: {}, showPostcard: {},
                                           showAlbum: {}, showSettings: {}, hide: {})
                .environment(\.colorScheme, .light)
            let panel = PetWindowController.makeWindow(content: AnyView(view))
            defer { panel.close() }
            let hosting = try XCTUnwrap(panel.contentView)
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, 240)
            XCTAssertGreaterThanOrEqual(bitmap.pixelsHigh, 280)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(png.count, 2000)
            scenes.insert(png)
            if let directory = ProcessInfo.processInfo.environment["TRAVEL_CAT_DESKTOP_PREVIEW_DIR"] {
                let root = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try png.write(to: root.appendingPathComponent("desktop-\(phase.rawValue).png"))
            }
        }
        XCTAssertEqual(scenes.count, 4)
    }
}

@MainActor
private final class PlaybackSettings: ObservableObject {
    @Published var reduceMotion = false
}

@MainActor
private struct PlaybackFixture: View {
    @ObservedObject var settings: PlaybackSettings
    var body: some View {
        PetSpriteView(state: .resting, requiresReducedMotion: settings.reduceMotion)
            .frame(width: 240, height: 280)
    }
}
