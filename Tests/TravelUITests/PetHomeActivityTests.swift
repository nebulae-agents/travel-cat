import AppKit
import SwiftUI
import XCTest
import TravelCore
@testable import TravelUI

final class PetHomeActivityTests: XCTestCase {
    @MainActor func testActivityFramesRenderAsSingleClippedSprites() throws {
        let rows = VStack(spacing: 8) {
            HStack {
                ForEach(Array(PetHomeActivity.allCases.prefix(3)), id: \.self) { activity in
                    VStack {
                        PetSpriteView(animation: activity.animation, isAnimating: false)
                        Text(activity.title).font(.system(size: 12))
                    }.frame(width: 150, height: 160)
                }
            }
            HStack {
                ForEach(Array(PetHomeActivity.allCases.suffix(3)), id: \.self) { activity in
                    VStack {
                        PetSpriteView(animation: activity.animation, isAnimating: false)
                        Text(activity.title).font(.system(size: 12))
                    }.frame(width: 150, height: 160)
                }
            }
        }.padding(12).background(Color.white)
        let view = NSHostingView(rootView: rows)
        view.frame = NSRect(x: 0, y: 0, width: 500, height: 350)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let bytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(bytes.count, 10_000)
        if let path = ProcessInfo.processInfo.environment["TRAVELCAT_HOME_RENDER_PATH"] {
            try bytes.write(to: URL(fileURLWithPath: path))
        }
    }

    func testEveryActivityUsesExistingDistinctFramesInsideTheAtlas() {
        let layout = PetSpriteLayout.version2
        XCTAssertGreaterThanOrEqual(Set(PetHomeActivity.allCases.map { $0.animation.row }).count, 4)
        for activity in PetHomeActivity.allCases {
            XCTAssertFalse(activity.title.isEmpty)
            XCTAssertTrue((12...90).contains(activity.duration))
            for frame in activity.animation.frames {
                XCTAssertNotNil(layout.frameRect(row: activity.animation.row, frame: frame), activity.rawValue)
            }
        }
    }
    func testDaytimeVariesWithoutRepeatingAndNightStaysQuiet() {
        var seen = Set<PetHomeActivity>()
        for seed in UInt64(0)..<100 {
            let activity = PetHomeActivity.next(after: .watching, hour: 12, seed: seed)
            XCTAssertNotEqual(activity, .watching)
            seen.insert(activity)
            let night = PetHomeActivity.next(after: .watching, hour: 23, seed: seed)
            XCTAssertTrue([PetHomeActivity.dozing, .stretching].contains(night))
        }
        XCTAssertGreaterThanOrEqual(seen.count, 4)
        XCTAssertEqual(PetHomeActivity.initial(hour: 2), .dozing)
        XCTAssertEqual(PetHomeActivity.initial(hour: 10), .watching)
    }
    func testWalkingFacesItsDirectionOfTravel() {
        XCTAssertEqual(PetHomeActivity.strolling.animation(facingLeft: false).row, 1)
        XCTAssertEqual(PetHomeActivity.strolling.animation(facingLeft: true).row, 2)
        XCTAssertEqual(PetHomeActivity.dozing.animation(facingLeft: true), PetHomeActivity.dozing.animation)
    }

    func testDozingKeepsEyesClosedAndWalkingDoesNotLeaveThePorch() {
        XCTAssertEqual(PetHomeActivity.dozing.animation.row, 0)
        XCTAssertEqual(PetHomeActivity.dozing.animation.frames.first, 4)
        for activity in PetHomeActivity.allCases {
            XCTAssertLessThanOrEqual(abs(activity.horizontalOffset), 14)
        }
    }
}
