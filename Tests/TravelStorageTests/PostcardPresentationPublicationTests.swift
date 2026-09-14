import Foundation
import CoreGraphics
import ImageIO
import CryptoKit
import TravelCore
import XCTest
@testable import TravelStorage

final class PostcardPresentationPublicationTests: XCTestCase {
    func testLegacyReadyConversionWithNilCASPreservesOriginalReplay() throws {
        let (repo, work, path) = try fixture()
        let result = envelope(work, path, nil)
        _ = try repo.markImage(result, mode: .fast)
        let event = try XCTUnwrap(repo.events().first)
        let reference = try prepare(repo, event, path)
        let original = try Data(contentsOf: repo.root.appendingPathComponent(path))
        let journal = try Data(contentsOf: repo.root.appendingPathComponent("journal/events.jsonl"))
        let snapshot = try Data(contentsOf: repo.snapshotURL)
        let retryBefore = try XCTUnwrap(repo.imageRetry(for: event.id))
        XCTAssertEqual(try repo.publishPresentation(reference, for: event.id, expectedSourceSHA256: digest(original), expectedPresentationSHA256: nil), reference)
        var expectedRetry = retryBefore
        expectedRetry.currentPresentation = reference
        XCTAssertEqual(try repo.imageRetry(for: event.id), expectedRetry)
        XCTAssertEqual(try Data(contentsOf: repo.root.appendingPathComponent("journal/events.jsonl")), journal)
        XCTAssertEqual(try Data(contentsOf: repo.snapshotURL), snapshot)
        XCTAssertThrowsError(try repo.publishPresentation(reference, for: event.id, expectedSourceSHA256: digest(original), expectedPresentationSHA256: nil))
        XCTAssertEqual(try repo.markImage(result, mode: .fast).status, .ready)
        XCTAssertEqual(try repo.loadContents().presentationReferences[event.id], reference)
        XCTAssertEqual(try Data(contentsOf: repo.root.appendingPathComponent(path)), original)
    }

    func testCancelledConversionNeverPublishes() async throws {
        let (repo, work, path) = try fixture()
        _ = try repo.markImage(envelope(work, path, nil), mode: .fast)
        let event = try XCTUnwrap(repo.events().first)
        let reference = try prepare(repo, event, path)
        let source = digest(try Data(contentsOf: repo.root.appendingPathComponent(path)))
        repo.imageValidationHook = { withUnsafeCurrentTask { $0?.cancel() } }
        let task = Task {
            try repo.publishPresentation(reference, for: event.id, expectedSourceSHA256: source, expectedPresentationSHA256: nil)
        }
        do { _ = try await task.value; XCTFail("cancelled conversion published") }
        catch is CancellationError { }
        XCTAssertTrue(try repo.loadContents().presentationReferences.isEmpty)
    }

    func testCancelledReadyKeepsLeaseAndDoesNotActivatePresentation() async throws {
        let (repo, work, path) = try fixture()
        let result = envelope(work, path, try prepare(repo, work.event, path))
        let retry = try repo.imageRetry(for: work.event.id)
        let journal = try Data(contentsOf: repo.root.appendingPathComponent("journal/events.jsonl"))
        repo.imageValidationHook = { withUnsafeCurrentTask { $0?.cancel() } }
        let task = Task { try repo.markImage(result, mode: .fast) }
        do { _ = try await task.value; XCTFail("cancelled ready published") }
        catch is CancellationError { }
        XCTAssertEqual(try repo.imageRetry(for: work.event.id), retry)
        XCTAssertTrue(try repo.loadContents().presentationReferences.isEmpty)
        XCTAssertEqual(try repo.events().first?.postcardStatus, .pendingImage)
        XCTAssertEqual(try Data(contentsOf: repo.root.appendingPathComponent("journal/events.jsonl")), journal)
    }

