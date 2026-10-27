import Foundation
import XCTest
@testable import TravelStorage

final class RepositoryExportDestinationTests: XCTestCase {
    private let unsafeMessage = "export destination must be outside the repository"

    private func fixture() throws -> (URL, URL, TravelRepository) {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("ExportDestination-\(UUID().uuidString)").resolvingSymlinksInPath()
        let root = parent.appendingPathComponent("Data")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        return (parent, root, try TravelRepository(root: root))
    }

    private func assertRejected(_ destination: URL, repository: TravelRepository, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertThrowsError(try repository.export(to: destination), file: file, line: line) {
            XCTAssertEqual(String(describing: $0), self.unsafeMessage, file: file, line: line)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), file: file, line: line)
        let names = try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path)
        XCTAssertFalse(names.contains { $0.hasSuffix(".export.tmp") }, file: file, line: line)
    }

    func testExportRejectsPostcardsDestinationWithoutPublishingOrChangingSource() throws {
        let (_, root, repository) = try fixture()
        let source = root.appendingPathComponent("state/current-trip.json")
        let original = try Data(contentsOf: source)
        // Existing postcard export skips hidden staging, so this red test cannot recurse.
        try assertRejected(root.appendingPathComponent("postcards/backup"), repository: repository)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testExportRejectsNestedDestinationsBeforeReadingSourceTrees() throws {
        let (parent, root, repository) = try fixture()
        // A source-link sentinel aborts old code before it can reach characters/staging.
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("postcards/sentinel"), withDestinationURL: parent.appendingPathComponent("missing"))
        for relative in ["characters/backup", "characters/custom/nested/backup", "state/backup", "backups/nested/backup"] {
            let destination = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try assertRejected(destination, repository: repository)
        }
    }

    func testExportRejectsRepositoryRootBeforeExistingDestinationCheck() throws {
        let (_, root, repository) = try fixture()
        XCTAssertThrowsError(try repository.export(to: root)) {
            XCTAssertEqual(String(describing: $0), self.unsafeMessage)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("state/current-trip.json").path))
    }

    func testExportRejectsPhysicalDescendantThroughExternalSymlink() throws {
        let (parent, root, repository) = try fixture()
        let characters = root.appendingPathComponent("characters")
        try FileManager.default.createDirectory(at: characters, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("postcards/sentinel"), withDestinationURL: parent.appendingPathComponent("missing"))
        let alias = parent.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: characters)
        try assertRejected(alias.appendingPathComponent("backup"), repository: repository)
    }

    func testExportRejectsCaseAliasOnCaseInsensitiveVolume() throws {
        let (_, root, repository) = try fixture()
        let alias = root.deletingLastPathComponent().appendingPathComponent("DATA")
        guard FileManager.default.fileExists(atPath: alias.path) else { throw XCTSkip("Case-sensitive volume") }
        try assertRejected(alias.appendingPathComponent("postcards/backup"), repository: repository)
    }

    func testExportAllowsSiblingWithSharedPrefixAndExternalSymlinkParent() throws {
        let (parent, root, repository) = try fixture()
        let original = try Data(contentsOf: root.appendingPathComponent("state/current-trip.json"))
        let sibling = parent.appendingPathComponent("Data-copy")
        _ = try repository.export(to: sibling)
        XCTAssertEqual(try Data(contentsOf: sibling.appendingPathComponent("state/current-trip.json")), original)
        let outside = parent.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let alias = parent.appendingPathComponent("outside-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
        let exported = try repository.export(to: alias.appendingPathComponent("backup"))
        XCTAssertEqual(try Data(contentsOf: exported.appendingPathComponent("state/current-trip.json")), original)
    }
}
