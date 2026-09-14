import Darwin
import Foundation
import XCTest
@testable import TravelStorage

final class DefaultPetInstallerTests: XCTestCase {
    func testInitialInstallAndExactRepeatPreserveSourceBytes() throws {
        let fixture = try Fixture()
        let installer = DefaultPetInstaller(resourcesRoot: fixture.resources, petsRoot: fixture.pets)
        XCTAssertEqual(try installer.install(), .installed)
        XCTAssertEqual(try installer.install(), .alreadyInstalled)
        XCTAssertEqual(try Data(contentsOf: fixture.target.appendingPathComponent("pet.json")), fixture.manifest)
        XCTAssertEqual(try Data(contentsOf: fixture.target.appendingPathComponent("spritesheet.webp")), fixture.sprite)
    }

    func testConflictAndTargetFileAreNeverOverwritten() throws {
        for targetIsFile in [false, true] {
            let fixture = try Fixture()
            if targetIsFile {
                try Data("keep-file".utf8).write(to: fixture.target)
            } else {
                try FileManager.default.createDirectory(at: fixture.target, withIntermediateDirectories: false)
                try Data("keep-conflict".utf8).write(to: fixture.target.appendingPathComponent("pet.json"))
            }
            let before = try fixture.snapshotTarget()
            XCTAssertThrowsError(try DefaultPetInstaller(resourcesRoot: fixture.resources, petsRoot: fixture.pets).install())
            XCTAssertEqual(try fixture.snapshotTarget(), before)
        }
    }

    func testCorruptSourceAndSourceOrTargetLinksFailWithoutStagingResidue() throws {
        let corrupt = try Fixture()
        try Data("corrupt".utf8).write(to: corrupt.resources.appendingPathComponent("pet.json"))
        XCTAssertThrowsError(try DefaultPetInstaller(resourcesRoot: corrupt.resources, petsRoot: corrupt.pets).install())
        XCTAssertFalse(FileManager.default.fileExists(atPath: corrupt.target.path))

        let linkedSource = try Fixture()
        let manifest = linkedSource.resources.appendingPathComponent("pet.json")
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: linkedSource.sourceManifest)
        XCTAssertThrowsError(try DefaultPetInstaller(resourcesRoot: linkedSource.resources, petsRoot: linkedSource.pets).install())

