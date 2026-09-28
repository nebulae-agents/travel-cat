import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import TravelCatApp

@MainActor
private final class SetupViewTestCredentials: TravelServiceCredentialStoring {
    var accessCount = 0
    func read(id: String) throws -> String? { accessCount += 1; return nil }
    func save(_ secret: String?, id: String) throws { accessCount += 1 }
}

final class GenerationSetupViewTests: XCTestCase {
    @MainActor func testCompatibleServiceSetupRendersAtMinimumAndPreferredSize() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TravelGenerationConfigurationStore(root: root)
        var configuration = TravelGenerationConfiguration()
        configuration.narrative = .init(kind: .openAICompatible, baseURL: "http://localhost:11434/v1", model: "local-text-test")
        configuration.image = .init(kind: .openAICompatible, baseURL: "http://127.0.0.1:18181/v1", model: "local-image-test")
        try store.save(configuration)
        let credentials = SetupViewTestCredentials()
        let controller = try GenerationServiceController(store: store, credentials: credentials, hasExistingHistory: false)
        let view = GenerationSetupView(controller: controller, credentials: credentials,
                                       executor: CodexTravelExecutor(executableURL: root.appendingPathComponent("never-executed")))
        let hosting = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        hosting.sizingOptions = []
        hosting.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 760),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        // Never order the test window on screen or synthesize user input.
        defer { window.close() }
        for size in [NSSize(width: 600, height: 630), NSSize(width: 640, height: 760)] {
            window.setContentSize(size)
            hosting.frame = NSRect(origin: .zero, size: size)
            hosting.layoutSubtreeIfNeeded()
            XCTAssertFalse(window.isVisible)
            XCTAssertFalse(hosting.hasAmbiguousLayout)
            XCTAssertEqual(hosting.bounds.width, size.width, accuracy: 0.5)
            XCTAssertEqual(hosting.bounds.height, size.height, accuracy: 0.5)
            // With sizingOptions disabled, AppKit fittingSize is intentionally zero;
            // actual mounted bounds above are the relevant layout contract.
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
            XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
            XCTAssertGreaterThan(png.count, 5_000, "Setup should render visible content rather than an empty bitmap")
            if size.width == 640, let output = ProcessInfo.processInfo.environment["TRAVELCAT_RENDER_SETUP_PATH"] {
                try png.write(to: URL(fileURLWithPath: output))
            }
        }
        XCTAssertEqual(credentials.accessCount, 0, "Layout must not access real or mock service credentials")
        XCTAssertFalse(controller.isReady)
    }
}
