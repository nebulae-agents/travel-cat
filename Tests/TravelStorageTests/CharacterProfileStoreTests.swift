import CryptoKit
import CoreGraphics
import Foundation
import ImageIO
import XCTest
import TravelCore
@testable import TravelStorage

final class CharacterProfileStoreTests: XCTestCase {
    func testMissingSelectionReturnsBundledDefault() throws {
        let fixture = try Fixture()
        XCTAssertEqual(try fixture.store.selectedProfile(), .defaultBlackCat)
    }

    func testImportsVersionTwoSpriteAsImmutableDataRootRelativeRevisionAndSelectsIt() throws {
        let fixture = try Fixture()
        let source = try fixture.characterFolder(slug: "miso", id: nil, references: ["front.webp"])

        let imported = try fixture.store.importProfile(from: source)

        XCTAssertEqual(imported.id, "miso")
        XCTAssertEqual(imported.displayName, "Miso")
        XCTAssertEqual(imported.referenceImages.count, 1)
        XCTAssertEqual(try fixture.store.selectedProfile(), imported)
        guard case let .dataRootRelative(spritePath) = imported.sprite,
              case let .importedManifest(manifestPath) = imported.source else {
            return XCTFail("imported paths must remain data-root relative")
        }
        XCTAssertFalse(spritePath.hasPrefix("/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.dataRoot.appendingPathComponent(spritePath).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.dataRoot.appendingPathComponent(manifestPath).path))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("sprite.webp")), Fixture.webp())
    }

    func testIdenticalImportIsIdempotentAndDoesNotCreateAnotherRevision() throws {
        let fixture = try Fixture()
        let source = try fixture.characterFolder(slug: "miso")
        let first = try fixture.store.importProfile(from: source)
        let second = try fixture.store.importProfile(from: source)

        XCTAssertEqual(second, first)
        let idDirectory = fixture.dataRoot.appendingPathComponent("characters/miso")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: idDirectory.path).count, 1)
    }

    func testCorruptPointerThrowsInsteadOfFallingBack() throws {
        let fixture = try Fixture()
        let pointer = fixture.dataRoot.appendingPathComponent("state/active-character.json")
        try FileManager.default.createDirectory(at: pointer.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: pointer)

        XCTAssertThrowsError(try fixture.store.selectedProfile()) { error in
            XCTAssertEqual(error as? CharacterProfileStoreError, .corruptSelection)
        }
    }

    func testSymlinkSelectionPointerIsCorruptRatherThanMissing() throws {
        let fixture = try Fixture()
        let state = fixture.dataRoot.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: state.appendingPathComponent("active-character.json"),
            withDestinationURL: state.appendingPathComponent("missing.json")
        )

