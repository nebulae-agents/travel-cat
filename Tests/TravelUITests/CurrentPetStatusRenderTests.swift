import AppKit
import SwiftUI
import XCTest
import TravelCore
@testable import TravelUI

@MainActor
final class CurrentPetStatusRenderTests: XCTestCase {
    func testHomePackingAndAwayRenderAtMinimumWindowSize() throws {
        let now = Date()
        let suite = "CurrentPetStatusRenderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var renderedScenes = Set<Data>()
        for phase in [TravelPhase.resting, .preparing, .exploring] {
            let tripID = UUID()
            let event = TripEvent(id: UUID(), tripID: tripID, previousEventID: nil, occurredAt: now,
                phase: phase, location: Location(country: "中国", city: "杭州", place: "西湖"), transport: "火车",
                summary: phase == .preparing ? "把背包放在门口，准备出发。" : "微风轻轻吹过，今天的节奏很从容。",
                mood: Mood(level: 1, label: "平静", quote: ""), continuityReferences: [], openHook: nil,
                consumedItemID: nil, postcardStatus: .none, postcardRelativePath: nil)
            let snapshot = TripSnapshot(stateVersion: 1, tripID: tripID, lastEventID: event.id,
                phase: phase, nextActionAt: now.addingTimeInterval(600), lastUpdatedAt: now,
                usedItemIDs: [], visitedPlaces: [], mood: event.mood)
            let model = AppModel(snapshot: snapshot, events: [event], defaults: defaults)
            let view = CurrentPetStatusView(model: model, close: {}, openPostcard: { _ in }, openAlbum: {})
                .frame(width: 420, height: 520)
                .environment(\.colorScheme, .light)
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(x: 0, y: 0, width: 420, height: 520)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = hosting
            window.isReleasedWhenClosed = false
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            window.close()
            XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, 420)
            XCTAssertGreaterThanOrEqual(bitmap.pixelsHigh, 520)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(png.count, 5000)
            renderedScenes.insert(png)
            if let directory = ProcessInfo.processInfo.environment["TRAVEL_CAT_STATUS_PREVIEW_DIR"] {
                let root = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try png.write(to: root.appendingPathComponent("status-\(phase.rawValue).png"))
            }
        }
        XCTAssertEqual(renderedScenes.count, 3, "The scroll content must render different home/packing/away artwork")
    }
}
