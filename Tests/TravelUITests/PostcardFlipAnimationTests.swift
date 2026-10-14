import XCTest
import TravelCore
@testable import TravelUI

@MainActor
final class PostcardFlipAnimationTests: XCTestCase {
    func testTurnKeepsOldFaceUntilMidpointAndRejectsRepeatedClicks() throws {
        let animation = PostcardFlipAnimation()
        let event = postcard()
        let turn = try XCTUnwrap(animation.begin(from: .message, event: event))
        XCTAssertTrue(animation.isTurning)
        XCTAssertFalse(animation.isUnfolding)
        XCTAssertEqual(animation.expectedFace, .message)
        XCTAssertNil(animation.begin(from: .message, event: event))
        XCTAssertEqual(animation.reveal(turn), .scenic)
        XCTAssertEqual(animation.expectedFace, .scenic)
        XCTAssertTrue(animation.isUnfolding)
        XCTAssertTrue(animation.isTurning, "Scenery observation stays disabled while the new face unfolds")
        XCTAssertNil(animation.reveal(turn), "The midpoint cannot run twice")
        animation.finish(turn)
        XCTAssertFalse(animation.isTurning)
        XCTAssertFalse(animation.isUnfolding)
        let reverse = try XCTUnwrap(animation.begin(from: .scenic, event: event))
        XCTAssertEqual(animation.reveal(reverse), .message)
        animation.finish(reverse)
        XCTAssertFalse(animation.isTurning)
    }

    func testCancelledCompletionCannotRevealOrFinishANewerTurn() throws {
        let animation = PostcardFlipAnimation()
        let event = postcard()
        let old = try XCTUnwrap(animation.begin(from: .message, event: event))
        animation.angle = 90
        animation.cancel()
        XCTAssertEqual(animation.angle, 0)
        XCTAssertFalse(animation.isTurning)
        let current = try XCTUnwrap(animation.begin(from: .message, event: event))
        XCTAssertNil(animation.reveal(old))
        animation.finish(old)
        XCTAssertTrue(animation.isTurning)
        XCTAssertEqual(animation.expectedFace, .message)
        XCTAssertEqual(animation.reveal(current), .scenic)
        animation.finish(old)
        XCTAssertTrue(animation.isTurning)
        animation.finish(current)
        XCTAssertFalse(animation.isTurning)
    }

    func testUnavailableSceneryDoesNotStartATurnButCanReturnToMessage() throws {
        for status in [PostcardStatus.pendingImage, .imageUnavailable, .none, .rejected, .ready] {
            for path in [nil, "", "postcards/test.png"] as [String?] {
                if status == .ready && path == "postcards/test.png" { continue }
                var event = postcard()
                event.postcardStatus = status
                event.postcardRelativePath = path
                let animation = PostcardFlipAnimation()
                XCTAssertNil(animation.begin(from: .message, event: event))
                XCTAssertFalse(animation.isTurning)
                let reverse = try XCTUnwrap(animation.begin(from: .scenic, event: event))
                XCTAssertEqual(animation.reveal(reverse), .message)
                animation.finish(reverse)
                XCTAssertFalse(animation.isTurning)
            }
        }
    }

    func testDeferredVisibilityUsesCurrentPhaseAndFaceWhenInvoked() throws {
        let animation = PostcardFlipAnimation()
        var face = PostcardFace.scenic
        var reports: [String] = []
        let deferred = animation.visibilityHandler(face: { face }, onVisible: { reports.append($0) })
        let turn = try XCTUnwrap(animation.begin(from: face, event: postcard()))
        deferred("postcards/test.png")
        XCTAssertTrue(reports.isEmpty)
        face = try XCTUnwrap(animation.reveal(turn))
        deferred("postcards/test.png")
        XCTAssertTrue(reports.isEmpty)
        animation.finish(turn)
        deferred("postcards/test.png")
        XCTAssertTrue(reports.isEmpty, "A delayed photo callback cannot consume a card now showing text")
        face = .scenic
        deferred("postcards/test.png")
        XCTAssertEqual(reports, ["postcards/test.png"])
    }

    private func postcard() -> TripEvent {
        TripEvent(id: UUID(), tripID: UUID(), previousEventID: nil,
            occurredAt: Date(), phase: .postcardReady, location: nil, transport: "步行",
            summary: "旅途小憩", mood: .init(level: 0, label: "平静", quote: "停一停再出发。"),
            continuityReferences: [], openHook: nil, consumedItemID: nil,
            postcardStatus: .ready, postcardRelativePath: "postcards/test.png")
    }
}
