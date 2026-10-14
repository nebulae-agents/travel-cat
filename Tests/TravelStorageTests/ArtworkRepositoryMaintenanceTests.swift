import Foundation
import XCTest
import TravelStorage

final class ArtworkRepositoryMaintenanceTests: XCTestCase {
    private let indexPath = "state/postcard-artwork-revisions.json"
    private let indexData = Data(#"{"schemaVersion":1,"revisions":[{"request":{"eventID":"11111111-1111-1111-1111-111111111111","narrativeHash":"original-narrative","originalRelativePath":"postcards/22222222-2222-2222-2222-222222222222/original.png","relativePath":"postcards/22222222-2222-2222-2222-222222222222/revised.png","contentHash":"accepted-pixels"},"tripID":"22222222-2222-2222-2222-222222222222","installedAt":"2026-10-14T00:00:00Z"}]}"#.utf8)

    private func fixture() throws -> (root: URL, repository: TravelRepository) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("artwork-maintenance-\(UUID().uuidString)")
        let repository = try TravelRepository(root: root.appendingPathComponent("data"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try indexData.write(to: repository.root.appendingPathComponent(indexPath))
        try Data("accepted artwork bytes".utf8).write(to: repository.root.appendingPathComponent("postcards/revised.png"))
        return (root, repository)
    }

    func testExportPreservesRevisionBindingsAndPixels() throws {
        let f = try fixture()
        let exported = try f.repository.export(to: f.root.appendingPathComponent("export"))
        XCTAssertEqual(try Data(contentsOf: exported.appendingPathComponent(indexPath)), indexData)
        XCTAssertEqual(try Data(contentsOf: exported.appendingPathComponent("postcards/revised.png")),
                       Data("accepted artwork bytes".utf8))
        XCTAssertEqual(try Data(contentsOf: f.repository.root.appendingPathComponent(indexPath)), indexData)
    }

    func testClearHistoryBacksUpBindingsAndRemovesActiveIndex() throws {
        let f = try fixture()
        let backup = try f.repository.clearHistory()
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent(indexPath)), indexData)
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("postcards/revised.png")),
                       Data("accepted artwork bytes".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.repository.root.appendingPathComponent(indexPath).path))
    }

    func testFailedHistoryResetRestoresRevisionIndex() throws {
        let f = try fixture()
        let journal = f.repository.root.appendingPathComponent("journal")
        let previousSnapshot = try Data(contentsOf: f.repository.root.appendingPathComponent("state/current-trip.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: journal.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: journal.path) }
        var backupPath: String?
        XCTAssertThrowsError(try f.repository.clearHistory()) { error in
            guard case let RepositoryError.clearHistoryResetFailed(path, _) = error else {
                return XCTFail("Expected reset failure after the backup, got \(error)")
            }
            backupPath = path
        }
        XCTAssertEqual(try Data(contentsOf: f.repository.root.appendingPathComponent(indexPath)), indexData)
        XCTAssertEqual(try Data(contentsOf: f.repository.root.appendingPathComponent("state/current-trip.json")), previousSnapshot)
        let backup = URL(fileURLWithPath: try XCTUnwrap(backupPath))
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent(indexPath)), indexData)
    }

    func testUnsafeRevisionIndexStopsBeforeChangingHistory() throws {
        let f = try fixture()
        let index = f.repository.root.appendingPathComponent(indexPath)
        let outside = f.root.appendingPathComponent("outside-index.json")
        try indexData.write(to: outside)
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createSymbolicLink(at: index, withDestinationURL: outside)
        let snapshot = try Data(contentsOf: f.repository.root.appendingPathComponent("state/current-trip.json"))
        XCTAssertThrowsError(try f.repository.export(to: f.root.appendingPathComponent("export")))
        XCTAssertThrowsError(try f.repository.clearHistory())
        XCTAssertEqual(try Data(contentsOf: outside), indexData)
        XCTAssertEqual(try Data(contentsOf: f.repository.root.appendingPathComponent("state/current-trip.json")), snapshot)
    }
}
