import Foundation
import XCTest
@testable import TravelCore

final class CharacterProfileTests: XCTestCase {
    func testDefaultBlackCatHasStableIdentityAndBundledVersionTwoSprite() {
        let profile = CharacterProfile.defaultBlackCat

        XCTAssertEqual(profile.id, "cute-black-cat")
        XCTAssertEqual(profile.displayName, "Cute Black Cat")
        XCTAssertEqual(profile.spriteVersionNumber, 2)
        XCTAssertEqual(profile.sprite, .bundled("cute-black-cat-spritesheet.webp"))
        XCTAssertEqual(profile.referenceImages, [])
        XCTAssertEqual(profile.source, .bundledDefault)
    }

    func testProfileRoundTripsThroughTravelCatJSONCoding() throws {
        let profile = CharacterProfile(
            id: "miso",
            displayName: "Miso",
            description: "A travelling cat.",
            spriteVersionNumber: 2,
            sprite: .dataRootRelative("characters/miso/abc/assets/sprite.webp"),
            referenceImages: [.dataRootRelative("characters/miso/abc/assets/front.webp")],
            source: .importedManifest("characters/miso/abc/source-manifest.json")
        )

        let data = try JSONEncoder.travelCat.encode(profile)
        XCTAssertEqual(try JSONDecoder.travelCat.decode(CharacterProfile.self, from: data), profile)
    }
}
