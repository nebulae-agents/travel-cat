import AppKit
import SwiftUI
import XCTest
import TravelCore
import TravelUI
@testable import TravelCatApp

@MainActor
final class StandalonePetControllerTests: XCTestCase {
    func testOnlyTravelCatAppBundlesCanPresentDesktopPet() {
        XCTAssertTrue(StandalonePetController.permitsDesktopPresentation(bundleURL: URL(fileURLWithPath: "/Applications/Travel Cat.app"), identifier: "com.nebulae.travelcat"))
        XCTAssertFalse(StandalonePetController.permitsDesktopPresentation(bundleURL: URL(fileURLWithPath: "/tmp/TravelCatPackageTests.xctest"), identifier: "com.apple.dt.xctest.tool"))
    }

    func testMenuRoutesExternallyAndKeepsCompactPresentation() throws {
        let suite = "StandalonePetTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(snapshot: .empty(now: Date()), events: [postcard()], defaults: defaults)
        var routes: [String] = []
        let controller = StandalonePetController(model: model,
            openJourney: { routes.append("journey") }, openPostcard: { routes.append("postcard") },
            openAlbum: { routes.append("album") }, openSupplies: { routes.append("supplies") },
            positionStore: WindowPositionStore(defaults: defaults))
        XCTAssertEqual(controller.contextMenu.items.map(\.title), ["当前旅程", "最新明信片", "旅行册", "用品", "", "隐藏桌宠"])
        for index in 0..<4 { controller.contextMenu.performActionForItem(at: index) }
        XCTAssertEqual(routes, ["journey", "postcard", "album", "supplies"])
        let window = try XCTUnwrap(controller.window)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: CGPoint(x: 120, y: 120),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
        XCTAssertEqual(routes.last, "journey")
        XCTAssertEqual(routes.count, 5)
        XCTAssertEqual(model.presentation, .pet)
        XCTAssertEqual(controller.window?.frame.size, CGSize(width: 240, height: 280))
        controller.show()
        XCTAssertNil(controller.locatorSelection(), "Tests must not put another pet on the user desktop")
        controller.contextMenu.performActionForItem(at: 5)
        XCTAssertFalse(controller.window?.isVisible ?? true)
        XCTAssertNil(controller.locatorSelection())
        controller.show()
        XCTAssertFalse(controller.window?.isVisible ?? false)
        controller.hide()
    }

    func testMenuAvailabilityRefreshesWhenPostcardArrivesOrHistoryIsCleared() throws {
        let suite = "StandalonePetAvailabilityTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(snapshot: .empty(now: Date()), defaults: defaults)
        let controller = StandalonePetController(model: model,
            openJourney: {}, openPostcard: {}, openAlbum: {}, openSupplies: {},
            positionStore: WindowPositionStore(defaults: defaults))
        XCTAssertFalse(controller.contextMenu.autoenablesItems)
        XCTAssertNotNil(controller.contextMenu.delegate)
        for index in [1, 2] { XCTAssertFalse(controller.contextMenu.items[index].isEnabled) }
        XCTAssertTrue(controller.contextMenu.items[0].isEnabled)
        XCTAssertTrue(controller.contextMenu.items[3].isEnabled)
        var next = model.snapshot
        next.stateVersion += 1
        model.apply(next: next, events: [postcard()])
        controller.contextMenu.delegate?.menuNeedsUpdate?(controller.contextMenu)
        for index in [1, 2] { XCTAssertTrue(controller.contextMenu.items[index].isEnabled) }
        model.replaceAfterHistoryClear(next: .empty(now: Date()), events: [])
        controller.contextMenu.delegate?.menuNeedsUpdate?(controller.contextMenu)
        for index in [1, 2] { XCTAssertFalse(controller.contextMenu.items[index].isEnabled) }
    }

    private func postcard() -> TripEvent {
        TripEvent(id: UUID(), tripID: UUID(), previousEventID: nil,
            occurredAt: Date(timeIntervalSince1970: 1), phase: .postcardReady,
            location: nil, transport: nil, summary: "来信", mood: Mood(level: 0, label: "开心", quote: "风景很好"),
            continuityReferences: [], openHook: nil, consumedItemID: nil,
            postcardStatus: .imageUnavailable, postcardRelativePath: nil)
    }

    func testSixPhasesKeepHouseAndOnlyHomePhasesShowCat() {
        let expected = ["在家休息", "收拾行囊", "正在路上", "探索远方", "远方来信", "正在回家"]
        XCTAssertEqual(TravelPhase.allCases.map { PetHouseStatus(phase: $0, hasUnreadPostcard: false).title }, expected)
        for phase in TravelPhase.allCases {
            let status = PetHouseStatus(phase: phase, hasUnreadPostcard: false)
            XCTAssertEqual(status.showsCat, phase == .resting || phase == .preparing)
            XCTAssertEqual(status.showsLetter, phase == .postcardReady)
            XCTAssertTrue(PetHouseStatus(phase: phase, hasUnreadPostcard: true).showsLetter)
        }
    }

    func testRenderSixStatesAtInitialAnimationFrame() throws {
        let directory = URL(fileURLWithPath: "/tmp/travel-cat-standalone-six-states", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for phase in TravelPhase.allCases {
            let view = NSHostingView(rootView: PetHouseView(phase: phase, hasUnreadPostcard: phase == .postcardReady))
            view.frame = CGRect(x: 0, y: 0, width: 240, height: 280)
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(data.count, 1000)
            // The roof must actually render, not just the cat and status label.
            var visibleRoofSamples = 0
            for y in stride(from: 0, to: bitmap.pixelsHigh / 2, by: 8) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 8) {
                    if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { visibleRoofSamples += 1 }
                }
            }
            XCTAssertGreaterThan(visibleRoofSamples, 150, "Missing cottage artwork for \(phase)")
            try data.write(to: directory.appendingPathComponent("\(phase.rawValue).png"))
        }
    }
}
