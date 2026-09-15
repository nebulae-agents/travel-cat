import AppKit
import CryptoKit
import Foundation
import SwiftUI
import TravelCore
import TravelStorage
import XCTest
@testable import TravelUI

/// Opt-in real-image acceptance. Private paths belong in the external JSON only.
final class PostcardGeneratedPresentationAcceptanceTests: XCTestCase {
    private enum AcceptanceError: Error { case prerequisiteMismatch(String) }
    private func require(_ condition: Bool, _ reason: String) throws {
        guard condition else { throw AcceptanceError.prerequisiteMismatch(reason) }
    }
    func testMismatchCannotReachAcceptedStatus() {
        var status = "checking"
        do { try require(false, "changed source"); status = "accepted" }
        catch { status = "input-or-harness-error" }
        XCTAssertEqual(status, "input-or-harness-error")
    }
    private struct Configuration: Decodable {
        struct Fixture: Decodable { let scenePath: String; let inkPath: String; let quote: String }
        let fixtures: [Fixture]
        let outputDirectory: String
    }

    @MainActor
    func testRealGeneratedSamplesThroughAcceptanceAndNativePresentation() async throws {
        guard let path = ProcessInfo.processInfo.environment["TRAVEL_CAT_PRESENTATION_ACCEPTANCE_CONFIG"] else {
            throw XCTSkip("Set TRAVEL_CAT_PRESENTATION_ACCEPTANCE_CONFIG to a private fixture JSON")
        }
        let configFile = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? configFile.close() }
        let configBytes = try configFile.read(upToCount: 65_537) ?? Data()
        guard configBytes.count <= 65_536 else { throw CocoaError(.fileReadTooLarge) }
        let config = try JSONDecoder().decode(Configuration.self, from: configBytes)
        guard (1...2).contains(config.fixtures.count) else { throw CocoaError(.fileReadCorruptFile) }
        let output = URL(fileURLWithPath: config.outputDirectory).standardizedFileURL
        guard config.outputDirectory.hasPrefix("/private/tmp/"), !config.outputDirectory.components(separatedBy: "/").contains("..") else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let temporaryRoot = URL(fileURLWithPath: "/private/tmp").resolvingSymlinksInPath().path
        guard output.resolvingSymlinksInPath().path.hasPrefix(temporaryRoot + "/") else { throw CocoaError(.fileWriteNoPermission) }
        let reader = GeneratedPostcardImageReader()
        var reports: [[String: Any]] = []
        for (index, fixture) in config.fixtures.enumerated() {
            progress(index, "reading trusted inputs")
            var report: [String: Any] = ["fixture": index + 1, "quote": fixture.quote]
            do {
                let base = try reader.read(path: fixture.scenePath), ink = try reader.read(path: fixture.inkPath)
                report["sceneSHA256"] = digest(base); report["inkSHA256"] = digest(ink)
                let now = Date(timeIntervalSince1970: 1_786_435_200), trip = UUID()
                let event = TripEvent(id: UUID(), tripID: trip, previousEventID: nil, occurredAt: now,
                    phase: .preparing, location: nil, transport: nil, summary: "Real generated postcard acceptance",
                    mood: .init(level: 1, label: "开心", quote: fixture.quote), continuityReferences: [],
                    openHook: nil, consumedItemID: nil, postcardStatus: .pendingImage, postcardRelativePath: nil)
                var selectedHint: PostcardHandwritingPolicy.Hint?
                do {
                    progress(index, "selecting with default visual analyzer")
                    let hint = try await Task.detached { try PostcardHandwritingPolicy.select(event: event, base: base) }.value
                    selectedHint = hint
                    report["selection"] = ["safeArea": [hint.safeArea.x, hint.safeArea.y, hint.safeArea.width, hint.safeArea.height],
                        "colorRGB": [hint.color.red, hint.color.green, hint.color.blue]]
                } catch { report["selectionRejection"] = typed(error) }
                do {
                    progress(index, "verifying with default analyzer and OCR")
                    let placement = try await Task.detached { try PostcardHandwritingPolicy.verify(event: event, base: base, ink: ink) }.value
                    progress(index, "accepted; preparing disposable repository presentation")
                    report["placement"] = [placement.x, placement.y, placement.width, placement.height]
                    let root = output.appendingPathComponent("repository-\(index + 1)-\(UUID().uuidString)")
                    let repo = try TravelRepository(root: root, clock: FixedClock(now: now))
                    let snapshot = TripSnapshot(stateVersion: 1, tripID: trip, lastEventID: event.id, phase: .preparing,
                        nextActionAt: .distantFuture, lastUpdatedAt: now, carriedItemID: nil, usedItemIDs: [],
                        visitedPlaces: [], mood: event.mood, openHook: nil)
                    try repo.publish(event: event, next: snapshot)
                    let work = try XCTUnwrap(repo.pendingImages(mode: .fast).first)
                    let scenePath = "postcards/\(trip.uuidString.lowercased())/scene.png"
                    let sceneURL = root.appendingPathComponent(scenePath)
                    try FileManager.default.createDirectory(at: sceneURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try base.write(to: sceneURL)
                    let store = PostcardPresentationStore(root: root)
                    let ref = try store.prepare(event: event, expectedSourceRelativePath: scenePath, derivedLandscapeData: base,
                        handwriting: .generated(ink), placement: placement, styleVersion: PostcardHandwritingPolicy.styleVersion)
                    _ = try repo.markImage(.init(eventId: event.id, status: .ready, attemptedAt: now,
                        relativePath: scenePath, reason: nil, attemptToken: work.attemptToken,
                        attemptCount: work.imageAttemptCount, publishedNarrativeHash: work.publishedNarrativeHash,
                        presentation: ref), mode: .fast)
                    let reopened = try TravelRepository(root: root, clock: FixedClock(now: now))
                    let contents = try reopened.loadContents()
                    let storedRef = try XCTUnwrap(contents.presentationReferences[event.id])
                    try require(storedRef == ref, "reopened reference changed")
                    let ready = try XCTUnwrap(contents.events.first { $0.id == event.id })
                    let loaded = try store.load(reference: storedRef, event: ready, expectedSourceRelativePath: scenePath)
                    try require(loaded.landscapeData == base && loaded.handwritingData == ink, "stored image bytes changed")
                    try require(try Data(contentsOf: sceneURL) == base, "source copy changed")
                    let actual = try await PostcardPresentationLoader.load(event: ready, rootURL: root, reference: storedRef)
                    try require(actual.manifest != nil && actual.handwriting != nil && !actual.showsFallbackIndicator, "loader did not use accepted presentation")
                    for (label, width, height, profile) in [("compact", 320.0, 120.0, PostcardOverlayProfile.compact),
                        ("detail", 345.0, 230.0, .detail), ("narrow", 280.0, 120.0, .compact)] {
                        progress(index, "capturing native \(label) artwork")
                        let artwork = PostcardArtworkView(event: ready, rootURL: root, height: height,
                            profile: profile, presentationReference: storedRef).frame(width: width, alignment: .leading)
                        try await capture(AnyView(artwork), width: width, height: 250,
                            to: output.appendingPathComponent("fixture-\(index + 1)-\(label).png"))
                    }
                    try await capture(AnyView(PostcardView(event: ready, rootURL: root,
                        presentationReference: storedRef, open: { _ in })), width: 380, height: 520,
                        to: output.appendingPathComponent("fixture-\(index + 1)-postcard.png"))
                    report["status"] = "accepted-native-captures-await-visual-review"
                    report["repository"] = root.path
                    report["reference"] = ["relativePath": storedRef.relativePath, "sha256": storedRef.sha256]
                } catch {
                    report["status"] = error is PostcardHandwritingVerifier.Rejection ? "rejected" : "input-or-harness-error"
                    report["rejection"] = typed(error)
                    if let hint = selectedHint, error is PostcardHandwritingVerifier.Rejection {
                        do {
                            // Observational only: never feed these observations into verify.
                            let diagnostic = try await Self.detachedOCRDiagnostics(base: base, ink: ink, hint: hint)
                            report["ocrDiagnostics"] = diagnostic
                        } catch { report["ocrDiagnosticError"] = typed(error) }
                    }
                    XCTFail("Fixture \(index + 1): \(typed(error))")
                }
                try require(digest(try reader.read(path: fixture.scenePath)) == digest(base), "original scene hash changed")
                try require(digest(try reader.read(path: fixture.inkPath)) == digest(ink), "original ink hash changed")
            } catch {
                report["status"] = "input-or-harness-error"; report["error"] = typed(error)
                XCTFail("Fixture \(index + 1): \(typed(error))")
            }
            reports.append(report)
            progress(index, "finished: \(report["status"] as? String ?? "unknown")")
        }
        let diagnostics = try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys])
        try diagnostics.write(to: output.appendingPathComponent("diagnostics.json"), options: .atomic)
        print(String(decoding: diagnostics, as: UTF8.self))
    }

    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func typed(_ error: Error) -> String { "\(String(reflecting: type(of: error))).\(error)" }
    private func progress(_ index: Int, _ phase: String) {
        FileHandle.standardOutput.write(Data("Acceptance fixture \(index + 1): \(phase)\n".utf8))
    }

    private static func detachedOCRDiagnostics(base: Data, ink: Data, hint: PostcardHandwritingPolicy.Hint) async throws -> String {
        try await Task.detached { try ocrDiagnostics(base: base, ink: ink, hint: hint) }.value
    }

    private static func ocrDiagnostics(base: Data, ink: Data, hint: PostcardHandwritingPolicy.Hint) throws -> String {
        let image = try PostcardHandwritingPolicy.decodeBase(base)
        let raster = try PostcardPresentationStore.inspectHandwriting(ink)
        let viewport = raster.paddedViewport
        let sourceWidth = viewport.width * Double(raster.width), sourceHeight = viewport.height * Double(raster.height)
        let safe = hint.safeArea
        let scale = min(safe.width * Double(image.width) / sourceWidth, safe.height * Double(image.height) / sourceHeight)
        let compactScale = Double(TripAlbumLayout.readableCompactArtworkWidth) / Double(image.width)
        let viewportRect = CGRect(x: viewport.x, y: viewport.y, width: viewport.width, height: viewport.height)
        let background: CGFloat = hint.color.relativeLuminance < 0.5 ? 1 : 0
        let lines = try PostcardHandwritingVerifier.recognize(raster.image, background: background)
        let diagnostics: [String: Any] = [
            "viewport": [viewport.x, viewport.y, viewport.width, viewport.height],
            "rasterSize": [raster.width, raster.height], "inspectionBackground": background,
            "placementScale": scale, "compactScale": compactScale,
            "lines": lines.map { line -> [String: Any] in
                let height = line.bounds.height * Double(raster.height) * scale * compactScale
                return ["text": line.text, "confidence": line.confidence,
                    "bounds": [line.bounds.minX, line.bounds.minY, line.bounds.width, line.bounds.height],
                    "viewportContains": viewportRect.contains(line.bounds), "projectedLogicalHeight": height,
                    "meets12PointMinimum": height >= 12]
            }
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: diagnostics, options: [.sortedKeys]), as: UTF8.self)
    }

    @MainActor
    private func capture(_ view: AnyView, width: Double, height: Double, to url: URL) async throws {
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        defer { window.close() }
        // Permit the production .task loader and layout to complete on the main actor.
        for _ in 0..<30 { try await Task.sleep(for: .milliseconds(50)); hosting.layoutSubtreeIfNeeded() }
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
