import XCTest
import TravelCore
@testable import TravelUI

final class PostcardTwoSidedPolicyTests: XCTestCase {
    func testMissingSceneryAlwaysStartsOnMessageEvenForPreviouslyReadCards() {
        XCTAssertEqual(PostcardFace.initial(isUnread: false, hasScenery: false), .message)
        XCTAssertEqual(PostcardFace.initial(isUnread: true, hasScenery: false), .message)
        XCTAssertEqual(PostcardFace.initial(isUnread: false, hasScenery: true), .scenic)
        XCTAssertEqual(PostcardFace.initial(isUnread: true, hasScenery: true), .message)
    }

    func testOnlyReadyCardWithAPathAllowsFlippingToScenery() {
        for status in [PostcardStatus.pendingImage, .imageUnavailable, .none, .rejected, .ready] {
            for path: String? in [nil, "", "postcards/photo.png"] {
                let event = TripEvent(id: UUID(), tripID: UUID(), previousEventID: nil,
                    occurredAt: Date(), phase: .postcardReady, location: nil, transport: nil,
                    summary: "风景", mood: .init(level: 0, label: "平静", quote: "风景正好"),
                    continuityReferences: [], openHook: nil, consumedItemID: nil,
                    postcardStatus: status, postcardRelativePath: path)
                XCTAssertEqual(PostcardFace.hasScenery(for: event), status == .ready && path == "postcards/photo.png")
            }
        }
    }
}