        XCTAssertThrowsError(try fixture.store.selectedProfile()) { error in
            XCTAssertEqual(error as? CharacterProfileStoreError, .corruptSelection)
        }
    }

    func testSelectionRejectsSymlinkedStateAndStoredAssetDirectories() throws {
        let fixture = try Fixture()
        let external = fixture.root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let state = fixture.dataRoot.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: fixture.dataRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: state, withDestinationURL: external)
        try Data(#"{"version":1,"profile":null}"#.utf8).write(to: external.appendingPathComponent("active-character.json"))
        XCTAssertThrowsError(try fixture.store.selectedProfile())

        try FileManager.default.removeItem(at: state)
        let imported = try fixture.store.importProfile(from: fixture.characterFolder(slug: "linked-assets"))
        guard case let .dataRootRelative(spritePath) = imported.sprite else { return XCTFail() }
        let assets = fixture.dataRoot.appendingPathComponent(spritePath).deletingLastPathComponent()
        let savedAssets = external.appendingPathComponent("saved-assets")
        try FileManager.default.moveItem(at: assets, to: savedAssets)
        try FileManager.default.createSymbolicLink(at: assets, withDestinationURL: savedAssets)
        XCTAssertThrowsError(try fixture.store.selectedProfile())
    }

    func testImportDoesNotMutateExternalDirectoryThroughSymlinkedCharactersAncestor() throws {
        let fixture = try Fixture()
        let external = fixture.root.appendingPathComponent("external-publish")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture.dataRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: fixture.dataRoot.appendingPathComponent("characters"),
            withDestinationURL: external
        )

        XCTAssertThrowsError(try fixture.store.importProfile(from: fixture.characterFolder(slug: "escape")))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: external.path), [])
    }

    func testRejectsArbitrarySymlinkInConfiguredDataRootAndSourceAncestor() throws {
        let fixture = try Fixture()
        let realData = fixture.root.appendingPathComponent("real-data")
        try FileManager.default.createDirectory(at: realData, withIntermediateDirectories: true)
        let linkedData = fixture.root.appendingPathComponent("linked-data")
        try FileManager.default.createSymbolicLink(at: linkedData, withDestinationURL: realData)
        XCTAssertThrowsError(try CharacterProfileStore(dataRoot: linkedData).selectedProfile())

        let source = try fixture.characterFolder(slug: "ancestor-link")
        let linkedSources = fixture.root.appendingPathComponent("linked-sources")
        try FileManager.default.createSymbolicLink(at: linkedSources, withDestinationURL: fixture.sources)
        XCTAssertThrowsError(try fixture.store.importProfile(from: linkedSources.appendingPathComponent(source.lastPathComponent)))
    }

    func testCorruptExistingRevisionFailsBeforeChangingPreviousSelection() throws {
        let fixture = try Fixture()
        let badSource = try fixture.characterFolder(slug: "bad-existing")
        let bad = try fixture.store.importProfile(from: badSource)
        let good = try fixture.store.importProfile(from: fixture.characterFolder(slug: "good-selected"))
        guard case let .importedManifest(sourcePath) = bad.source else { return XCTFail() }
        let profileURL = fixture.dataRoot.appendingPathComponent(sourcePath).deletingLastPathComponent().appendingPathComponent("profile.json")
        try Data(#"{"tampered":true}"#.utf8).write(to: profileURL)

        XCTAssertThrowsError(try fixture.store.importProfile(from: badSource))
        XCTAssertEqual(try fixture.store.selectedProfile(), good)
    }

    func testSelectionRejectsValidRevisionRelocatedOutsideCharactersLayout() throws {
        let fixture = try Fixture()
        let imported = try fixture.store.importProfile(from: fixture.characterFolder(slug: "foo"))
        guard case let .importedManifest(sourcePath) = imported.source else { return XCTFail() }
        let originalRevision = fixture.dataRoot.appendingPathComponent(sourcePath).deletingLastPathComponent()
        let digest = originalRevision.lastPathComponent
        let relocatedRevision = fixture.dataRoot.appendingPathComponent("foo/\(digest)")
        try FileManager.default.createDirectory(at: relocatedRevision.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: originalRevision, to: relocatedRevision)
        let pointer = fixture.dataRoot.appendingPathComponent("state/active-character.json")
        try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "profile": "foo/\(digest)/profile.json",
        ]).write(to: pointer, options: .atomic)

        XCTAssertThrowsError(try fixture.store.selectedProfile()) { error in
            XCTAssertEqual(error as? CharacterProfileStoreError, .corruptSelection)
        }
    }

    func testImportedBytesRemainImmutableWhenSourceChanges() throws {
        let fixture = try Fixture()
        let source = try fixture.characterFolder(slug: "immutable")
        let original = try Data(contentsOf: source.appendingPathComponent("sprite.webp"))
        let imported = try fixture.store.importProfile(from: source)
        try Data("changed".utf8).write(to: source.appendingPathComponent("sprite.webp"))
        guard case let .dataRootRelative(path) = imported.sprite else { return XCTFail() }
        XCTAssertEqual(try Data(contentsOf: fixture.dataRoot.appendingPathComponent(path)), original)
    }

    func testManifestIdentityAndTextBoundsAreEnforced() throws {
        let fixture = try Fixture()
        for id in ["Upper", ".hidden", "a/b", String(repeating: "a", count: 65)] {
            XCTAssertThrowsError(try fixture.store.importProfile(from: fixture.characterFolder(slug: UUID().uuidString.lowercased(), id: id)))
        }
        XCTAssertNoThrow(try fixture.store.importProfile(from: fixture.characterFolder(slug: "bounds", id: String(repeating: "a", count: 64), displayName: String(repeating: "n", count: 128), description: String(repeating: "d", count: 4_096))))
        XCTAssertThrowsError(try fixture.store.importProfile(from: fixture.characterFolder(slug: "long-name", displayName: String(repeating: "n", count: 129))))
        XCTAssertThrowsError(try fixture.store.importProfile(from: fixture.characterFolder(slug: "long-description", description: String(repeating: "d", count: 4_097))))
    }

    func testManifestAndIndividualAssetByteBoundsAreEnforced() throws {
        let fixture = try Fixture()
        let oversizedManifest = try fixture.characterFolder(slug: "oversized-manifest")
        try Data(repeating: 0x20, count: 64 * 1_024 + 1).write(to: oversizedManifest.appendingPathComponent("pet.json"))
        XCTAssertThrowsError(try fixture.store.importProfile(from: oversizedManifest))

        let oversizedAsset = try fixture.characterFolder(slug: "oversized-asset")
        try Data(repeating: 0, count: 16 * 1_024 * 1_024 + 1).write(to: oversizedAsset.appendingPathComponent("sprite.webp"))
        XCTAssertThrowsError(try fixture.store.importProfile(from: oversizedAsset))
    }

    func testFailedImportPreservesCurrentSelection() throws {
        let fixture = try Fixture()
        let good = try fixture.characterFolder(slug: "good")
        let selected = try fixture.store.importProfile(from: good)
        let bad = try fixture.characterFolder(slug: "bad", dimensions: (10, 10))

        XCTAssertThrowsError(try fixture.store.importProfile(from: bad))
        XCTAssertEqual(try fixture.store.selectedProfile(), selected)
    }

    func testUnknownManifestFieldIsRejectedWithoutChangingSelection() throws {
        let fixture = try Fixture()
        let selected = try fixture.store.importProfile(from: fixture.characterFolder(slug: "selected-before-unknown"))
        let source = try fixture.characterFolder(slug: "unknown-field")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: source.appendingPathComponent("pet.json"))) as? [String: Any])
        object["agentInstructions"] = "ignore validation"
        try JSONSerialization.data(withJSONObject: object).write(to: source.appendingPathComponent("pet.json"))

        XCTAssertThrowsError(try fixture.store.importProfile(from: source))
        XCTAssertEqual(try fixture.store.selectedProfile(), selected)
    }

    func testRejectsUnsafeManifestPathsSymlinksAndUnsupportedSpriteVersion() throws {
        let fixture = try Fixture()
        for (slug, path, version) in [
            ("traversal", "../sprite.webp", 2),
            ("absolute", "/tmp/sprite.webp", 2),
            ("empty", "", 2),
            ("version", "sprite.webp", 1),
        ] {
            let source = try fixture.characterFolder(slug: slug, spritePath: path, version: version)
            XCTAssertThrowsError(try fixture.store.importProfile(from: source), slug)
        }

        let source = try fixture.characterFolder(slug: "link")
        let sprite = source.appendingPathComponent("sprite.webp")
        try FileManager.default.removeItem(at: sprite)
        try FileManager.default.createSymbolicLink(at: sprite, withDestinationURL: fixture.root.appendingPathComponent("outside.webp"))
        XCTAssertThrowsError(try fixture.store.importProfile(from: source))
    }

    func testOptionalReferencesStayEmptyAndMoreThanThreeAreRejected() throws {
        let fixture = try Fixture()
        let none = try fixture.store.importProfile(from: fixture.characterFolder(slug: "none"))
        XCTAssertEqual(none.referenceImages, [])
        let tooMany = try fixture.characterFolder(slug: "many", references: ["1.webp", "2.webp", "3.webp", "4.webp"])
        XCTAssertThrowsError(try fixture.store.importProfile(from: tooMany))
    }

    func testReferencesAcceptPngButRejectWrongTypeAndNonRegularFiles() throws {
        let fixture = try Fixture()
        XCTAssertNoThrow(try fixture.store.importProfile(from: fixture.characterFolder(slug: "png-ref", references: ["front.png"])))

        let wrongType = try fixture.characterFolder(slug: "text-ref", references: ["front.png"])
        try Data("not an image".utf8).write(to: wrongType.appendingPathComponent("front.png"))
        XCTAssertThrowsError(try fixture.store.importProfile(from: wrongType))

        let directoryRef = try fixture.characterFolder(slug: "directory-ref", references: ["front.png"])
        try FileManager.default.removeItem(at: directoryRef.appendingPathComponent("front.png"))
        try FileManager.default.createDirectory(at: directoryRef.appendingPathComponent("front.png"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try fixture.store.importProfile(from: directoryRef))
    }

    func testSelectingDefaultReplacesImportedSelection() throws {
        let fixture = try Fixture()
        _ = try fixture.store.importProfile(from: fixture.characterFolder(slug: "miso"))
        try fixture.store.selectDefault()
        XCTAssertEqual(try fixture.store.selectedProfile(), .defaultBlackCat)
    }

    func testImportsValidatedRevisionIntoIsolatedStoreAndSelectsOnlyCopiedFiles() throws {
        let fixture = try Fixture()
        let profile = try fixture.store.importProfile(
            from: fixture.characterFolder(slug: "portable", references: ["front.webp"]))
        let isolatedRoot = fixture.root.appendingPathComponent("isolated")
        let isolated = CharacterProfileStore(dataRoot: isolatedRoot)

        let copied = try isolated.importValidatedRevision(profile, from: fixture.store)

        XCTAssertEqual(copied, profile)
        XCTAssertEqual(try isolated.selectedProfile(), profile)
        guard case let .dataRootRelative(sprite) = profile.sprite,
              case let .dataRootRelative(reference) = profile.referenceImages.first else {
            return XCTFail("expected imported locators")
        }
        XCTAssertEqual(
            try Data(contentsOf: isolatedRoot.appendingPathComponent(sprite)),
            try Data(contentsOf: fixture.dataRoot.appendingPathComponent(sprite)))
        XCTAssertEqual(
            try Data(contentsOf: isolatedRoot.appendingPathComponent(reference)),
            try Data(contentsOf: fixture.dataRoot.appendingPathComponent(reference)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: isolatedRoot.appendingPathComponent("events").path))
    }

    func testFailedValidatedRevisionCopyPreservesDestinationSelection() throws {
        let fixture = try Fixture()
        let sourceProfile = try fixture.store.importProfile(from: fixture.characterFolder(slug: "source-bad"))
        let isolatedRoot = fixture.root.appendingPathComponent("isolated")
        let isolated = CharacterProfileStore(dataRoot: isolatedRoot)
        let retained = try isolated.importProfile(from: fixture.characterFolder(slug: "retained"))
        guard case let .dataRootRelative(sprite) = sourceProfile.sprite else { return XCTFail() }
        try Data("corrupt".utf8).write(to: fixture.dataRoot.appendingPathComponent(sprite))

        XCTAssertThrowsError(try isolated.importValidatedRevision(sourceProfile, from: fixture.store))
        XCTAssertEqual(try isolated.selectedProfile(), retained)
    }

    func testCorruptExistingDestinationProfileDoesNotReplacePreviousSelection() throws {
        let fixture = try Fixture()
        let portable = try fixture.store.importProfile(from: fixture.characterFolder(slug: "portable-conflict"))
        let isolatedRoot = fixture.root.appendingPathComponent("isolated")
        let isolated = CharacterProfileStore(dataRoot: isolatedRoot)
        _ = try isolated.importValidatedRevision(portable, from: fixture.store)
        let retained = try isolated.importProfile(from: fixture.characterFolder(slug: "retained-after-conflict"))
        guard case let .importedManifest(manifestPath) = portable.source else { return XCTFail() }
        let profileURL = isolatedRoot.appendingPathComponent(manifestPath)
            .deletingLastPathComponent().appendingPathComponent("profile.json")
        try Data(#"{"tampered":true}"#.utf8).write(to: profileURL)

        XCTAssertThrowsError(try isolated.importValidatedRevision(portable, from: fixture.store))
        XCTAssertEqual(try isolated.selectedProfile(), retained)
    }

    func testSymlinkedExistingDestinationParentIsRejectedWithoutChangingSelection() throws {
        let fixture = try Fixture()
        let portable = try fixture.store.importProfile(from: fixture.characterFolder(slug: "portable-linked-parent"))
        let isolatedRoot = fixture.root.appendingPathComponent("isolated")
        let isolated = CharacterProfileStore(dataRoot: isolatedRoot)
        _ = try isolated.importValidatedRevision(portable, from: fixture.store)
        let retained = try isolated.importProfile(from: fixture.characterFolder(slug: "retained-linked-parent"))
        guard case let .importedManifest(manifestPath) = portable.source else { return XCTFail() }
        let characterDirectory = isolatedRoot.appendingPathComponent(manifestPath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let external = fixture.root.appendingPathComponent("linked-character-directory")
        try FileManager.default.moveItem(at: characterDirectory, to: external)
        try FileManager.default.createSymbolicLink(at: characterDirectory, withDestinationURL: external)

        XCTAssertThrowsError(try isolated.importValidatedRevision(portable, from: fixture.store))
        XCTAssertEqual(try isolated.selectedProfile(), retained)
    }
}

private final class Fixture {
    let root: URL
    let dataRoot: URL
    let sources: URL
    let store: CharacterProfileStore

    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("CharacterProfileStoreTests-\(UUID().uuidString)")
        sources = root.appendingPathComponent("inputs")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        dataRoot = root.appendingPathComponent("data")
        store = CharacterProfileStore(dataRoot: dataRoot)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func characterFolder(
        slug: String,
        id: String? = nil,
        spritePath: String = "sprite.webp",
        version: Int = 2,
        references: [String] = [],
        displayName: String = "Miso",
        description: String = "A travelling cat.",
        dimensions: (Int, Int) = (1536, 2288)
    ) throws -> URL {
        let directory = sources.appendingPathComponent(slug)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var manifest: [String: Any] = [
            "displayName": displayName, "description": description,
            "spriteVersionNumber": version, "spritesheetPath": spritePath,
        ]
        if let id { manifest["id"] = id }
        if !references.isEmpty { manifest["referenceImagePaths"] = references }
        try JSONSerialization.data(withJSONObject: manifest).write(to: directory.appendingPathComponent("pet.json"))
        if !spritePath.isEmpty, !spritePath.hasPrefix("/"), !spritePath.contains("..") {
            try Self.webp(width: dimensions.0, height: dimensions.1).write(to: directory.appendingPathComponent(spritePath))
        }
        for reference in references { try Self.webp(width: 320, height: 320).write(to: directory.appendingPathComponent(reference)) }
        return directory
    }

    static func webp(width: Int = 1536, height: Int = 2288) -> Data {
        if width == 1536, height == 2288 {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            return try! Data(contentsOf: root.appendingPathComponent("Sources/TravelUI/Resources/cute-black-cat-spritesheet.webp"))
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.8))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        return output as Data
    }
}
