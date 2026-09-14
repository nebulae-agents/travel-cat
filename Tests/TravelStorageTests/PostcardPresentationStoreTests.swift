import Foundation
import CoreGraphics
import ImageIO
import CryptoKit
import TravelCore
import XCTest
@testable import TravelStorage

final class PostcardPresentationStoreTests: XCTestCase {
    func testRoundTripIsImmutableAndBindsExactQuote() throws {
        let (root, event, path) = try fixture()
        let store = PostcardPresentationStore(root: root)
        let original = try Data(contentsOf: root.appendingPathComponent(path))
        let ref = try prepare(store, event, path)
        let loaded = try store.load(reference: ref, event: event, expectedSourceRelativePath: path)
        XCTAssertEqual(loaded.manifest.quote, event.mood.quote)
        XCTAssertEqual(loaded.sourceData, original)
        XCTAssertEqual(loaded.landscapeData, original)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), original)
        XCTAssertNotEqual(try prepare(store, event, path), ref)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("state").path))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
        var mood = try XCTUnwrap(object["mood"] as? [String: Any]); mood["quote"] = "changed"; object["mood"] = mood
        let changed = try JSONDecoder().decode(TripEvent.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try store.load(reference: ref, event: changed, expectedSourceRelativePath: path))
        XCTAssertThrowsError(try store.load(reference: ref, event: event, expectedSourceRelativePath: "postcards/../bad.png"))
    }

    func testGeneratedHandwritingRequiresVisibleInkAndTransparency() throws {
        let (root, event, path) = try fixture(); let store = PostcardPresentationStore(root: root)
        for kind in [0, 1, 3] {
            XCTAssertThrowsError(try prepare(store, event, path, handwriting: .generated(try png(width: 16, height: 16, alpha: kind))))
        }
        let ref = try prepare(store, event, path, handwriting: .generated(try png(width: 16, height: 16, alpha: 2)))
        XCTAssertNotNil(try store.load(reference: ref, event: event, expectedSourceRelativePath: path).handwritingData)
    }

    func testCorruptionAndUnsafeFilesRejectWithoutDamagingPriorReference() throws {
        let (root, event, path) = try fixture(); let store = PostcardPresentationStore(root: root)
        let ref = try prepare(store, event, path)
        XCTAssertThrowsError(try store.prepare(event: event, expectedSourceRelativePath: path, derivedLandscapeData: Data([1]), handwriting: .localFallback(.generationFailed), placement: rect, styleVersion: "v1"))
        _ = try store.load(reference: ref, event: event, expectedSourceRelativePath: path)
        let source = root.appendingPathComponent(path)
        let copy = root.appendingPathComponent("copy.png")
        try FileManager.default.linkItem(at: source, to: copy)
        XCTAssertThrowsError(try store.load(reference: ref, event: event, expectedSourceRelativePath: path))
        try FileManager.default.removeItem(at: copy)
        try Data([0]).write(to: source)
        XCTAssertThrowsError(try store.load(reference: ref, event: event, expectedSourceRelativePath: path))
    }

    private var rect: PostcardPresentationRect { .init(x: 0.1, y: 0.1, width: 0.4, height: 0.2) }
    func testLegacySourcePathRetainsExactStoredBinding() throws {
        let (root, original, path) = try fixture()
        let legacy = "legacy/old.png"
        try FileManager.default.createDirectory(at: root.appendingPathComponent("postcards/legacy"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: root.appendingPathComponent(path), to: root.appendingPathComponent("postcards/" + legacy))
        var event = original; event.postcardRelativePath = legacy
        let store = PostcardPresentationStore(root: root)
        let ref = try prepare(store, event, legacy)
        XCTAssertEqual(try store.load(reference: ref, event: event, expectedSourceRelativePath: legacy).manifest.source.relativePath, legacy)
    }

    func testStrictManifestVersionUnknownDuplicateKeysAndInvalidRect() throws {
        let (root, event, path) = try fixture(); let store = PostcardPresentationStore(root: root)
        let ref = try prepare(store, event, path)
        let bytes = try Data(contentsOf: root.appendingPathComponent(ref.relativePath))
        for transform: (inout [String: Any]) -> Void in [
            { $0["schemaVersion"] = 2 }, { $0["unexpected"] = true },
            { $0["placement"] = ["x": 0, "y": 0, "width": 2, "height": 1] },
            { $0["source"] = ["relativePath": "../escape.png", "sha256": "a"] },
            { $0["eventID"] = UUID().uuidString }, { $0["quoteSHA256"] = String(repeating: "0", count: 64) }
        ] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any]); transform(&object)
            let bad = try JSONSerialization.data(withJSONObject: object)
            let changed = try writeManifest(bad, root: root, ref: ref)
            XCTAssertThrowsError(try store.load(reference: changed, event: event, expectedSourceRelativePath: path))
        }
        let duplicate = Data(("{\"schemaVersion\":1," + String(decoding: bytes.dropFirst(), as: UTF8.self)).utf8)
        XCTAssertThrowsError(try store.load(reference: writeManifest(duplicate, root: root, ref: ref), event: event, expectedSourceRelativePath: path))
        XCTAssertThrowsError(try store.prepare(event: event, expectedSourceRelativePath: path, handwriting: .localFallback(.unavailable), placement: .init(x: .nan, y: 0, width: 1, height: 1), styleVersion: "v1"))
    }

    func testSymlinkParentsLeavesAndFinalRevalidationRejectReplacement() throws {
        let (root, event, path) = try fixture(); let store = PostcardPresentationStore(root: root)
        let ref = try prepare(store, event, path)
        let source = root.appendingPathComponent(path)
        let copy = root.appendingPathComponent("saved.png")
        try FileManager.default.copyItem(at: source, to: copy)
        try store.withValidatedPresentation(reference: ref, event: event, expectedSourceRelativePath: path) { _, revalidate in
            try FileManager.default.removeItem(at: source)
            try FileManager.default.createSymbolicLink(at: source, withDestinationURL: copy)
            XCTAssertThrowsError(try revalidate())
        }
        XCTAssertThrowsError(try store.load(reference: ref, event: event, expectedSourceRelativePath: path))
        try FileManager.default.removeItem(at: source); try FileManager.default.copyItem(at: copy, to: source)
        let directory = source.deletingLastPathComponent(); let moved = root.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: directory, to: moved)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: moved)
        XCTAssertThrowsError(try store.load(reference: ref, event: event, expectedSourceRelativePath: path))
    }

    func testBoundedFilesAndPendingCanonicalSource() throws {
        let (root, original, path) = try fixture(); let store = PostcardPresentationStore(root: root)
        var event = original; event.postcardStatus = .pendingImage; event.postcardRelativePath = nil
        let ref = try prepare(store, event, path)
        _ = try store.load(reference: ref, event: event, expectedSourceRelativePath: path)
        XCTAssertThrowsError(try prepare(store, event, "legacy/old.png"))
        XCTAssertThrowsError(try store.load(reference: .init(relativePath: "postcards/../escape.json", sha256: ref.sha256), event: event, expectedSourceRelativePath: path))
        let manifest = root.appendingPathComponent(ref.relativePath)
        try Data(repeating: 32, count: 65_537).write(to: manifest)
        XCTAssertThrowsError(try store.load(reference: ref, event: event, expectedSourceRelativePath: path))
        let source = root.appendingPathComponent(path)
        let file = try FileHandle(forWritingTo: source); try file.truncate(atOffset: UInt64(PostcardPresentationStore.maximumImageBytes + 1)); try file.close()
        XCTAssertThrowsError(try prepare(store, event, path))
    }

    private func writeManifest(_ data: Data, root: URL, ref: PostcardPresentationReference) throws -> PostcardPresentationReference {
        try data.write(to: root.appendingPathComponent(ref.relativePath))
        return .init(relativePath: ref.relativePath, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    func testDerivedLandscapeSeparateOriginalAndFormatDimensionsAreChecked() throws {
        let (root, event, path) = try fixture(); let store = PostcardPresentationStore(root: root)
        let original = try Data(contentsOf: root.appendingPathComponent(path))
        let ref = try store.prepare(event: event, expectedSourceRelativePath: path, derivedLandscapeData: original, handwriting: .localFallback(.unavailable), placement: rect, styleVersion: "v1")
        let value = try store.load(reference: ref, event: event, expectedSourceRelativePath: path)
        XCTAssertNotEqual(value.manifest.landscape.relativePath, path)
        XCTAssertEqual(value.landscapeData, original)
        for bad in [try png(width: 16, height: 16, alpha: 1), try png(width: 32769, height: 1, alpha: 1), Data(original.prefix(original.count / 2))] {
            XCTAssertThrowsError(try store.prepare(event: event, expectedSourceRelativePath: path, derivedLandscapeData: bad, handwriting: .localFallback(.unavailable), placement: rect, styleVersion: "v1"))
        }
        var webp = event
        let fakePath = String(path.dropLast(3)) + "webp"
        webp.postcardRelativePath = fakePath
        try original.write(to: root.appendingPathComponent(fakePath))
        XCTAssertThrowsError(try prepare(store, webp, fakePath))
        try png(width: 1536, height: 1024, alpha: 1).write(to: root.appendingPathComponent(path))
        XCTAssertThrowsError(try store.load(reference: ref, event: event, expectedSourceRelativePath: path))
    }

    func testQuoteBindingRejectsCanonicallyEquivalentButDifferentUTF8() throws {
        let (root, original, path) = try fixture()
        let store = PostcardPresentationStore(root: root)
        for (quote, tampered) in [("caf\u{00E9}", "cafe\u{0301}"), ("cafe\u{0301}", "caf\u{00E9}")] {
            var eventObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
            var mood = try XCTUnwrap(eventObject["mood"] as? [String: Any])
            mood["quote"] = quote; eventObject["mood"] = mood
            let event = try JSONDecoder().decode(TripEvent.self, from: JSONSerialization.data(withJSONObject: eventObject))
            let reference = try prepare(store, event, path)
            let bytes = try Data(contentsOf: root.appendingPathComponent(reference.relativePath))
            var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            manifest["quote"] = tampered
            let changed = try writeManifest(JSONSerialization.data(withJSONObject: manifest), root: root, ref: reference)
            XCTAssertThrowsError(try store.load(reference: changed, event: event, expectedSourceRelativePath: path))
        }
    }
    private func prepare(_ store: PostcardPresentationStore, _ event: TripEvent, _ path: String, handwriting: PostcardPresentationStore.HandwritingInput = .localFallback(.generationFailed)) throws -> PostcardPresentationReference {
        try store.prepare(event: event, expectedSourceRelativePath: path, derivedLandscapeData: nil, handwriting: handwriting, placement: rect, styleVersion: "v1")
    }
    private func fixture() throws -> (URL, TripEvent, String) {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        let trip = UUID(); let path = "postcards/\(trip.uuidString.lowercased())/original.png"
        try FileManager.default.createDirectory(at: root.appendingPathComponent(path).deletingLastPathComponent(), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try png(width: 1152, height: 768, alpha: 1).write(to: root.appendingPathComponent(path))
        return (root, TripEvent(id: UUID(), tripID: trip, previousEventID: nil, occurredAt: Date(), phase: .postcardReady, location: nil, transport: nil, summary: "summary", mood: Mood(level: 4, label: "calm", quote: " exact\n中文 "), continuityReferences: [], openHook: nil, consumedItemID: nil, postcardStatus: .ready, postcardRelativePath: path), path)
    }
    private func png(width: Int, height: Int, alpha: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        if alpha > 0 {
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(alpha == 2 ? CGRect(x: 2, y: 2, width: width - 4, height: height - 4) : CGRect(x: 0, y: 0, width: width, height: height))
            if alpha == 3 { context.clear(CGRect(x: 0, y: 0, width: 1, height: 1)) }
        }
        let data = NSMutableData(); let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(context.makeImage()), nil); XCTAssertTrue(CGImageDestinationFinalize(dest)); return data as Data
    }
}