    func testCorruptOptionalReadyLandscapeStillAllowsOpenAndContentsRead() throws {
        let (repo, work, path) = try fixture()
        let pointer = try XCTUnwrap(realpath(repo.root.path, nil))
        defer { free(pointer) }
        let store = PostcardPresentationStore(root: URL(fileURLWithPath: String(cString: pointer)))
        let source = try Data(contentsOf: repo.root.appendingPathComponent(path))
        let reference = try store.prepare(event: work.event, expectedSourceRelativePath: path, derivedLandscapeData: source, handwriting: .localFallback(.unavailable), placement: .init(x: 0.1, y: 0.1, width: 0.4, height: 0.2), styleVersion: "derived")
        _ = try repo.markImage(envelope(work, path, reference), mode: .fast)
        let event = try XCTUnwrap(repo.events().first)
        let manifest = try JSONDecoder.travelCat.decode(PostcardPresentationManifest.self, from: Data(contentsOf: repo.root.appendingPathComponent(reference.relativePath)))
        XCTAssertNotEqual(manifest.landscape.relativePath, path)
        try Data([0]).write(to: repo.root.appendingPathComponent(manifest.landscape.relativePath))
        let contents = try TravelRepository(root: repo.root).loadContents()
        XCTAssertEqual(contents.events.first, event)
        XCTAssertEqual(try Data(contentsOf: repo.root.appendingPathComponent(path)), source)
    }

    func testReferenceValidationAndRetryInvariants() throws {
        let (repo, work, path) = try fixture()
        let malformed = PostcardPresentationReference(relativePath: "postcards/a/b.json", sha256: "BAD")
        XCTAssertThrowsError(try repo.markImage(envelope(work, path, malformed), mode: .fast))
        let valid = try prepare(repo, work.event, path)
        let failed = ImageResultEnvelope(eventId: work.event.id, status: .failed, attemptedAt: Date(), relativePath: nil, reason: "failed", attemptToken: work.attemptToken, attemptCount: 0, publishedNarrativeHash: work.publishedNarrativeHash, presentation: valid)
        XCTAssertThrowsError(try repo.markImage(failed, mode: .fast))
        XCTAssertThrowsError(try ImageResultEnvelope.decode(JSONEncoder.travelCat.encode(failed)))
        let retry = ImageRetry(attemptCount: 0, retryAt: nil, publishedNarrativeHash: work.publishedNarrativeHash)
        let bytes = try JSONEncoder.travelCat.encode(retry)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertNil(json["terminalPresentation"]); XCTAssertNil(json["currentPresentation"])
        var badRetry = retry; badRetry.currentPresentation = valid
        XCTAssertThrowsError(try ImageRetryStore(entries: [work.event.id.uuidString.lowercased(): badRetry]).validated())
        XCTAssertEqual(try repo.imageRetry(for: work.event.id)?.activeAttemptToken, work.attemptToken)
    }

    func testConcurrentIdenticalReadySubmissionReplays() throws {
        let (repo, work, path) = try fixture()
        let result = envelope(work, path, try prepare(repo, work.event, path))
        repo.imageValidationHook = {
            repo.imageValidationHook = nil
            do { _ = try repo.markImage(result, mode: .fast) }
            catch { XCTFail("nested publication failed: \(error)") }
        }
        XCTAssertEqual(try repo.markImage(result, mode: .fast).status, .ready)
    }

    func testCrashRecoveryValidatesInitialPresentationAndRejectsCorruption() throws {
        for corrupt in [false, true] {
            let (repo, work, path) = try fixture()
            let reference = try prepare(repo, work.event, path)
            let result = envelope(work, path, reference)
            _ = try repo.markImage(result, mode: .fast)
            let journal = repo.root.appendingPathComponent("journal/events.jsonl")
            let encoder = JSONEncoder.travelCat; encoder.outputFormatting = [.sortedKeys]
            var pending = try encoder.encode(work.event); pending.append(10)
            try pending.write(to: journal, options: .atomic)
            if corrupt {
                try Data([0]).write(to: repo.root.appendingPathComponent(reference.relativePath))
                XCTAssertThrowsError(try TravelRepository(root: repo.root))
                XCTAssertEqual(try Data(contentsOf: journal), pending)
            } else {
                let recovered = try TravelRepository(root: repo.root)
                XCTAssertEqual(try recovered.loadContents().presentationReferences[work.event.id], reference)
                XCTAssertEqual(try recovered.markImage(result, mode: .fast).status, .ready)
            }
        }
    }

