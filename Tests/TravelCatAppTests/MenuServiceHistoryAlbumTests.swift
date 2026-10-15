import AppKit
import SwiftUI
import Vision
import XCTest
import TravelCore
import TravelUI
@testable import TravelCatApp

final class MenuServiceHistoryAlbumTests: XCTestCase {
    @MainActor
    func testMenuAlbumRendersPostcardsFromEarlierAndLatestTrips() throws {
        _ = NSApplication.shared
        let suiteName = "MenuServiceHistoryAlbumTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let older = postcard(tripID: UUID(), at: now.addingTimeInterval(-600), place: "Historic Meadow")
        let latest = postcard(tripID: UUID(), at: now.addingTimeInterval(-300), place: "Recent Harbor")
        let snapshot = TripSnapshot(
            stateVersion: 1, tripID: latest.tripID, phase: .resting,
            nextActionAt: now, lastUpdatedAt: now,
            usedItemIDs: [], visitedPlaces: [], mood: latest.mood
        )
        let model = AppModel(snapshot: snapshot, events: [latest, older], defaults: defaults,
                             supplies: [], clock: { now })
        model.openLatestAlbumFromMenu()
        XCTAssertEqual(model.presentation, .album(latest.tripID))
        let unreadBeforeRendering = model.unreadPostcardIDs
        let hosting = NSHostingView(rootView: MenuServiceRootView(
            model: model, closeWindow: {}, presentationChanged: { _ in }
        ).environment(\.colorScheme, .light))
        hosting.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 760, height: 1_000),
            styleMask: [], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer {
            window.close()
            window.contentView = nil
        }

        // Hidden SwiftUI hosts expose no AX children on this macOS version.
        // Inspect the actual rendered cards; both trips share one visible row.
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1_520, pixelsHigh: 2_000,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.size = hosting.bounds.size
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let image = try XCTUnwrap(bitmap.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        let renderedText = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        XCTAssertTrue(renderedText.contains("Recent Harbor"), "Latest card must render; text: \(renderedText)")
        XCTAssertTrue(renderedText.contains("Historic Meadow"), "Historical card must render alongside the latest trip; text: \(renderedText)")
        XCTAssertFalse(window.isVisible, "Regression must never display a test window")
        XCTAssertEqual(model.events, [latest, older])
        XCTAssertEqual(model.snapshot, snapshot)
        XCTAssertEqual(model.unreadPostcardIDs, unreadBeforeRendering)
        XCTAssertEqual(model.presentation, .album(latest.tripID))
    }

    private func postcard(tripID: UUID, at date: Date, place: String) -> TripEvent {
        let id = UUID()
        return TripEvent(
            id: id, tripID: tripID, previousEventID: nil, occurredAt: date, phase: .exploring,
            location: Location(country: "中国", city: "杭州", place: place), transport: nil,
            summary: place, mood: Mood(level: 1, label: "平静", quote: place),
            continuityReferences: [], openHook: nil, consumedItemID: nil,
            postcardStatus: .ready, postcardRelativePath: "postcards/\(id).png"
        )
    }
}
