import Foundation
import XCTest
import TravelCore
import TravelStorage
@testable import TravelUI

final class CharacterSpriteResolverTests: XCTestCase {
    func testValidatedImportedProfileResolvesInsideDataRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CharacterSpriteResolverTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "id": "orange-cat", "displayName": "小橘", "description": "A pet.",
            "spriteVersionNumber": 2, "spritesheetPath": "sprite.webp",
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: source.appendingPathComponent("pet.json"))
        let bundled = try XCTUnwrap(PetSpriteResources.spriteSheetURL)
        try FileManager.default.copyItem(at: bundled, to: source.appendingPathComponent("sprite.webp"))
        let dataRoot = root.appendingPathComponent("data", isDirectory: true)
        let profile = try CharacterProfileStore(dataRoot: dataRoot).importProfile(from: source)

        guard case let .available(url) = CharacterSpriteResolver.resolve(profile: profile, dataRoot: dataRoot) else {
            return XCTFail("A validated imported sprite should resolve")
        }
        XCTAssertTrue(url.path.hasPrefix(dataRoot.path + "/"))
        XCTAssertEqual(url.lastPathComponent, "sprite.webp")
    }
    func testForgedImportedProfileIsUnavailableInsteadOfFallingBackToBlackCat() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CharacterSpriteResolverTests-\(UUID().uuidString)")
        let forged = CharacterProfile(
            id: "forged", displayName: "未验证角色", description: "", spriteVersionNumber: 2,
            sprite: .dataRootRelative("characters/forged/nope/assets/pet.webp"),
            referenceImages: [],
            source: .importedManifest("characters/forged/nope/source-manifest.json")
        )

        XCTAssertEqual(CharacterSpriteResolver.resolve(profile: forged, dataRoot: root), .unavailable(displayName: "未验证角色"))
    }

    func testDefaultProfileUsesBundledResource() {
        guard case let .available(url) = CharacterSpriteResolver.resolve(profile: .defaultBlackCat, dataRoot: nil) else {
            return XCTFail("The bundled default should resolve")
        }
        XCTAssertEqual(url.lastPathComponent, "cute-black-cat-spritesheet.webp")
    }
}
