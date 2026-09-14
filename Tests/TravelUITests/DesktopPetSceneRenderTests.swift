import AppKit
import SwiftUI
import XCTest
import TravelCore
@testable import TravelUI

@MainActor
final class DesktopPetSceneRenderTests: XCTestCase {
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