        let linkedTarget = try Fixture()
        let outside = linkedTarget.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: linkedTarget.target, withDestinationURL: outside)
        XCTAssertThrowsError(try DefaultPetInstaller(resourcesRoot: linkedTarget.resources, petsRoot: linkedTarget.pets).install())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: linkedTarget.pets.path), ["cute-black-cat"])
    }

    func testFIFOResourceIsRejectedWithoutBlockingOrTouchingTarget() throws {
        let fixture = try Fixture()
        let manifest = fixture.resources.appendingPathComponent("pet.json")
        try FileManager.default.removeItem(at: manifest)
        XCTAssertEqual(mkfifo(manifest.path, 0o600), 0)
        XCTAssertThrowsError(try DefaultPetInstaller(resourcesRoot: fixture.resources, petsRoot: fixture.pets).install())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.target.path))
    }

    func testConcurrentExactTargetAppearanceReturnsAlreadyInstalledAndCleansOnlyOwnStaging() throws {
        let fixture = try Fixture()
        let preserved = fixture.pets.appendingPathComponent(".unrelated-staging")
        try FileManager.default.createDirectory(at: preserved, withIntermediateDirectories: false)
        let installer = DefaultPetInstaller(resourcesRoot: fixture.resources, petsRoot: fixture.pets)
        installer.beforePublish = {
            try FileManager.default.createDirectory(at: fixture.target, withIntermediateDirectories: false)
            try fixture.manifest.write(to: fixture.target.appendingPathComponent("pet.json"))
            try fixture.sprite.write(to: fixture.target.appendingPathComponent("spritesheet.webp"))
        }
        XCTAssertEqual(try installer.install(), .alreadyInstalled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: preserved.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.pets.path).filter { $0.hasPrefix(".cute-black-cat-install-") }, [])
    }

    func testMissingCodexHomeAndCustomAncestorSymlinkAreRejected() throws {
        let missing = try Fixture()
        try FileManager.default.removeItem(at: missing.codexHome)
        XCTAssertThrowsError(try DefaultPetInstaller(resourcesRoot: missing.resources, petsRoot: missing.pets).install())

        let linked = try Fixture()
        let realHome = linked.root.appendingPathComponent("real codex", isDirectory: true)
        try FileManager.default.createDirectory(at: realHome, withIntermediateDirectories: false)
        let linkedHome = linked.root.appendingPathComponent("linked codex", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedHome, withDestinationURL: realHome)
        XCTAssertThrowsError(try DefaultPetInstaller(
            resourcesRoot: linked.resources,
            petsRoot: linkedHome.appendingPathComponent("pets", isDirectory: true)
        ).install())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: realHome.path), [])
    }

    func testConcurrentConflictingTargetIsPreservedAndOnlyOwnedStagingIsRemoved() throws {
        let fixture = try Fixture()
        let preserved = fixture.pets.appendingPathComponent(".unrelated-staging")
        try FileManager.default.createDirectory(at: preserved, withIntermediateDirectories: false)
        let installer = DefaultPetInstaller(resourcesRoot: fixture.resources, petsRoot: fixture.pets)
        installer.beforePublish = {
            try FileManager.default.createDirectory(at: fixture.target, withIntermediateDirectories: false)
            try Data("competitor".utf8).write(to: fixture.target.appendingPathComponent("pet.json"))
        }
        XCTAssertThrowsError(try installer.install())
        XCTAssertEqual(try Data(contentsOf: fixture.target.appendingPathComponent("pet.json")), Data("competitor".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: preserved.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.pets.path).filter { $0.hasPrefix(".cute-black-cat-install-") }, [])
    }

    func testReplacedStagingDirectoryIsNeitherPublishedNorDeleted() throws {
        let fixture = try Fixture()
        let installer = DefaultPetInstaller(resourcesRoot: fixture.resources, petsRoot: fixture.pets)
        var foreign: URL?
        installer.beforePublish = {
            let stagingName = try XCTUnwrap(
                FileManager.default.contentsOfDirectory(atPath: fixture.pets.path)
                    .first { $0.hasPrefix(".cute-black-cat-install-") }
            )
            let staging = fixture.pets.appendingPathComponent(stagingName, isDirectory: true)
            let moved = fixture.pets.appendingPathComponent("moved-owned-staging", isDirectory: true)
            try FileManager.default.moveItem(at: staging, to: moved)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            try Data("foreign sentinel".utf8).write(to: staging.appendingPathComponent("sentinel"))
            foreign = staging
        }

        XCTAssertThrowsError(try installer.install())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.target.path))
        let foreignDirectory = try XCTUnwrap(foreign)
        XCTAssertEqual(try Data(contentsOf: foreignDirectory.appendingPathComponent("sentinel")), Data("foreign sentinel".utf8))
    }
}

private struct Fixture {
    let root: URL
    let resources: URL
    let codexHome: URL
    let pets: URL
    let target: URL
    let sourceManifest: URL
    let manifest: Data
    let sprite: Data

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Default Pet Tests \(UUID().uuidString)", isDirectory: true)
        resources = root.appendingPathComponent("Signed Resources", isDirectory: true)
        codexHome = root.appendingPathComponent("Codex Home", isDirectory: true)
        pets = codexHome.appendingPathComponent("pets", isDirectory: true)
        target = pets.appendingPathComponent("cute-black-cat", isDirectory: true)
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        sourceManifest = project.appendingPathComponent("Sources/TravelUI/Resources/pet.json")
        let sourceSprite = project.appendingPathComponent("Sources/TravelUI/Resources/cute-black-cat-spritesheet.webp")
        manifest = try Data(contentsOf: sourceManifest)
        sprite = try Data(contentsOf: sourceSprite)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pets, withIntermediateDirectories: false)
        try manifest.write(to: resources.appendingPathComponent("pet.json"))
        try sprite.write(to: resources.appendingPathComponent("cute-black-cat-spritesheet.webp"))
    }

    func snapshotTarget() throws -> [String: Data] {
        var result: [String: Data] = [:]
        if let data = try? Data(contentsOf: target) { result["$file"] = data; return result }
        guard FileManager.default.fileExists(atPath: target.path) else { return result }
        for name in try FileManager.default.contentsOfDirectory(atPath: target.path) {
            result[name] = try Data(contentsOf: target.appendingPathComponent(name))
        }
        return result
    }
}
