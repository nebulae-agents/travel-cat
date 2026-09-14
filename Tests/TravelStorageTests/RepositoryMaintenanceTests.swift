import Foundation
import XCTest
import TravelCore
@testable import TravelStorage

final class RepositoryMaintenanceTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RepositoryMaintenanceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testExportIncludesStableDataAndRejectsSymlinkedPostcards() throws {
        let root = try temporaryDirectory()
        let repository = try TravelRepository(root: root)
        try TravelSettingsStore(root: root).save(.init(mode: .fast))
        try Data("image".utf8).write(to: root.appendingPathComponent("postcards/card.webp"))
        try Data("partial".utf8).write(to: root.appendingPathComponent("postcards/.card.tmp"))
        try Data("temp".utf8).write(to: root.appendingPathComponent("state/.active.tmp"))
        let destination = try temporaryDirectory().appendingPathComponent("My Travel Cat Export.custom name")

        let exported = try repository.export(to: destination)
        XCTAssertEqual(exported.standardizedFileURL, destination.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.appendingPathComponent("state/current-trip.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.appendingPathComponent("state/settings.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.appendingPathComponent("journal/events.jsonl").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.appendingPathComponent("postcards/card.webp").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: exported.appendingPathComponent("postcards/.card.tmp").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: exported.appendingPathComponent("state/.active.tmp").path))

        let outside = destination.deletingLastPathComponent().appendingPathComponent("outside")
        try Data("secret".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("postcards/leak"),
            withDestinationURL: outside
        )
        let failedDestination = try temporaryDirectory().appendingPathComponent("failed exact export")
        XCTAssertThrowsError(try repository.export(to: failedDestination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: failedDestination.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(
            atPath: failedDestination.deletingLastPathComponent().path
        ).contains(where: { $0.contains("export.tmp") }))

        let existing = try temporaryDirectory().appendingPathComponent("existing export")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: existing.appendingPathComponent("marker"))
        XCTAssertThrowsError(try repository.export(to: existing))
        XCTAssertEqual(try Data(contentsOf: existing.appendingPathComponent("marker")), Data("keep".utf8))
    }

    func testClearHistoryPreservesSettingsAndCreatesRecoverableBackup() throws {
        let root = try temporaryDirectory()
        let repository = try TravelRepository(root: root)
        let event = TripEvent.fixture()
        try repository.publish(event: event, next: .fixture(stateVersion: 1, tripID: event.tripID, lastEventID: event.id))
        try Data("image".utf8).write(to: root.appendingPathComponent("postcards/card.webp"))
        let settings = TravelSettings(mode: .fast, quietStart: 21, quietEnd: 6)
        try TravelSettingsStore(root: root).save(settings)

        let backup = try repository.clearHistory(now: Date(timeIntervalSince1970: 42))

        XCTAssertEqual(try repository.events(), [])
        XCTAssertEqual(try repository.loadSnapshot().phase, .resting)
        XCTAssertEqual(try TravelSettingsStore(root: root).load(), settings)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.appendingPathComponent("state/current-trip.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.appendingPathComponent("postcards/card.webp").path))
    }

    func testClearHistoryCopyFailureLeavesSourceUnchangedAndNoFinalBackup() throws {
        let root = try temporaryDirectory()
        let repository = try TravelRepository(root: root)
        let before = try repository.loadContents()
        let outside = root.appendingPathComponent("outside")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("postcards/unsafe"),
            withDestinationURL: outside
        )

        XCTAssertThrowsError(try repository.clearHistory(now: Date(timeIntervalSince1970: 42)))
        XCTAssertEqual(try repository.loadContents(), before)
        let backups = root.appendingPathComponent("backups")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: backups.path)) ?? []
        XCTAssertFalse(names.contains(where: { $0.hasPrefix("cleared-") || $0.hasPrefix(".") }))
    }

    func testCharacterTreeLinkBlocksExportAndClearWithoutPublishingOrChangingLiveData() throws {
        let root = try temporaryDirectory()
        let repository = try TravelRepository(root: root)
        let beforeSnapshot = try Data(contentsOf: root.appendingPathComponent("state/current-trip.json"))
        let beforeJournal = try Data(contentsOf: root.appendingPathComponent("journal/events.jsonl"))
        let missingOutside = root.appendingPathComponent("missing-character")
        let characters = root.appendingPathComponent("characters/custom/revision/assets")
        try FileManager.default.createDirectory(at: characters, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: characters.appendingPathComponent("unsafe.webp"),
            withDestinationURL: missingOutside
        )

        let destination = try temporaryDirectory().appendingPathComponent("failed-character-export")
        XCTAssertThrowsError(try repository.export(to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertThrowsError(try repository.clearHistory(now: Date(timeIntervalSince1970: 42)))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("state/current-trip.json")), beforeSnapshot)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("journal/events.jsonl")), beforeJournal)
        let backupNames = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("backups").path)) ?? []
        XCTAssertFalse(backupNames.contains(where: { $0.hasPrefix("cleared-") || $0.hasPrefix(".") }))
    }

    func testDanglingStateDirectoryLinkBlocksExportWithoutPublishingFinalDirectory() throws {
        let root = try temporaryDirectory()
        let repository = try TravelRepository(root: root)
        let state = root.appendingPathComponent("state")
        try FileManager.default.removeItem(at: state)
        try FileManager.default.createSymbolicLink(
            at: state,
            withDestinationURL: root.appendingPathComponent("missing-state")
        )
        let destinationParent = try temporaryDirectory()
        let destination = destinationParent.appendingPathComponent("failed-state-export")

        XCTAssertThrowsError(try repository.export(to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: destinationParent.path)
            .contains(where: { $0.contains("export.tmp") }))
    }

    func testExistingStateDirectoryLinkBlocksExportWithoutPublishingFinalDirectory() throws {
        let root = try temporaryDirectory()
        let repository = try TravelRepository(root: root)
        let state = root.appendingPathComponent("state")
        try TravelSettingsStore(root: root).save(.init(mode: .fast))
        try Data("retries".utf8).write(to: state.appendingPathComponent("image-retries.json"))
        try Data("active".utf8).write(to: state.appendingPathComponent("active-character.json"))
        try Data("frozen".utf8).write(to: state.appendingPathComponent("frozen-character.json"))
        let external = try temporaryDirectory().appendingPathComponent("external-state")
        try FileManager.default.moveItem(at: state, to: external)
        try FileManager.default.createSymbolicLink(at: state, withDestinationURL: external)
        let destinationParent = try temporaryDirectory()
        let destination = destinationParent.appendingPathComponent("failed-linked-state-export")

        XCTAssertThrowsError(try repository.export(to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: destinationParent.path)
            .contains(where: { $0.contains("export.tmp") }))
    }
}
