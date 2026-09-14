import AppKit
import XCTest
import TravelCore
@testable import TravelUI

final class PetSpriteTests: XCTestCase {
    func testVersion2LayoutMatchesAssetGeometry() {
        let layout = PetSpriteLayout.version2

        XCTAssertEqual(layout.frameSize, CGSize(width: 192, height: 208))
        XCTAssertEqual(layout.columns, 8)
        XCTAssertEqual(layout.rows, 11)
        XCTAssertEqual(layout.sheetSize, CGSize(width: 1_536, height: 2_288))
    }

    func testFrameRectUsesWholeCellsAndRejectsOutOfBoundsSelections() {
        let layout = PetSpriteLayout.version2

        XCTAssertEqual(
            layout.frameRect(row: 10, frame: 7),
            CGRect(x: 1_344, y: 2_080, width: 192, height: 208)
        )
        XCTAssertEqual(layout.frameOrigin(row: 1, frame: 2), CGPoint(x: 384, y: 208))
        XCTAssertNil(layout.frameRect(row: -1, frame: 0))
        XCTAssertNil(layout.frameRect(row: 0, frame: -1))
        XCTAssertNil(layout.frameRect(row: layout.rows, frame: 0))
        XCTAssertNil(layout.frameRect(row: 0, frame: layout.columns))
    }

    func testEveryTravelPhaseHasAnInBoundsAnimation() {
        let layout = PetSpriteLayout.version2

        for phase in TravelPhase.allCases {
            let animation = PetAnimation.animation(for: phase)
            XCTAssertTrue((0..<layout.rows).contains(animation.row), "Invalid row for \(phase)")
            XCTAssertTrue((1...layout.columns).contains(animation.frameCount), "Invalid frame count for \(phase)")

            for frame in 0..<animation.frameCount {
                XCTAssertNotNil(layout.frameRect(row: animation.row, frame: frame))
            }
        }
    }

    func testBaselinePhaseAnimationMapping() {
        XCTAssertEqual(PetAnimation.animation(for: .resting), PetAnimation(row: 0, frameCount: 6))
        XCTAssertEqual(PetAnimation.animation(for: .transit), PetAnimation(row: 1, frameCount: 8))

        for phase in TravelPhase.allCases where phase != .resting && phase != .transit {
            XCTAssertEqual(PetAnimation.animation(for: phase), PetAnimation(row: 8, frameCount: 6))
        }
    }

    func testBundledManifestIdentifiesSelectedPetAndSpriteVersion() throws {
        struct Manifest: Decodable {
            let displayName: String
            let description: String
            let spriteVersionNumber: Int
            let spritesheetPath: String
        }

        let url = try XCTUnwrap(PetSpriteResources.manifestURL)
        let data = try Data(contentsOf: url)
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(manifest.displayName, "Cute Black Cat")
        XCTAssertEqual(
            manifest.description,
            "A calm golden-eyed black cat with a subtle violet glow."
        )
        XCTAssertEqual(manifest.spriteVersionNumber, 2)
        XCTAssertEqual(manifest.spritesheetPath, "spritesheet.webp")
        XCTAssertEqual(
            Set(object.keys),
            Set(["displayName", "description", "spriteVersionNumber", "spritesheetPath"])
        )
    }

    func testImporterRejectsAlteredDescriptionWithoutChangingDestination() throws {
        try assertImporterResult(shouldSucceed: false) { manifest in
            manifest["description"] = "A different black cat."
        }
    }

    func testImporterRejectsExtraManifestKeyWithoutChangingDestination() throws {
        try assertImporterResult(shouldSucceed: false) { manifest in
            manifest["unapproved"] = true
        }
    }

    func testImporterAcceptsTheFullAuthorizedManifestWithoutChangingDestination() throws {
        try assertImporterResult(shouldSucceed: true) { _ in }
    }

    func testImporterRejectsDirectoryAtManifestDestinationWithoutChangingResources() throws {
        try assertImporterRejectsUnsafeDestination(named: "pet.json")
    }

    func testImporterRejectsDirectoryAtSpriteDestinationWithoutChangingResources() throws {
        try assertImporterRejectsUnsafeDestination(named: "cute-black-cat-spritesheet.webp")
    }

