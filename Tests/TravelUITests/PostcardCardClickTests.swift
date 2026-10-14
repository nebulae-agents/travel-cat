import XCTest
import TravelCore
@testable import TravelUI

@MainActor
final class PostcardCardClickTests: XCTestCase {
    func testReducedMotionActionAlternatesFacesWithoutStartingATurn() throws {
        let animation = PostcardFlipAnimation()
        var face = PostcardFace.message
        face = try XCTUnwrap(animation.immediateFace(from: face, event: postcard()))
        XCTAssertEqual(face, .scenic)
        face = try XCTUnwrap(animation.immediateFace(from: face, event: postcard()))
        XCTAssertEqual(face, .message)
        XCTAssertFalse(animation.isTurning)
        XCTAssertEqual(animation.angle, 0)
    }

    func testReducedMotionActionGuardsUnavailableSceneryAndAllowsReturningToMessage() {
        for status in [PostcardStatus.pendingImage, .imageUnavailable, .none, .rejected, .ready] {
            for path in [nil, "", "postcards/test.png"] as [String?] {
                if status == .ready && path == "postcards/test.png" { continue }
                var event = postcard()
                event.postcardStatus = status
                event.postcardRelativePath = path
                let animation = PostcardFlipAnimation()
                XCTAssertNil(animation.immediateFace(from: .message, event: event))
                XCTAssertEqual(animation.immediateFace(from: .scenic, event: event), .message)
                XCTAssertFalse(animation.isTurning)
                XCTAssertEqual(animation.angle, 0)
            }
        }
    }

    private func postcard() -> TripEvent {
        TripEvent(id: UUID(), tripID: UUID(), previousEventID: nil,
            occurredAt: Date(), phase: .postcardReady,
            location: Location(country: "中国", city: "杭州", place: "西湖"), transport: "步行",
            summary: "小黑在湖边看风景。", mood: .init(level: 0, label: "平静", quote: "慢一点，水纹会给我新的答案。"),
            continuityReferences: [], openHook: nil, consumedItemID: nil,
            postcardStatus: .ready, postcardRelativePath: "postcards/test.png")
    }
}
