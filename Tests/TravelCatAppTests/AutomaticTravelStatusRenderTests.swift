import AppKit
import SwiftUI
import XCTest
@testable import TravelCatApp

@MainActor
final class AutomaticTravelStatusRenderTests: XCTestCase {
    func testActualStatusViewAtSettingsWidth() async throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        var callback: AutomaticTravelProgressHandler?
        var completion: CheckedContinuation<AutomaticTravelOutcome, Never>?
        let controller = AutomaticTravelController(isEnabled: { true }, runWithProgress: { report in
            callback = report
            return await withCheckedContinuation { completion = $0 }
        }, retryWithProgress: { _ in .init(nextCheckAt: date, message: "等待") }, lastSuccessDate: date)
        defer { controller.stop() }
        controller.refresh()
        for _ in 0..<100 { await Task.yield() }
        callback?(.imageHandling)
        try await render(controller, name: "running")
        var outcome = AutomaticTravelOutcome(nextCheckAt: date.addingTimeInterval(60),
            message: "等待生成间隔，再继续处理明信片 · 12 张等待自动处理 · 3 张已停止自动重试，可在旅行册手动重试",
            failure: AutomaticTravelFailure(error: CocoaError(.fileWriteNoPermission), recordedAt: date, stage: .publication))
        outcome.lastSuccessDate = date
        completion?.resume(returning: outcome)
        for _ in 0..<100 { await Task.yield() }
        try await render(controller, name: "waiting")
        XCTAssertFalse(controller.isRunning)
        XCTAssertEqual(controller.lastSuccessDate, date)
        let failure = AutomaticTravelFailure(error: CocoaError(.fileWriteNoPermission), recordedAt: date, stage: .publication)
        let failed = AutomaticTravelController(isEnabled: { true }, runWithProgress: { _ in
            .init(nextCheckAt: date.addingTimeInterval(60), message: failure.message, failure: failure)
        }, lastSuccessDate: date)
        defer { failed.stop() }
        failed.refresh()
        for _ in 0..<100 { await Task.yield() }
        try await render(failed, name: "failure")
    }

    private func render(_ controller: AutomaticTravelController, name: String) async throws {
        // Actual settings uses a 480 pt grouped form with 20 pt outer padding.
        let content = Form {
            Section("旅行") { AutomaticTravelStatusView(controller: controller) }
        }.formStyle(.grouped).padding(20).frame(width: 480, height: 340)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.locale, Locale(identifier: "zh_CN"))
        let view = NSHostingView(rootView: content)
        view.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 340),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = view
        defer { window.contentView = nil; window.close() }
        view.frame = NSRect(x: 0, y: 0, width: 480, height: 340)
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, 480)
        if let directory = ProcessInfo.processInfo.environment["TRAVEL_CAT_PROGRESS_RENDER"] {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("travel-progress-\(name).png")
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        }
    }
}
