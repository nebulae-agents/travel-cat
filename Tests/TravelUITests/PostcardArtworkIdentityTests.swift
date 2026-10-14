import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import XCTest
import TravelCore
import TravelStorage
@testable import TravelUI

final class PostcardArtworkIdentityTests: XCTestCase {
    func testDamagedRevisionChangesStillInvalidateTheViewWithoutValidatingPixels() throws {
        let fixture = try revisionFixture(data: sourcePhoto())
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data("broken".utf8).write(to: fixture.revision)
        let first = PostcardArtworkLoadIdentity.requestID(event: fixture.event, rootURL: fixture.root)
        try Data("still broken".utf8).write(to: fixture.revision)
        let second = PostcardArtworkLoadIdentity.requestID(event: fixture.event, rootURL: fixture.root)
        XCTAssertNotEqual(first, second, "A change token must track damaged files too; full validation belongs to loading")
        XCTAssertEqual(try PostcardImageLoader.loadData(relativePath: fixture.event.postcardRelativePath!, rootURL: fixture.root), fixture.data)
    }

    func testSameSizeDamagedRewriteWithRestoredModificationDateInvalidatesTheView() throws {
        let fixture = try revisionFixture(data: sourcePhoto())
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let date = Date(timeIntervalSince1970: 100)
        try Data("broken-a".utf8).write(to: fixture.revision)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: fixture.revision.path)
        let first = PostcardArtworkLoadIdentity.requestID(event: fixture.event, rootURL: fixture.root)
        try Data("broken-b".utf8).write(to: fixture.revision)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: fixture.revision.path)
        let second = PostcardArtworkLoadIdentity.requestID(event: fixture.event, rootURL: fixture.root)
        XCTAssertNotEqual(first, second, "File change time must protect same-size rewrites with restored mtime")
        XCTAssertEqual(try PostcardImageLoader.loadData(relativePath: fixture.event.postcardRelativePath!, rootURL: fixture.root), fixture.data)
    }

    func testOnlyFullyValidatedRevisionBytesCarryAReusableHash() throws {
        let fixture = try revisionFixture(data: sourcePhoto())
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let relativePath = try XCTUnwrap(fixture.event.postcardRelativePath)
        let accepted = try PostcardImageLoader.loadArtworkData(relativePath: relativePath, rootURL: fixture.root)
        XCTAssertEqual(accepted.data, fixture.data)
        XCTAssertEqual(accepted.validatedContentHash,
            SHA256.hash(data: accepted.data).map { String(format: "%02x", $0) }.joined())
        XCTAssertThrowsError(try PostcardImageLoader.loadArtworkData(relativePath: relativePath,
            rootURL: fixture.root, maximumBytes: 1)) { error in
            XCTAssertEqual(error as? PostcardImageLoaderError, .tooLarge)
        }
        try Data("broken".utf8).write(to: fixture.revision)
        let fallback = try PostcardImageLoader.loadArtworkData(relativePath: relativePath, rootURL: fixture.root)
        XCTAssertEqual(fallback.data, fixture.data)
        XCTAssertNil(fallback.validatedContentHash, "The original bytes must receive their own hash in the image cache")
    }

    func testIsolatedRevisionIdentityBenchmark() throws {
        guard let photoPath = ProcessInfo.processInfo.environment["TRAVELCAT_REVISION_BENCHMARK_PHOTO"] else {
            throw XCTSkip("Opt-in isolated artwork identity timing")
        }
        let fixture = try revisionFixture(data: Data(contentsOf: URL(fileURLWithPath: photoPath)))
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let iterations = 40
        let clock = ContinuousClock()
        var lastID = ""
        let duration = clock.measure {
            for _ in 0..<iterations {
                lastID = PostcardArtworkLoadIdentity.requestID(event: fixture.event, rootURL: fixture.root)
            }
        }
        XCTAssertFalse(lastID.isEmpty)
        print("ARTWORK_IDENTITY_BENCHMARK iterations=\(iterations) bytes=\(fixture.data.count) duration=\(duration)")
    }

    private func revisionFixture(data: Data) throws -> (root: URL, event: TripEvent, revision: URL, data: Data) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        _ = try TravelRepository(root: root)
        let tripID = UUID()
        let directory = "postcards/\(tripID.uuidString.lowercased())"
        let originalPath = directory + "/original.png"
        let revisionPath = directory + "/revision.png"
        try FileManager.default.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        try data.write(to: root.appendingPathComponent(originalPath))
        let revision = root.appendingPathComponent(revisionPath)
        try data.write(to: revision)
        let event = TripEvent(id: UUID(), tripID: tripID, previousEventID: nil,
            occurredAt: Date(timeIntervalSince1970: 100), phase: .postcardReady,
            location: nil, transport: nil, summary: "湖边的记忆", mood: Mood(level: 0, label: "平静", quote: "慢慢看风景。"),
            continuityReferences: [], openHook: nil, consumedItemID: nil, postcardStatus: .ready,
            postcardRelativePath: originalPath)
        let encoder = JSONEncoder.travelCat
        encoder.outputFormatting = [.sortedKeys]
        try (encoder.encode(event) + Data("\n".utf8)).write(to: root.appendingPathComponent("journal/events.jsonl"))
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let store = try PostcardArtworkRevisionStore(root: root)
        let candidate = try XCTUnwrap(store.candidates().first)
        try store.install([.init(eventID: event.id, narrativeHash: candidate.narrativeHash,
            originalRelativePath: originalPath, relativePath: revisionPath, contentHash: hash)])
        return (root, event, revision, data)
    }

    private func sourcePhoto() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1152, height: 768, bitsPerComponent: 8,
            bytesPerRow: 1152 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1152, height: 768))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
