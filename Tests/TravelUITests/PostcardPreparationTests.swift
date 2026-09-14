import Foundation
import CoreGraphics
import ImageIO
import TravelCore
import TravelStorage
import XCTest
@testable import TravelUI

final class PostcardPreparationTests: XCTestCase {
    func testBeginFinishAndRejectPreserveRepositoryBytesAndUseTrustedPrompt() throws {
        let f = try fixture(), ink = try png(ink: true)
        let before = try state(f.repo)
        let service = PostcardPreparation(repository: f.repo, select: { _, _ in Self.hint },
            verify: { _, _, _ in Self.hint.safeArea }, read: { _ in ink })
        let begin = try service.execute(request(f, action: "begin"))
        XCTAssertEqual(begin.status, .generate)
        XCTAssertEqual(begin.generationPrompt, try PostcardHandwritingPolicy.prompt(event: f.event, hint: Self.hint))
        let fallback = try XCTUnwrap(begin.fallbackReference)
        XCTAssertEqual(try f.store.load(reference: fallback, event: f.event, expectedSourceRelativePath: f.path).manifest.handwriting, .localFallback(.generationFailed))
        let finished = try service.execute(request(f, action: "finish", ref: fallback))
        XCTAssertEqual(finished.status, .prepared)
        let generated = try XCTUnwrap(finished.presentationReference)
        XCTAssertEqual(try f.store.load(reference: generated, event: f.event, expectedSourceRelativePath: f.path).handwritingData, ink)
        let reject = PostcardPreparation(repository: f.repo, select: { _, _ in Self.hint },
            verify: { _, _, _ in throw PostcardHandwritingVerifier.Rejection.invalidText }, read: { _ in ink })
        let rejected = try reject.execute(request(f, action: "finish", ref: fallback))
        XCTAssertEqual(rejected.status, .rejected)
        XCTAssertEqual(rejected.rejection, .invalidText)
        XCTAssertEqual(rejected.correctionPrompt, try PostcardHandwritingPolicy.prompt(event: f.event, hint: Self.hint, correction: .invalidText))
        XCTAssertThrowsError(try reject.execute(request(f, action: "finish", ref: generated)))
        XCTAssertThrowsError(try reject.execute(request(f, action: "finish", ref: .init(relativePath: fallback.relativePath, sha256: String(repeating: "0", count: 64)))))
        XCTAssertEqual(try state(f.repo), before)
        XCTAssertTrue(try f.repo.loadContents().presentationReferences.isEmpty)
    }

    func testNoSafePlacementReturnsCapturedFallback() throws {
        let f = try fixture(), before = try state(f.repo)
        let service = PostcardPreparation(repository: f.repo, select: { _, _ in throw PostcardHandwritingVerifier.Rejection.unsafeLayout })
        let response = try service.execute(request(f, action: "begin"))
        XCTAssertEqual(response.status, .fallback)
        XCTAssertNotNil(response.fallbackReference)
        XCTAssertNil(response.generationPrompt)
        XCTAssertEqual(try state(f.repo), before)
    }

    func testChangedSourceAndSetupErrorsAreNeverInkRejections() throws {
        let f = try fixture()
        let service = PostcardPreparation(repository: f.repo, select: { _, _ in Self.hint })
        let fallback = try XCTUnwrap(service.execute(request(f, action: "begin")).fallbackReference)
        let unsafeReader = PostcardPreparation(repository: f.repo, select: { _, _ in Self.hint },
            read: { _ in throw GeneratedPostcardImageReader.Rejection.unsafePath })
        XCTAssertThrowsError(try unsafeReader.execute(request(f, action: "finish", ref: fallback)))
        try png(gray: 0.5).write(to: f.repo.root.appendingPathComponent(f.path), options: .atomic)
        XCTAssertThrowsError(try service.execute(request(f, action: "finish", ref: fallback)))
    }

    func testRealVerifierRejectsBadPNGWithoutPublishing() throws {
        let f = try fixture(), before = try state(f.repo)
        let service = PostcardPreparation(repository: f.repo, select: { _, _ in Self.hint }, verify: { event, base, ink in
            // Deterministic foreground geometry lets the real verifier reach PNG validation.
            let analysis = PostcardVisualAnalysis(salientRegions: [],
                samples: .init(columns: 1, rows: 1, values: [.init(luminance: 1, red: 1, green: 1, blue: 1)]),
                foregroundRegions: [CGRect(x: 0.42, y: 0.35, width: 0.2, height: 0.4)])
            return try PostcardHandwritingVerifier.verify(event: event,
                base: PostcardHandwritingPolicy.decodeBase(base), inkData: ink, analysis: analysis).placement
        }, read: { _ in Data([1, 2, 3]) })
        let fallback = try XCTUnwrap(service.execute(request(f, action: "begin")).fallbackReference)
        let result = try service.execute(request(f, action: "finish", ref: fallback))
        XCTAssertEqual(result.status, .rejected)
        XCTAssertEqual(result.rejection, .invalidImage)
        XCTAssertNotNil(result.correctionPrompt)
        XCTAssertEqual(try state(f.repo), before)
    }

    func testSourceReplacementDuringVerificationFailsClosedEvenOnInkRejection() throws {
        for rejecting in [false, true] {
            let f = try fixture(), replacement = try png(gray: 0.5), ink = try png(ink: true)
            let service = PostcardPreparation(repository: f.repo, select: { _, _ in Self.hint }, verify: { _, _, _ in
                try replacement.write(to: f.repo.root.appendingPathComponent(f.path), options: .atomic)
                if rejecting { throw PostcardHandwritingVerifier.Rejection.invalidText }
                return Self.hint.safeArea
            }, read: { _ in ink })
            let fallback = try XCTUnwrap(service.execute(request(f, action: "begin")).fallbackReference)
            XCTAssertThrowsError(try service.execute(request(f, action: "finish", ref: fallback)))
        }
    }