    func testImporterRejectsSymlinkSourceManifestWithoutChangingDestination() throws {
        let fileManager = FileManager.default
        let fixture = try makeImporterFixture()
        defer { try? fileManager.removeItem(at: fixture.root) }

        let realManifestURL = fixture.sourceDirectory.appendingPathComponent("real-pet.json")
        try fileManager.moveItem(at: fixture.sourceManifestURL, to: realManifestURL)
        try fileManager.createSymbolicLink(
            at: fixture.sourceManifestURL,
            withDestinationURL: realManifestURL
        )
        let manifestBefore = try Data(contentsOf: fixture.destinationManifestURL)
        let sheetBefore = try Data(contentsOf: fixture.destinationSheetURL)

        let status = try runImporter(fixture)

        XCTAssertNotEqual(status, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.destinationManifestURL), manifestBefore)
        XCTAssertEqual(try Data(contentsOf: fixture.destinationSheetURL), sheetBefore)
    }

    func testInvalidSourceDoesNotCreateAbsentDestinationDirectory() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let scriptsDirectory = root.appendingPathComponent("scripts", isDirectory: true)
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        let destinationDirectory = root
            .appendingPathComponent("Sources/TravelUI/Resources", isDirectory: true)
        try fileManager.createDirectory(at: scriptsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let copiedImporterURL = scriptsDirectory.appendingPathComponent("import-pet-asset.sh")
        try fileManager.copyItem(
            at: repositoryRoot.appendingPathComponent("Scripts/import-pet-asset.sh"),
            to: copiedImporterURL
        )
        let bundledManifestURL = try XCTUnwrap(PetSpriteResources.manifestURL)
        let bundledSheetURL = try XCTUnwrap(PetSpriteResources.spriteSheetURL)
        var manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: bundledManifestURL))
                as? [String: Any]
        )
        manifest["description"] = "Not the authorized pet."
        try JSONSerialization.data(withJSONObject: manifest).write(
            to: sourceDirectory.appendingPathComponent("pet.json")
        )
        try fileManager.copyItem(
            at: bundledSheetURL,
            to: sourceDirectory.appendingPathComponent("spritesheet.webp")
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [copiedImporterURL.path, sourceDirectory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertFalse(fileManager.fileExists(atPath: destinationDirectory.path))
    }

    func testBundledSpriteSheetLoadsAtExpectedPixelSizeWithAlpha() throws {
        let url = try XCTUnwrap(PetSpriteResources.spriteSheetURL)
        let image = try XCTUnwrap(NSImage(contentsOf: url))
        var proposedRect = CGRect(origin: .zero, size: image.size)
        let cgImage = try XCTUnwrap(
            image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
        )

        XCTAssertEqual(cgImage.width, 1_536)
        XCTAssertEqual(cgImage.height, 2_288)
        XCTAssertNotEqual(cgImage.alphaInfo, .none)
        XCTAssertNotEqual(cgImage.alphaInfo, .noneSkipFirst)
        XCTAssertNotEqual(cgImage.alphaInfo, .noneSkipLast)
    }

    private func assertImporterResult(
        shouldSucceed: Bool,
        _ mutation: (inout [String: Any]) -> Void
    ) throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let scriptsDirectory = temporaryRoot.appendingPathComponent("scripts", isDirectory: true)
        let sourceDirectory = temporaryRoot.appendingPathComponent("source", isDirectory: true)
        let resourcesDirectory = temporaryRoot
            .appendingPathComponent("Sources/TravelUI/Resources", isDirectory: true)
        try fileManager.createDirectory(at: scriptsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: resourcesDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: temporaryRoot)
        }

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let importerURL = repositoryRoot.appendingPathComponent("Scripts/import-pet-asset.sh")
        let copiedImporterURL = scriptsDirectory.appendingPathComponent("import-pet-asset.sh")
        let bundledManifestURL = try XCTUnwrap(PetSpriteResources.manifestURL)
        let bundledSheetURL = try XCTUnwrap(PetSpriteResources.spriteSheetURL)
        let destinationManifestURL = resourcesDirectory.appendingPathComponent("pet.json")
        let destinationSheetURL = resourcesDirectory
            .appendingPathComponent("cute-black-cat-spritesheet.webp")

        try fileManager.copyItem(at: importerURL, to: copiedImporterURL)
        try fileManager.copyItem(at: bundledManifestURL, to: destinationManifestURL)
        try fileManager.copyItem(at: bundledSheetURL, to: destinationSheetURL)
        try fileManager.copyItem(
            at: bundledSheetURL,
            to: sourceDirectory.appendingPathComponent("spritesheet.webp")
        )

        let bundledManifestData = try Data(contentsOf: bundledManifestURL)
        var manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bundledManifestData) as? [String: Any]
        )
        mutation(&manifest)
        let sourceManifestData = if shouldSucceed {
            bundledManifestData
        } else {
            try JSONSerialization.data(
                withJSONObject: manifest,
                options: [.prettyPrinted, .sortedKeys]
            )
        }
        try sourceManifestData.write(to: sourceDirectory.appendingPathComponent("pet.json"))

        let manifestBefore = try Data(contentsOf: destinationManifestURL)
        let sheetBefore = try Data(contentsOf: destinationSheetURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [copiedImporterURL.path, sourceDirectory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        if shouldSucceed {
            XCTAssertEqual(process.terminationStatus, 0)
        } else {
            XCTAssertNotEqual(process.terminationStatus, 0)
        }
        XCTAssertEqual(try Data(contentsOf: destinationManifestURL), manifestBefore)
        XCTAssertEqual(try Data(contentsOf: destinationSheetURL), sheetBefore)
    }

    private func assertImporterRejectsUnsafeDestination(named destinationName: String) throws {
        let fileManager = FileManager.default
        let fixture = try makeImporterFixture()
        defer { try? fileManager.removeItem(at: fixture.root) }

        let unsafeDestination = fixture.resourcesDirectory.appendingPathComponent(destinationName)
        try fileManager.removeItem(at: unsafeDestination)
        try fileManager.createDirectory(at: unsafeDestination, withIntermediateDirectories: false)
        let sentinelURL = unsafeDestination.appendingPathComponent("sentinel")
        let sentinel = Data("keep".utf8)
        try sentinel.write(to: sentinelURL)
        let safeResourceURL = destinationName == "pet.json"
            ? fixture.destinationSheetURL
            : fixture.destinationManifestURL
        let safeResourceBefore = try Data(contentsOf: safeResourceURL)

        let status = try runImporter(fixture)

        XCTAssertNotEqual(status, 0)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(fileManager.fileExists(atPath: unsafeDestination.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(try Data(contentsOf: sentinelURL), sentinel)
        XCTAssertFalse(fileManager.fileExists(
            atPath: unsafeDestination.appendingPathComponent(destinationName).path
        ))
        XCTAssertEqual(try Data(contentsOf: safeResourceURL), safeResourceBefore)
    }

    private struct ImporterFixture {
        let root: URL
        let copiedImporterURL: URL
        let sourceDirectory: URL
        let sourceManifestURL: URL
        let resourcesDirectory: URL
        let destinationManifestURL: URL
        let destinationSheetURL: URL
    }

    private func makeImporterFixture() throws -> ImporterFixture {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let scriptsDirectory = root.appendingPathComponent("scripts", isDirectory: true)
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        let resourcesDirectory = root
            .appendingPathComponent("Sources/TravelUI/Resources", isDirectory: true)
        try fileManager.createDirectory(at: scriptsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: resourcesDirectory, withIntermediateDirectories: true)

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let copiedImporterURL = scriptsDirectory.appendingPathComponent("import-pet-asset.sh")
        let bundledManifestURL = try XCTUnwrap(PetSpriteResources.manifestURL)
        let bundledSheetURL = try XCTUnwrap(PetSpriteResources.spriteSheetURL)
        let sourceManifestURL = sourceDirectory.appendingPathComponent("pet.json")
        let destinationManifestURL = resourcesDirectory.appendingPathComponent("pet.json")
        let destinationSheetURL = resourcesDirectory
            .appendingPathComponent("cute-black-cat-spritesheet.webp")

        try fileManager.copyItem(
            at: repositoryRoot.appendingPathComponent("Scripts/import-pet-asset.sh"),
            to: copiedImporterURL
        )
        try fileManager.copyItem(at: bundledManifestURL, to: sourceManifestURL)
        try fileManager.copyItem(
            at: bundledSheetURL,
            to: sourceDirectory.appendingPathComponent("spritesheet.webp")
        )
        try fileManager.copyItem(at: bundledManifestURL, to: destinationManifestURL)
        try fileManager.copyItem(at: bundledSheetURL, to: destinationSheetURL)

        return ImporterFixture(
            root: root,
            copiedImporterURL: copiedImporterURL,
            sourceDirectory: sourceDirectory,
            sourceManifestURL: sourceManifestURL,
            resourcesDirectory: resourcesDirectory,
            destinationManifestURL: destinationManifestURL,
            destinationSheetURL: destinationSheetURL
        )
    }

    private func runImporter(_ fixture: ImporterFixture) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [fixture.copiedImporterURL.path, fixture.sourceDirectory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
