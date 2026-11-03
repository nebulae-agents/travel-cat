import AppKit
import SwiftUI
import XCTest
@testable import TravelCatApp

@MainActor
final class AgentXViewTests: XCTestCase {
    func testWorkbenchPageEmbedsHostWorkbenchInsteadOfChatComposer() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("AgentXWorkbenchPage-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = AgentXController(repository: AgentXRepository(root: root), credentials: AgentXTestCredentials())
        try controller.ensureWorkbenchApp()
        controller.openApp("workbench")
        var renders = 0
        let windowController = AgentXWindowController(controller: controller, openJourney: {}, openAlbum: {},
            travelPending: false, workbenchContent: { renders += 1; return AnyView(Text("HOST_WORKBENCH")) })
        defer { windowController.window?.close() }
        windowController.window?.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertGreaterThan(renders, 0)
        XCTAssertEqual(controller.selectedAppID, "workbench")
    }

    func testLegacyWorkbenchInboxUpdatesKeepDraftAndRouteToExistingWorkbench() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentXInboxTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = AgentXController(repository: AgentXRepository(root: root), credentials: AgentXTestCredentials())
        controller.drafts["draft"] = "保留未发送内容"
        var opened = 0
        let windowController = AgentXWindowController(controller: controller, openJourney: {}, openAlbum: {},
            travelPending: false, workbenchPending: 2, openWorkbench: { opened += 1 })
        defer { windowController.window?.close() }
        let host = try XCTUnwrap(windowController.window?.contentView as? NSHostingView<AgentXManagerView>)
        XCTAssertEqual(host.rootView.workbenchPending, 2)
        windowController.updateWorkbenchPending(3)
        windowController.updateTravelPending(true)
        XCTAssertEqual(host.rootView.workbenchPending, 3)
        XCTAssertTrue(host.rootView.travelPending)
        host.rootView.openWorkbench()
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(controller.drafts["draft"], "保留未发送内容")
        controller.openFromDock(travelPending: host.rootView.workbenchPending > 0)
        XCTAssertEqual(controller.page, .inbox)
    }

    func testNativePagesRenderWithoutShowingDesktopPetOrModifyingTravelData() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentXViewTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = AgentXController(repository: AgentXRepository(root: root), credentials: AgentXTestCredentials())
        let windowController = AgentXWindowController(controller: controller, openJourney: {}, openAlbum: {}, travelPending: false)
        let window = try XCTUnwrap(windowController.window)
        defer { window.close() }
        let host = try XCTUnwrap(window.contentView)
        for page in AgentXPage.allCases {
            controller.page = page
            for size in [NSSize(width: 1280, height: 820), NSSize(width: 960, height: 640)] {
                window.setContentSize(size)
                host.frame = NSRect(origin: .zero, size: size)
                try await Task.sleep(for: .milliseconds(40))
                host.layoutSubtreeIfNeeded()
                XCTAssertFalse(window.isVisible)
                XCTAssertFalse(host.hasAmbiguousLayout)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                XCTAssertGreaterThan(png.count, 10_000)
                if let output = ProcessInfo.processInfo.environment["AGENTX_RENDER_DIR"] {
                    try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
                    try png.write(to: URL(fileURLWithPath: output).appendingPathComponent("\(page.rawValue)-\(Int(size.width)).png"))
                }
            }
        }
    }
}
