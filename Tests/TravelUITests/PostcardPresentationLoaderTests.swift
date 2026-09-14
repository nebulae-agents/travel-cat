import XCTest
import AppKit
import SwiftUI
import CoreGraphics
import ImageIO
import TravelCore
import TravelStorage
@testable import TravelUI

final class PostcardPresentationLoaderTests: XCTestCase {
    @MainActor
    func testActualAsyncArtworkHasReadableCanvasAndOneInkLayerWithoutCaption() async throws {
        let (root, event) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let ref = try PostcardPresentationStore(root: root).prepare(event: event, expectedSourceRelativePath: event.postcardRelativePath!, derivedLandscapeData: png(width: 1152, height: 768), handwriting: .generated(png(width: 100, height: 80, ink: true)), placement: .init(x: 0.1, y: 0.1, width: 0.4, height: 0.3), styleVersion: "test")
        let view = PostcardArtworkView(event: event, rootURL: root, height: 120, profile: .compact, presentationReference: ref)
            .frame(width: 340, alignment: .leading).background(Color.black)
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 250), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        defer { window.close() }
        var captured: NSBitmapImageRep?
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(50))
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            if containsRed(bitmap) { captured = bitmap; break }
        }
        let bitmap = try XCTUnwrap(captured, "Accepted ink must reach the real asynchronous view")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/postcard-presentation-ui-compact.png"))
        // The decoded thumbnail is 1024x683, but the logical accepted canvas is
        // exactly 3:2. Sampling an interior row avoids its rounded corners.
        let scale = Double(bitmap.pixelsWide) / 340
        let y = Int(20 * scale)
        let whiteWidth = (0..<bitmap.pixelsWide).filter { x in
            guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
            return c.redComponent > 0.95 && c.greenComponent > 0.95 && c.blueComponent > 0.95
        }.count
        XCTAssertGreaterThanOrEqual(Double(whiteWidth) / scale, 320)
        XCTAssertLessThanOrEqual(hosting.fittingSize.height, 214, "Generated ink suppresses the ordinary below-image quote")
        XCTAssertEqual(hosting.fittingSize.height, ceil(320 / 1.5 * scale) / scale, accuracy: 0.001, "Only native backing-pixel rounding is allowed; no extra narrow-view hint")
        let firstBounds = try XCTUnwrap(redBounds(bitmap))
        XCTAssertLessThan(firstBounds.maxX / scale, 160, "There must be only one ink layer, within its stored placement")

        // A new accepted revision while this very view is open moves the ink.
        // Replacing with an invalid revision first also exercises cancellation of
        // an in-flight request without allowing its old result to win.
        let second = try PostcardPresentationStore(root: root).prepare(event: event, expectedSourceRelativePath: event.postcardRelativePath!, derivedLandscapeData: png(width: 1152, height: 768), handwriting: .generated(png(width: 100, height: 80, ink: true)), placement: .init(x: 0.5, y: 0.1, width: 0.4, height: 0.3), styleVersion: "second")
        hosting.rootView = PostcardArtworkView(event: event, rootURL: root, height: 120, profile: .compact, presentationReference: .init(relativePath: second.relativePath, sha256: "invalid"))
            .frame(width: 340, alignment: .leading).background(Color.black)
        await Task.yield()
        hosting.rootView = PostcardArtworkView(event: event, rootURL: root, height: 120, profile: .compact, presentationReference: second)
            .frame(width: 340, alignment: .leading).background(Color.black)
        var movedBounds: CGRect?
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(50))
            hosting.layoutSubtreeIfNeeded()
            let next = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: next)
            if let bounds = redBounds(next), bounds.minX / scale > 160 { movedBounds = bounds; break }
        }
        XCTAssertNotNil(movedBounds, "Replacing the reference refreshes the existing view and discards stale loads")

        hosting.rootView = PostcardArtworkView(event: event, rootURL: root, height: 230, profile: .detail, presentationReference: ref)
            .frame(width: 456, alignment: .leading).background(Color.black)
        window.setContentSize(NSSize(width: 456, height: 230))
        try await Task.sleep(for: .milliseconds(300))
        hosting.layoutSubtreeIfNeeded()
        let detail = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: detail)
        let detailBounds = try XCTUnwrap(redBounds(detail))
        let detailScale = Double(detail.pixelsWide) / 456
        XCTAssertEqual(detailBounds.minX / detailScale / 345, firstBounds.minX / scale / 320, accuracy: 0.01)
        XCTAssertEqual(detailBounds.width / detailScale / 345, firstBounds.width / scale / 320, accuracy: 0.01)
        XCTAssertEqual(hosting.fittingSize.height, 230, accuracy: 0.5)
        try XCTUnwrap(detail.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/postcard-presentation-ui-detail.png"))

        hosting.rootView = PostcardArtworkView(event: event, rootURL: root, height: 120, profile: .compact, presentationReference: ref)
            .frame(width: 280, alignment: .leading).background(Color.black)
        window.setContentSize(NSSize(width: 280, height: 230))
        try await Task.sleep(for: .milliseconds(300))
        hosting.layoutSubtreeIfNeeded()
        let narrow = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: narrow)
        XCTAssertEqual(hosting.fittingSize.width, 280, accuracy: 0.5)
        XCTAssertGreaterThan(hosting.fittingSize.height, 280 / 1.5 + 4, "A genuinely narrow view adds a reading hint below the canvas")
        XCTAssertLessThan(hosting.fittingSize.height, 220)
        XCTAssertTrue(containsRed(narrow))
        try XCTUnwrap(narrow.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/postcard-presentation-ui-narrow.png"))
    }

    @MainActor
    private func containsRed(_ bitmap: NSBitmapImageRep) -> Bool {
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 3) {
                if let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.redComponent > 0.8 && c.blueComponent < 0.3 && c.greenComponent < 0.3 { return true }
            }
        }
        return false
    }

    @MainActor
    private func redBounds(_ bitmap: NSBitmapImageRep) -> CGRect? {
        var bounds: CGRect?
        for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
            if let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.redComponent > 0.8 && c.blueComponent < 0.3 && c.greenComponent < 0.3 {
                let pixel = CGRect(x: x, y: y, width: 1, height: 1)
                bounds = bounds.map { $0.union(pixel) } ?? pixel
            }
        } }
        return bounds
    }
    func testAcceptedReferenceRevalidatesEveryRequestAndFallsBackToFreshOriginal() async throws {
        let (root, event) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try Data(contentsOf: root.appendingPathComponent(event.postcardRelativePath!))
        let ref = try PostcardPresentationStore(root: root).prepare(event: event, expectedSourceRelativePath: event.postcardRelativePath!, derivedLandscapeData: png(width: 1152, height: 768), handwriting: .generated(png(width: 100, height: 80, ink: true)), placement: .init(x: 0.1, y: 0.1, width: 0.4, height: 0.3), styleVersion: "test")
        let first = try await PostcardPresentationLoader.load(event: event, rootURL: root, reference: ref)
        XCTAssertNotNil(first.manifest)
        XCTAssertNotNil(first.handwriting)
        XCTAssertFalse(first.showsFallbackIndicator)
        let manifest = try XCTUnwrap(first.manifest)
        if case let .generated(asset) = manifest.handwriting {
            try Data([0]).write(to: root.appendingPathComponent(asset.relativePath))
        }
        let second = try await PostcardPresentationLoader.load(event: event, rootURL: root, reference: ref)
        XCTAssertNil(second.manifest)
        XCTAssertNil(second.handwriting)
        XCTAssertTrue(second.showsFallbackIndicator)
        XCTAssertEqual(second.image.width, 60)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(event.postcardRelativePath!)), original)
        try png(width: 90, height: 60).write(to: root.appendingPathComponent(event.postcardRelativePath!))
        let changed = try await PostcardPresentationLoader.load(event: event, rootURL: root, reference: ref)
        XCTAssertEqual(changed.image.width, 90)
        let legacy = try await PostcardPresentationLoader.load(event: event, rootURL: root, reference: nil)
        XCTAssertFalse(legacy.showsFallbackIndicator)
    }

    func testLocalFallbackUsesValidatedLandscapeAndChangedQuoteRejects() async throws {
        let (root, event) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let ref = try PostcardPresentationStore(root: root).prepare(event: event, expectedSourceRelativePath: event.postcardRelativePath!, derivedLandscapeData: png(width: 1152, height: 768), handwriting: .localFallback(.unavailable), placement: .init(x: 0.1, y: 0.1, width: 0.4, height: 0.3), styleVersion: "test")
        let loaded = try await PostcardPresentationLoader.load(event: event, rootURL: root, reference: ref)
        XCTAssertNotNil(loaded.manifest)
        XCTAssertNil(loaded.handwriting)
        XCTAssertTrue(loaded.showsFallbackIndicator)
        XCTAssertEqual(loaded.image.width, 1024)
        let changed = try changingQuote(event, to: "changed")
        let rejected = try await PostcardPresentationLoader.load(event: changed, rootURL: root, reference: ref)
        XCTAssertNil(rejected.manifest)
        XCTAssertEqual(rejected.image.width, 60)
        for invalid in [PostcardPresentationReference(relativePath: ref.relativePath, sha256: "bad"), PostcardPresentationReference(relativePath: "postcards/\(event.tripID.uuidString.lowercased())/missing.json", sha256: ref.sha256)] {
            let fallback = try await PostcardPresentationLoader.load(event: event, rootURL: root, reference: invalid)
            XCTAssertNil(fallback.manifest)
            XCTAssertTrue(fallback.showsFallbackIndicator)
            XCTAssertEqual(fallback.image.width, 60)
        }
        let landscapePath = try XCTUnwrap(loaded.manifest?.landscape.relativePath)
        try Data([0]).write(to: root.appendingPathComponent(landscapePath))
        let corrupt = try await PostcardPresentationLoader.load(event: event, rootURL: root, reference: ref)
        XCTAssertNil(corrupt.manifest)
        XCTAssertEqual(corrupt.image.width, 60)
    }

    func testCancelledPresentationRequestDoesNotReturnFallback() async throws {
        let (root, event) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let work = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await PostcardPresentationLoader.load(event: event, rootURL: root, reference: nil)
        }
        do { _ = try await work.value; XCTFail("Cancellation must propagate") }
        catch is CancellationError { }
    }

    func testViewportCropsBeforeReductionPreservesTopLeftPixelsAndOwnsBoundedStorage() throws {
        let data = try png(width: 3000, height: 2000, ink: true)
        let raster = try PostcardPresentationStore.inspectHandwriting(data)
        let decoded = try PostcardPresentationLoader.decodeHandwriting(data: data, viewport: raster.paddedViewport)
        XCTAssertEqual(decoded.width, 24)
        XCTAssertEqual(decoded.height, 14)
        XCTAssertLessThanOrEqual(decoded.bytesPerRow * decoded.height, 24 * 14 * 8)
        let bytes = try XCTUnwrap(decoded.dataProvider?.data) as Data
        // The red marker is at the top-left; the blue marker is at the bottom-right.
        XCTAssertGreaterThan(bytes[2 * decoded.bytesPerRow + 2 * 4], 200)
        XCTAssertGreaterThan(bytes[11 * decoded.bytesPerRow + 21 * 4 + 2], 200)
        XCTAssertEqual(data, try png(width: 3000, height: 2000, ink: true))
        let full = try PostcardPresentationLoader.decodeHandwriting(data: data, viewport: nil)
        XCTAssertEqual(full.width, 1024)
        XCTAssertLessThanOrEqual(full.height, 1024)
    }

    func testLoadIdentityBindsExactQuoteEventTripAndReferenceRevision() throws {
        let (root, event) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let ref = PostcardPresentationReference(relativePath: "manifest.json", sha256: "a")
        let first = PostcardArtworkLoadIdentity.requestID(event: event, rootURL: root, reference: ref)
        let changed = try changingQuote(event, to: event.mood.quote + " ")
        XCTAssertNotEqual(first, PostcardArtworkLoadIdentity.requestID(event: changed, rootURL: root, reference: ref))
        XCTAssertNotEqual(first, PostcardArtworkLoadIdentity.requestID(event: event, rootURL: root, reference: .init(relativePath: ref.relativePath, sha256: "b")))
    }

    private func changingQuote(_ event: TripEvent, to quote: String) throws -> TripEvent {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
        var mood = try XCTUnwrap(object["mood"] as? [String: Any])
        mood["quote"] = quote
        object["mood"] = mood
        return try JSONDecoder().decode(TripEvent.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func fixture() throws -> (URL, TripEvent) {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        let trip = UUID()
        let path = "postcards/\(trip.uuidString.lowercased())/source.png"
        try FileManager.default.createDirectory(at: root.appendingPathComponent(path).deletingLastPathComponent(), withIntermediateDirectories: true)
        try png(width: 60, height: 40).write(to: root.appendingPathComponent(path))
        return (root, TripEvent(id: UUID(), tripID: trip, previousEventID: nil, occurredAt: Date(), phase: .postcardReady, location: nil, transport: nil, summary: "summary", mood: Mood(level: 4, label: "calm", quote: " exact\n中文 "), continuityReferences: [], openHook: nil, consumedItemID: nil, postcardStatus: .ready, postcardRelativePath: path))
    }

    private func png(width: Int, height: Int, ink: Bool = false) throws -> Data {
        var bytes = [UInt8](repeating: ink ? 0 : 255, count: width * height * 4)
        if ink {
            for y in 10..<20 { for x in 10..<30 {
                let i = (y * width + x) * 4
                bytes[i + (y < 15 ? 0 : 2)] = 255
                bytes[i + 3] = 255
            } }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let result = NSMutableData()
        let destination = CGImageDestinationCreateWithData(result, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return result as Data
    }
}