    func testPendingRecoveryCannotActivateConversionOverride() throws {
        let (repo, work, path) = try fixture()
        let reference = try prepare(repo, work.event, path)
        _ = try repo.markImage(envelope(work, path, reference), mode: .fast)
        let retryURL = repo.root.appendingPathComponent("state/image-retries.json")
        var store = try JSONDecoder.travelCat.decode(ImageRetryStore.self, from: Data(contentsOf: retryURL))
        store.entries[work.event.id.uuidString.lowercased()]?.currentPresentation = reference
        try JSONEncoder.travelCat.encode(store).write(to: retryURL, options: .atomic)
        let encoder = JSONEncoder.travelCat; encoder.outputFormatting = [.sortedKeys]
        var journal = try encoder.encode(work.event); journal.append(10)
        try journal.write(to: repo.root.appendingPathComponent("journal/events.jsonl"), options: .atomic)
        XCTAssertThrowsError(try TravelRepository(root: repo.root))
    }

    func testCrossEventAndStaleQuoteReferencesRejectWithoutConsumingLease() throws {
        let (repo, work, path) = try fixture()
        let reference = try prepare(repo, work.event, path)
        for key in ["eventID", "quote", "source"] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: repo.root.appendingPathComponent(reference.relativePath))) as? [String: Any])
            if key == "eventID" { object[key] = UUID().uuidString }
            if key == "quote" { object[key] = "stale" }
            if key == "source" {
                var source = try XCTUnwrap(object[key] as? [String: Any]); source["sha256"] = String(repeating: "0", count: 64); object[key] = source
            }
            let data = try JSONSerialization.data(withJSONObject: object)
            let changedPath = "postcards/\(work.event.tripID.uuidString.lowercased())/\(UUID().uuidString.lowercased()).json"
            try data.write(to: repo.root.appendingPathComponent(changedPath))
            XCTAssertThrowsError(try repo.markImage(envelope(work, path, .init(relativePath: changedPath, sha256: digest(data))), mode: .fast))
            XCTAssertEqual(try repo.imageRetry(for: work.event.id)?.activeAttemptToken, work.attemptToken)
        }
    }

    func testCASRejectsWrongSourceAndReplacementAndKeepsJournalBytes() throws {
        let (repo, work, path) = try fixture()
        _ = try repo.markImage(envelope(work, path, nil), mode: .fast)
        let event = try XCTUnwrap(repo.events().first)
        let reference = try prepare(repo, event, path)
        let journal = try Data(contentsOf: repo.root.appendingPathComponent("journal/events.jsonl"))
        let snapshot = try Data(contentsOf: repo.snapshotURL)
        let source = digest(try Data(contentsOf: repo.root.appendingPathComponent(path)))
        XCTAssertThrowsError(try repo.publishPresentation(reference, for: event.id, expectedSourceSHA256: String(repeating: "0", count: 64), expectedPresentationSHA256: nil))
        repo.imageValidationHook = { try! Data([0]).write(to: repo.root.appendingPathComponent(reference.relativePath), options: .atomic) }
        XCTAssertThrowsError(try repo.publishPresentation(reference, for: event.id, expectedSourceSHA256: source, expectedPresentationSHA256: nil))
        XCTAssertTrue(try repo.loadContents().presentationReferences.isEmpty)
        XCTAssertEqual(try Data(contentsOf: repo.root.appendingPathComponent("journal/events.jsonl")), journal)
        XCTAssertEqual(try Data(contentsOf: repo.snapshotURL), snapshot)
    }

    func testReadyRejectsExpiredLease() throws {
        let (repo, work, path) = try fixture()
        let retryURL = repo.root.appendingPathComponent("state/image-retries.json")
        var store = try JSONDecoder.travelCat.decode(ImageRetryStore.self, from: Data(contentsOf: retryURL))
        store.entries[work.event.id.uuidString.lowercased()]?.leaseExpiresAt = .distantPast
        try JSONEncoder.travelCat.encode(store).write(to: retryURL, options: .atomic)
        XCTAssertThrowsError(try repo.markImage(envelope(work, path, nil), mode: .fast))
    }

    func testSchemaIncludesStrictOptionalReference() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Automation/schemas/image-result.schema.json"))) as? [String: Any])
        let properties = try XCTUnwrap(json["properties"] as? [String: Any])
        let presentation = try XCTUnwrap(properties["presentation"] as? [String: Any])
        XCTAssertEqual(presentation["additionalProperties"] as? Bool, false)
        XCTAssertEqual(Set(presentation["required"] as? [String] ?? []), Set(["relativePath", "sha256"]))
    }

    func testReadyReferenceReloadConversionAndOriginalReplay() throws {
        let (repo, work, path) = try fixture()
        let first = try prepare(repo, work.event, path)
        XCTAssertTrue(try repo.loadContents().presentationReferences.isEmpty)
        let result = envelope(work, path, first)
        _ = try repo.markImage(result, mode: .fast)
        XCTAssertEqual(try TravelRepository(root: repo.root).loadContents().presentationReferences[work.event.id], first)
        let event = try XCTUnwrap(repo.events().first)
        let next = try prepare(repo, event, path, style: "v2")
        let source = digest(try Data(contentsOf: repo.root.appendingPathComponent(path)))
        XCTAssertEqual(try repo.publishPresentation(next, for: event.id, expectedSourceSHA256: source, expectedPresentationSHA256: first.sha256), next)
        XCTAssertThrowsError(try repo.publishPresentation(first, for: event.id, expectedSourceSHA256: source, expectedPresentationSHA256: first.sha256))
        XCTAssertEqual(try repo.events().first, event)
        _ = try repo.markImage(result, mode: .fast)
        XCTAssertEqual(try repo.loadContents().presentationReferences[event.id], next)
        let newer = try prepare(repo, event, path, style: "v3")
        XCTAssertEqual(try repo.publishPresentation(newer, for: event.id, expectedSourceSHA256: source, expectedPresentationSHA256: next.sha256), newer)
        XCTAssertEqual(try repo.loadContents().presentationReferences[event.id], newer)
        XCTAssertThrowsError(try repo.publishPresentation(first, for: event.id, expectedSourceSHA256: source, expectedPresentationSHA256: next.sha256))
        _ = try repo.markImage(result, mode: .fast)
        XCTAssertEqual(try repo.loadContents().presentationReferences[event.id], newer)
        try Data([0]).write(to: repo.root.appendingPathComponent(newer.relativePath))
        XCTAssertEqual(try TravelRepository(root: repo.root).loadContents().events.first, event)
    }

    func testBadReferenceAndReplacementDoNotConsumeLease() throws {
        let (repo, work, path) = try fixture()
        let ref = try prepare(repo, work.event, path)
        let bad = PostcardPresentationReference(relativePath: ref.relativePath, sha256: String(repeating: "0", count: 64))
        XCTAssertThrowsError(try repo.markImage(envelope(work, path, bad), mode: .fast))
        XCTAssertEqual(try repo.imageRetry(for: work.event.id)?.activeAttemptToken, work.attemptToken)
        repo.imageValidationHook = { try! Data([0]).write(to: repo.root.appendingPathComponent(ref.relativePath), options: .atomic) }
        XCTAssertThrowsError(try repo.markImage(envelope(work, path, ref), mode: .fast))
        XCTAssertEqual(try repo.imageRetry(for: work.event.id)?.activeAttemptToken, work.attemptToken)
    }

    func testEnvelopeLegacyBytesAndStrictReference() throws {
        let (_, work, path) = try fixture()
        let old = envelope(work, path, nil)
        let bytes = try JSONEncoder.travelCat.encode(old)
        struct LegacyEnvelope: Encodable {
            let eventId: UUID; let status: ImageResultStatus; let attemptedAt: Date
            let relativePath: String?; let reason: String?; let attemptToken: String
            let attemptCount: Int; let publishedNarrativeHash: String
        }
        let legacyBytes = try JSONEncoder.travelCat.encode(LegacyEnvelope(eventId: old.eventId, status: old.status, attemptedAt: old.attemptedAt, relativePath: old.relativePath, reason: old.reason, attemptToken: old.attemptToken, attemptCount: old.attemptCount, publishedNarrativeHash: old.publishedNarrativeHash))
        XCTAssertEqual(bytes, legacyBytes)
        XCTAssertEqual(try NarrativeHasher.hash(old), digest(legacyBytes))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertNil(json["presentation"])
        XCTAssertEqual(try ImageResultEnvelope.decode(bytes), old)
        json["presentation"] = ["relativePath": "postcards/01234567-89ab-cdef-0123-456789abcdef/b.json", "sha256": String(repeating: "a", count: 64)]
        XCTAssertNoThrow(try ImageResultEnvelope.decode(JSONSerialization.data(withJSONObject: json)))
        json["presentation"] = ["relativePath": "postcards/a/b.json", "sha256": String(repeating: "a", count: 64), "extra": true]
        XCTAssertThrowsError(try ImageResultEnvelope.decode(JSONSerialization.data(withJSONObject: json)))
    }

    func testPresentationDecodeRejectsNoncanonicalPathsAndExplicitNull() throws {
        let (_, work, path) = try fixture()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.travelCat.encode(envelope(work, path, nil))) as? [String: Any])
        let trip = "01234567-89ab-cdef-0123-456789abcdef"
        for invalid in ["postcards/a/b.json", "postcards/\(trip.uppercased())/b.json", "postcards/\(trip)/.b.json", "postcards/\(trip)/_b.json", "postcards/\(trip)/-b.json", "postcards/\(trip)/b!.json"] {
            json["presentation"] = ["relativePath": invalid, "sha256": String(repeating: "a", count: 64)]
            XCTAssertThrowsError(try ImageResultEnvelope.decode(JSONSerialization.data(withJSONObject: json)), invalid)
        }
        json["presentation"] = NSNull()
        XCTAssertThrowsError(try ImageResultEnvelope.decode(JSONSerialization.data(withJSONObject: json)))
        let retry = ImageRetry(attemptCount: 0, retryAt: nil, publishedNarrativeHash: work.publishedNarrativeHash)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.travelCat.encode(retry)) as? [String: Any])
        for key in ["terminalPresentation", "currentPresentation"] {
            var malformed = original
            malformed[key] = NSNull()
            XCTAssertThrowsError(try JSONDecoder.travelCat.decode(ImageRetry.self, from: JSONSerialization.data(withJSONObject: malformed)), key)
        }
    }

    private func envelope(_ work: PendingImageWork, _ path: String, _ ref: PostcardPresentationReference?) -> ImageResultEnvelope {
        .init(eventId: work.event.id, status: .ready, attemptedAt: Date(timeIntervalSince1970: 1_786_435_200), relativePath: path, reason: nil, attemptToken: work.attemptToken, attemptCount: work.imageAttemptCount, publishedNarrativeHash: work.publishedNarrativeHash, presentation: ref)
    }
    private func prepare(_ repo: TravelRepository, _ event: TripEvent, _ path: String, style: String = "v1") throws -> PostcardPresentationReference {
        let pointer = try XCTUnwrap(realpath(repo.root.path, nil))
        defer { free(pointer) }
        return try PostcardPresentationStore(root: URL(fileURLWithPath: String(cString: pointer))).prepare(event: event, expectedSourceRelativePath: path, handwriting: .localFallback(.unavailable), placement: .init(x: 0.1, y: 0.1, width: 0.4, height: 0.2), styleVersion: style)
    }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func fixture() throws -> (TravelRepository, PendingImageWork, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PresentationPublication-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repo = try TravelRepository(root: root)
        let event = TripEvent.fixture(id: UUID(), tripID: UUID(), occurredAt: Date(timeIntervalSince1970: 1_786_435_200), phase: .preparing, postcardStatus: .pendingImage)
        try repo.publish(event: event, next: .fixture(stateVersion: 1, tripID: event.tripID, lastEventID: event.id, phase: .preparing, nextActionAt: .distantFuture, lastUpdatedAt: event.occurredAt))
        let path = "postcards/\(event.tripID.uuidString.lowercased())/base.png"
        try FileManager.default.createDirectory(at: root.appendingPathComponent(path).deletingLastPathComponent(), withIntermediateDirectories: true)
        let context = try XCTUnwrap(CGContext(data: nil, width: 1152, height: 768, bitsPerComponent: 8, bytesPerRow: 1152 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let data = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        try (data as Data).write(to: root.appendingPathComponent(path))
        return (repo, try XCTUnwrap(repo.pendingImages(mode: .fast).first), path)
    }
}
