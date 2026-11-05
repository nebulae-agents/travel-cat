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

    func testPopulatedV12PagesRenderAtBothSizesAndAppearances() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentXPopulated-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = AgentXController(repository: .init(root: root), credentials: AgentXTestCredentials(), respond: { _, _, _, _ in "先给结论，再说明必要依据。保留不确定性，回答简短清晰。" })
        try controller.addProvider(name: "本地验收服务", address: "http://localhost:1234", models: "preview-model", secret: "")
        try controller.addDefinition(name: "写作伙伴", prompt: "协助整理思路与写作。")
        try controller.addApp(name: "写作空间")
        let app = try XCTUnwrap(controller.state.apps.last)
        try controller.addInstance(name: "写作伙伴", appID: app.id, definitionID: controller.state.definitions[0].id, providerID: controller.state.providers[0].id, model: "preview-model")
        let instanceID = controller.state.instances[0].id
        controller.openApp(app.id)
        controller.send("帮我把想法整理成行动清单。", instanceID: instanceID)
        await controller.waitForRuns()
        controller.drafts[instanceID] = "尚未发送的内容，切换前后台后应保留。"
        controller.sendConfigurationRequest("回答更简短，先给结论。", instanceID: instanceID)
        await controller.waitForRuns()
        try controller.applyConfigurationProposal(runID: XCTUnwrap(controller.state.runs.last?.id))
        let workflow = AgentXWorkflowDefinition(name: "提纲与复核", steps: [.init(name: "整理提纲", instanceID: instanceID, instruction: "整理三点提纲"), .init(name: "复核表达", instanceID: instanceID, instruction: "基于上一步结果检查遗漏")])
        try controller.saveWorkflowDraft(appID: app.id, definition: workflow, expectedDraft: nil)
        try controller.publishWorkflow(appID: app.id)
        var experience = AgentXAppExperience()
        experience.title = "夜航写作室"; experience.intro = "在安静的港湾整理想法，与写作伙伴共同推进。"
        experience.rules = "先给结论，保留未确认事项。"; experience.sharedMemory = "每周五复盘。"
        experience.layout = .scene; experience.sceneTheme = .harbor
        experience.choices = ["整理三点提纲", "检查遗漏", "制定下一步"]
        try controller.saveExperienceDraft(appID: app.id, configuration: experience, expectedDraft: nil)
        try controller.publishExperience(appID: app.id)
        let wc = AgentXWindowController(controller: controller, openJourney: {}, openAlbum: {}, travelPending: true)
        let window = try XCTUnwrap(wc.window)
        defer { window.close() }
        let host = try XCTUnwrap(window.contentView)
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            window.appearance = NSAppearance(named: appearance)
            for page in [AgentXPage.chat, .configuration, .apps, .characters, .workflows, .sceneRules, .appModels, .appFiles, .appSettings, .members, .governance] {
                controller.page = page
                for width in [960, 1280] {
                    let size = NSSize(width: width, height: 820)
                    window.setContentSize(size); host.frame = NSRect(origin: .zero, size: size)
                    try await Task.sleep(for: .milliseconds(40))
                    host.layoutSubtreeIfNeeded()
                    XCTAssertFalse(host.hasAmbiguousLayout)
                    if let output = ProcessInfo.processInfo.environment["AGENTX_RENDER_DIR"] {
                        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
                        try data.write(to: URL(fileURLWithPath: output).appendingPathComponent("filled-\(page.rawValue)-\(width)-\(appearance.rawValue).png"))
                    }
                }
            }
        }
        XCTAssertEqual(controller.drafts[instanceID], "尚未发送的内容，切换前后台后应保留。")
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
