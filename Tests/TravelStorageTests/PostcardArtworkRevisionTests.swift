import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import XCTest
import TravelCore
@testable import TravelStorage

final class PostcardArtworkRevisionTests: XCTestCase {
    func testAcceptedRevisionSurvivesExportAndHistoryBackup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try TravelRepository(root: root.appendingPathComponent("data"))
        let trip = UUID()
        let old = "postcards/\(trip.uuidString.lowercased())/original.png"
        let revised = "postcards/\(trip.uuidString.lowercased())/revised.png"
        try image(repository.root.appendingPathComponent(old), red: 0.2)
        try image(repository.root.appendingPathComponent(revised), red: 0.7)
        let event = TripEvent.fixture(tripID: trip, phase: .postcardReady, place: "湖岸",
                                      postcardStatus: .ready, postcardRelativePath: old)
        let encoder = JSONEncoder.travelCat
        encoder.outputFormatting = [.sortedKeys]
        try (encoder.encode(event) + Data("\n".utf8))
            .write(to: repository.root.appendingPathComponent("journal/events.jsonl"))
        let pixels = try Data(contentsOf: repository.root.appendingPathComponent(revised))
        let store = try PostcardArtworkRevisionStore(root: repository.root)
        try store.install([.init(eventID: event.id, narrativeHash: try NarrativeHasher.hash(event),
            originalRelativePath: old, relativePath: revised,
            contentHash: SHA256.hash(data: pixels).map { String(format: "%02x", $0) }.joined())])

        let exported = try repository.export(to: root.appendingPathComponent("export"))
        let backup = try repository.clearHistory()
        for destination in [exported, backup] {
            let restored = try PostcardArtworkRevisionStore(root: destination)
            XCTAssertEqual(restored.resolvedPath(for: old), revised)
            XCTAssertEqual(restored.revisionData(for: old)?.data, pixels)
        }
        XCTAssertEqual(store.resolvedPath(for: old), old)
    }

    func testRevisionPreservesJournalOriginalAndRejectsChangedNarrativeOrPixels() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try TravelRepository(root: root)
        let trip = UUID()
        let old = "postcards/\(trip.uuidString.lowercased())/old.png"
        let new = "postcards/\(trip.uuidString.lowercased())/new.png"
        try image(root.appendingPathComponent(old), red: 0.2)
        try image(root.appendingPathComponent(new), red: 0.7)
        let event = TripEvent.fixture(tripID: trip, phase: .postcardReady, place: "湖岸", postcardStatus: .ready, postcardRelativePath: old)
        let encoder = JSONEncoder.travelCat
        encoder.outputFormatting = [.sortedKeys]
        let journal = try encoder.encode(event) + Data("\n".utf8)
        try journal.write(to: root.appendingPathComponent("journal/events.jsonl"))
        let original = try Data(contentsOf: root.appendingPathComponent(old))
        let data = try Data(contentsOf: root.appendingPathComponent(new))
        let store = try PostcardArtworkRevisionStore(root: root)
        func request(_ hash: String, path: String = new) -> PostcardArtworkRevisionRequest {
            .init(eventID: event.id, narrativeHash: hash, originalRelativePath: old,
                  relativePath: path, contentHash: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }
        XCTAssertThrowsError(try store.install([request(String(repeating: "0", count: 64))]))
        XCTAssertThrowsError(try store.install([request(try NarrativeHasher.hash(event), path: "../outside.png")]))
        try store.install([request(try NarrativeHasher.hash(event))])
        let accepted = try XCTUnwrap(store.revisionData(for: old))
        XCTAssertFalse(store.revisionIdentity(for: old).isEmpty)
        XCTAssertEqual(store.resolvedPath(for: old), new)
        XCTAssertEqual(try Data(contentsOf: repo.root.appendingPathComponent("journal/events.jsonl")), journal)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(old)), original)
        try Data("damaged".utf8).write(to: root.appendingPathComponent(new))
        XCTAssertEqual(accepted.data, data, "Accepted pixels are a snapshot, never a later reopen")
        XCTAssertEqual(store.resolvedPath(for: old), old)
        XCTAssertTrue(store.revisionIdentity(for: old).isEmpty, "A damaged revision must change the view task identity")
    }

    func testInvalidBatchDoesNotInstallAnyRevision() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try TravelRepository(root: root)
        let trip = UUID(), id = UUID()
        let old = "postcards/\(trip.uuidString.lowercased())/old.png"
        let first = "postcards/\(trip.uuidString.lowercased())/first.png"
        let next = "postcards/\(trip.uuidString.lowercased())/next.png"
        for path in [old, first, next] { try image(root.appendingPathComponent(path), red: 0.4) }
        let event = TripEvent.fixture(id: id, tripID: trip, phase: .postcardReady, postcardStatus: .ready, postcardRelativePath: old)
        let encoder = JSONEncoder.travelCat; encoder.outputFormatting = [.sortedKeys]
        try (encoder.encode(event) + Data("\n".utf8)).write(to: root.appendingPathComponent("journal/events.jsonl"))
        let hash = SHA256.hash(data: try Data(contentsOf: root.appendingPathComponent(first))).map { String(format: "%02x", $0) }.joined()
        let store = try PostcardArtworkRevisionStore(root: root)
        func request(_ path: String) throws -> PostcardArtworkRevisionRequest {
            .init(eventID: id, narrativeHash: try NarrativeHasher.hash(event), originalRelativePath: old, relativePath: path, contentHash: hash)
        }
        try store.install([request(first)])
        let index = root.appendingPathComponent("state/postcard-artwork-revisions.json")
        let before = try Data(contentsOf: index)
        XCTAssertThrowsError(try store.install([request(next), .init(eventID: UUID(), narrativeHash: "wrong",
            originalRelativePath: old, relativePath: "postcards/missing.png", contentHash: "wrong")]))
        XCTAssertEqual(try Data(contentsOf: index), before)
        XCTAssertEqual(store.resolvedPath(for: old), first)
    }

    func testStateSymlinkCannotWriteIndexOutsideRootAndLookupDoesNotBootstrap() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let emptyStore = try PostcardArtworkRevisionStore(root: root)
        XCTAssertEqual(emptyStore.resolvedPath(for: "postcards/missing.png"), "postcards/missing.png")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        _ = try TravelRepository(root: root)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideIndex = outside.appendingPathComponent("postcard-artwork-revisions.json")
        let outsideData = Data("{\"schemaVersion\":1,\"revisions\":[]}".utf8)
        try outsideData.write(to: outsideIndex)
        try FileManager.default.removeItem(at: root.appendingPathComponent("state"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("state"), withDestinationURL: outside)
        XCTAssertThrowsError(try emptyStore.install([.init(eventID: UUID(), narrativeHash: "wrong",
            originalRelativePath: "old", relativePath: "new", contentHash: "wrong")])) { error in
            guard case RepositoryError.unsafePostcardPath = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: outsideIndex), outsideData)
    }

    private func image(_ url: URL, red: CGFloat) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 1152, height: 768, bitsPerComponent: 8,
            bytesPerRow: 1152 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: red, green: 0.3, blue: 0.4, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 1152, height: 768))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }
}
