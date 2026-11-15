import AppKit
import SwiftUI
import XCTest
@testable import TravelCatApp

final class AgentXStopStatusTests: XCTestCase {
    func testUnverifiedCountsOnlyKnownItemsAndNeverReportsStopped() {
        let op = AgentXStopOperation(appID: "a", status: .unverified, items: [
            .init(id: "run", title: "运行", kind: .task, status: .confirmed),
            .init(id: "external", title: "外部运行器", kind: .runtime, status: .unverified)
        ])
        XCTAssertEqual(op.pendingItemCount, 1)
        XCTAssertEqual(op.statusTitle, "已禁止新任务 · 1 项停止未确认")
    }
    func testPersistenceFailureOverridesStoppedLabel() {
        let op = AgentXStopOperation(appID: "a", status: .stopped, items: [], persistenceFailure: "未保存")
        XCTAssertEqual(op.statusTitle, "停止记录未保存 · 不可确认完成")
    }
    func testStopFailureProjectionClearsOnlyConfirmedMatchingOperation() {
        var operation = AgentXStopOperation(appID: "a", status: .unverified, items: [])
        let failure = "等待超时"
        XCTAssertEqual(AgentXStopOperation.visibleFailure(failure, operationID: operation.id, current: operation), failure)
        operation.status = .stopped
        XCTAssertNil(AgentXStopOperation.visibleFailure(failure, operationID: operation.id, current: operation))
        operation.persistenceFailure = "未保存"
        XCTAssertEqual(AgentXStopOperation.visibleFailure(failure, operationID: operation.id, current: operation), failure)
        XCTAssertEqual(AgentXStopOperation.visibleFailure("启用失败", operationID: nil, current: operation), "启用失败")
    }
    func testDiagnosticHasIdentifiersAndStatusButNotArbitraryDetail() {
        let op = AgentXStopOperation(appID: "a", items: [.init(id: "run", title: "title", kind: .task, detail: "sensitive raw error")])
        XCTAssertTrue(op.safeDiagnostic.contains("app=a"))
        XCTAssertFalse(op.safeDiagnostic.contains("sensitive raw error"))
    }
}


@MainActor final class AgentXStopStatusRenderTests: XCTestCase {
    func testStopDetailsRenderAtBothSizesAndAppearances() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentXStopRender-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = AgentXRepository(root: root)
        var state = AgentXState()
        state.apps = [.init(id: "blackcat", name: "停止验收应用", kind: .blackcat, enabled: false)]
        try repository.save(state)
        let operation = AgentXStopOperation(appID: "blackcat", status: .unverified, items: [
            .init(id: "run-a", title: "宿主任务", kind: .task, status: .confirmed, observedAt: Date()),
            .init(id: "runtime", title: "外部运行器", kind: .runtime, status: .unverified, observedAt: Date(), detail: "应用未注册运行器停止验证，不能确认退出。")
        ])
        try AgentXStopOperationStore(root: root).save(["blackcat": operation])
        let c = AgentXController(repository: repository, credentials: AgentXTestCredentials(), autoRefreshCatalogs: false)
        c.externalRuntimeProbe = { _ in [
            .init(id: "native-fixture", kind: .native, state: .responsive, reason: .none),
            .init(id: "docker-fixture", kind: .docker, state: .unknown, reason: .timeout)
        ] }
        c.refreshExternalObservation(for: "blackcat")
        try await Task.sleep(for: .milliseconds(20))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 960, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            for width in [960, 1280] {
                let host = NSHostingView(rootView: AgentXStopStatusView(controller: c, appID: "blackcat")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor)))
                window.contentView = host
                window.setContentSize(.init(width: width, height: width == 960 ? 640 : 820))
                try await Task.sleep(for: .milliseconds(40))
                c.refreshExternalObservation(for: "blackcat")
                try await Task.sleep(for: .milliseconds(40))
                host.layoutSubtreeIfNeeded()
                XCTAssertFalse(host.hasAmbiguousLayout)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                XCTAssertGreaterThan(png.count, 5000)
                if let output = ProcessInfo.processInfo.environment["AGENTX_RENDER_DIR"] {
                    try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
                    try png.write(to: URL(fileURLWithPath: output).appendingPathComponent("stop-\(width)-\(appearance.rawValue).png"))
                }
            }
        }
    }
}