    func testFinishRequiresCapturedLandscapeHashAsWellAsSource() throws {
        let f = try fixture(), ink = try png(ink: true)
        let fallback = try f.store.prepare(event: f.event, expectedSourceRelativePath: f.path,
            derivedLandscapeData: png(gray: 0.5), handwriting: .localFallback(.unavailable),
            placement: Self.hint.safeArea, styleVersion: PostcardHandwritingPolicy.styleVersion)
        let service = PostcardPreparation(repository: f.repo, select: { _, _ in Self.hint },
            verify: { _, _, _ in Self.hint.safeArea }, read: { _ in ink })
        XCTAssertThrowsError(try service.execute(request(f, action: "finish", ref: fallback)))
        XCTAssertTrue(try f.repo.loadContents().presentationReferences.isEmpty)
    }

    func testPreparedReferenceStillNeedsOriginalUnexpiredLeaseAtMarkImage() throws {
        let f = try fixture(), ink = try png(ink: true)
        let work = try XCTUnwrap(f.repo.pendingImages(mode: .fast).first)
        let service = PostcardPreparation(repository: f.repo, select: { _, _ in Self.hint },
            verify: { _, _, _ in Self.hint.safeArea }, read: { _ in ink })
        let fallback = try XCTUnwrap(service.execute(request(f, action: "begin")).fallbackReference)
        let prepared = try XCTUnwrap(service.execute(request(f, action: "finish", ref: fallback)).presentationReference)
        func result(token: String) -> ImageResultEnvelope {
            .init(eventId: f.event.id, status: .ready, attemptedAt: Date(), relativePath: f.path, reason: nil,
                attemptToken: token, attemptCount: work.imageAttemptCount,
                publishedNarrativeHash: work.publishedNarrativeHash, presentation: prepared)
        }
        let bytes = try state(f.repo)
        XCTAssertThrowsError(try f.repo.markImage(result(token: UUID().uuidString.lowercased()), mode: .fast))
        let expired = try TravelRepository(root: f.repo.root, clock: FixedClock(now: work.leaseExpiresAt.addingTimeInterval(1)))
        XCTAssertThrowsError(try expired.markImage(result(token: work.attemptToken), mode: .fast))
        XCTAssertEqual(try state(f.repo), bytes)
        XCTAssertEqual(try f.repo.markImage(result(token: work.attemptToken), mode: .fast).status, .ready)
        XCTAssertEqual(try f.repo.loadContents().presentationReferences[f.event.id], prepared)
    }

    private static var hint: PostcardHandwritingPolicy.Hint {
        .init(safeArea: .init(x: 0.1, y: 0.1, width: 0.5, height: 0.2), color: .init(red: 0, green: 0, blue: 0))
    }
    private struct Fixture: Sendable {
        let repo: TravelRepository; let event: TripEvent; let path: String
        var store: PostcardPresentationStore { .init(root: repo.root) }
    }
    private func request(_ f: Fixture, action: String, ref: PostcardPresentationReference? = nil) throws -> PostcardPreparationRequest {
        var object: [String: Any] = ["action": action, "eventId": f.event.id.uuidString, "sourceRelativePath": f.path]
        if let ref { object["fallbackReference"] = ["relativePath": ref.relativePath, "sha256": ref.sha256]; object["generatedImagePath"] = "/trusted/ink.png" }
        return try PostcardPreparationRequest.decode(JSONSerialization.data(withJSONObject: object))
    }
    private func state(_ repo: TravelRepository) throws -> [Data] {
        try ["journal/events.jsonl", "state/current-trip.json", "state/image-retries.json"].map { try Data(contentsOf: repo.root.appendingPathComponent($0)) }
    }
    private func fixture() throws -> Fixture {
        let now = Date(timeIntervalSince1970: 1_786_435_200)
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        let repo = try TravelRepository(root: root, clock: FixedClock(now: now))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let trip = UUID()
        let event = TripEvent(id: UUID(), tripID: trip, previousEventID: nil, occurredAt: now, phase: .preparing,
            location: nil, transport: nil, summary: "summary", mood: .init(level: 1, label: "开心", quote: "旅行正好"),
            continuityReferences: [], openHook: nil, consumedItemID: nil, postcardStatus: .pendingImage, postcardRelativePath: nil)
        let snapshot = TripSnapshot(stateVersion: 1, tripID: trip, lastEventID: event.id, phase: .preparing,
            nextActionAt: .distantFuture, lastUpdatedAt: now, carriedItemID: nil, usedItemIDs: [], visitedPlaces: [], mood: event.mood, openHook: nil)
        try repo.publish(event: event, next: snapshot)
        let path = "postcards/\(trip.uuidString.lowercased())/scene.png"
        try FileManager.default.createDirectory(at: root.appendingPathComponent(path).deletingLastPathComponent(), withIntermediateDirectories: true)
        try png().write(to: root.appendingPathComponent(path))
        return Fixture(repo: repo, event: event, path: path)
    }
    private func png(ink: Bool = false, gray: CGFloat = 1) throws -> Data {
        let w = ink ? 100 : 1152, h = ink ? 50 : 768
        let context = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(ink ? CGRect(x: 4, y: 4, width: w - 8, height: h - 8) : CGRect(x: 0, y: 0, width: w, height: h))
        let data = NSMutableData(), dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest)); return data as Data
    }
}
