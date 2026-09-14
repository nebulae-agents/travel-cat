import CryptoKit
import AppKit
import ImageIO
import SwiftUI
import Foundation
import XCTest
import TravelCore
import TravelStorage
@testable import TravelCatApp
@testable import TravelUI

/// Explicit opt-in only. Ordinary unit tests must never consume model credits.
final class JourneyTestLiveAcceptanceTests: XCTestCase {
    @MainActor
    func testRenderRetainedLivePostcard() throws {
        guard let path = ProcessInfo.processInfo.environment["TRAVEL_CAT_LIVE_RENDER_SESSION"] else {
            throw XCTSkip("Retained live postcard render requires an explicit session.")
        }
        let root = URL(fileURLWithPath: path)
        let productionPath = try XCTUnwrap(ProcessInfo.processInfo.environment["TRAVEL_CAT_LIVE_PRODUCTION_ROOT"])
        let session = try JourneyTestSession.open(root: root, parent: root.deletingLastPathComponent(), productionRoot: URL(fileURLWithPath: productionPath))
        let events = try TravelRepository(root: session.root).loadContents().events
        let event = try XCTUnwrap(events.first(where: { $0.postcardStatus == .ready }))
        let relative = try XCTUnwrap(event.postcardRelativePath)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(session.root.appendingPathComponent(relative) as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let analysis = try PostcardVisualAnalyzer.analyze(image)
        for (profile, size) in [(PostcardOverlayProfile.detail, CGSize(width: 900, height: 450)), (.compact, CGSize(width: 320, height: 180))] {
            let transform = PostcardAspectFillTransform(imageSize: CGSize(width: image.width, height: image.height), containerSize: size)
            let layout = PostcardArtworkLayoutResolver.resolve(metadata: .init(event: event), analysis: transform.displayAnalysis(analysis), profile: profile, containerSize: size)
            XCTAssertEqual(layout.messagePlacement, .onImage, "This generated image has substantial clear space left of the cat.")
            let render = ImageRenderer(content: VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                    PostcardArtworkView(event: event, rootURL: nil, height: size.height, profile: profile)
                        .overlay(metadata: .init(event: event), layout: layout, containerSize: size)
                }.frame(width: size.width, height: size.height).clipped()
                Text(PostcardDisplayLocation().resolveCompact(event.location)).font(.headline)
            }.padding(12).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
            let rendered = try XCTUnwrap(render.cgImage)
            let bytes = try XCTUnwrap(NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:]))
            try session.validate()
            let output = session.root.appendingPathComponent("acceptance-\(profile).png")
            try bytes.write(to: output, options: .atomic)
            print("journey-render: path=\(output.path) quote=\(event.mood.quote) placement=\(layout.messagePlacement)")
        }
    }

    @MainActor
    func testRealModelJourney() async throws {
        guard ProcessInfo.processInfo.environment["TRAVEL_CAT_LIVE_JOURNEY_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Live model and image generation require explicit opt-in.")
        }
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let productionPath = try XCTUnwrap(ProcessInfo.processInfo.environment["TRAVEL_CAT_LIVE_PRODUCTION_ROOT"])
        guard productionPath.hasPrefix("/") else { throw CocoaError(.fileReadInvalidFileName) }
        let production = URL(fileURLWithPath: productionPath)
        let before = try fingerprints(production)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("JourneyLiveAcceptance-\(UUID().uuidString)")
        let parent = root.appendingPathComponent("JourneyTests")
        try JourneyTestParentDirectory.prepare(at: parent, productionRoot: production)
        let reference = project.appendingPathComponent("Sources/TravelUI/Resources/PreviewBlackCat/preview-cat-front.png")
        let generator = JourneyTestDiscoveredModelGenerator()
        let controller = JourneyTestController(
            parentRoot: parent, productionRoot: production,
            modelGenerator: generator,
            imageGenerator: JourneyTestCodexImageGenerator(model: generator),
            referenceImageURL: reference,
            onProgress: { progress in
                print("journey-live: session=\(progress.sessionID) stage=\(progress.stage?.rawValue ?? "initial") state=\(progress.state.rawValue) events=\(progress.completedEvents)")
            }
        )
        controller.start(fastTestEnabled: true)
        print("journey-live: retained-root=\(controller.session?.root.path ?? root.path)")
        await controller.waitUntilIdleForTesting()
        XCTAssertNil(controller.errorMessage, controller.errorMessage ?? "")
        XCTAssertEqual(controller.progress?.state, .completed)
        XCTAssertEqual(controller.model?.events.map(\.phase), [.preparing, .transit, .exploring, .postcardReady, .returning, .resting])
        let session = try XCTUnwrap(controller.session)
        let repository = try TravelRepository(root: session.root)
        let contents = try repository.loadContents()
        XCTAssertTrue(contents.events.contains(where: { $0.postcardStatus == .ready }))
        for (path, digest) in try fingerprints(session.root) where path.hasPrefix("postcards/") {
            print("journey-live: image=\(path) sha256=\(digest)")
        }
        let after = try fingerprints(production)
        // A concurrent formal heartbeat may legitimately change production. Record differences
        // rather than attributing them to the test; investigate any mismatch before acceptance.
        let changed = Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }.sorted()
        print("journey-live: production-changed-paths=\(changed)")
        XCTAssertTrue(changed.isEmpty, "Concurrent production changes require separate attribution: \(changed)")
    }

    private func fingerprints(_ root: URL) throws -> [String: String] {
        let normalizedRoot = root.standardizedFileURL
        guard let files = FileManager.default.enumerator(at: normalizedRoot, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            throw CocoaError(.fileReadUnknown)
        }
        var result: [String: String] = [:]
        for case let file as URL in files {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let relative = String(file.standardizedFileURL.path.dropFirst(normalizedRoot.path.count + 1))
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var digest = SHA256()
            while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty { digest.update(data: chunk) }
            result[relative] = digest.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return result
    }
}
