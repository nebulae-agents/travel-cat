import AppKit
import SwiftUI
import XCTest
import AgentXAppSDK
@testable import TravelCatApp

@MainActor
final class AgentXAppShellTests: XCTestCase {
    private func controller(respond: AgentXController.Responder? = nil) throws -> AgentXController {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("AppShell-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repo = AgentXRepository(root: root)
        var state = AgentXState()
        state.apps = [.init(id: "a", name: "A", kind: .chat), .init(id: "b", name: "B", kind: .chat), .init(id: "off", name: "Off", kind: .chat, enabled: false)]
        state.currentAppID = "b"
        state.runs = [.init(id: "other", appID: "a", instanceID: "other", prompt: "Other secret", status: .completed, response: "")]
        try repo.save(state)
        return AgentXController(repository: repo, credentials: AgentXTestCredentials(), respond: respond, autoRefreshCatalogs: false)
    }
    func testFrontendAndBackstageRememberIndependentLocations() throws {
        let c = try controller()
        c.selectModule("members")
        XCTAssertEqual(c.appArea, .frontend)
        c.openBackstage()
        XCTAssertEqual(c.page, .members)
        c.navigate(to: .characters)
        c.openFrontend()
        XCTAssertEqual(c.page, .members)
        c.openBackstage()
        XCTAssertEqual(c.page, .characters)
        XCTAssertTrue(c.selectApplication("a"))
        c.openFrontend()
        XCTAssertTrue(c.selectApplication("b"))
        XCTAssertEqual(c.page, .characters)
        XCTAssertEqual(c.appArea, .backstage)
    }
    func testSettingsStartAtMembersAndRememberEachApplicationsSection() throws {
        let c = try controller()
        c.selectModule("artifacts")
        c.openBackstage()
        XCTAssertEqual(c.page, .members)
        c.navigate(to: .appModels)
        c.openFrontend()
        XCTAssertEqual(c.currentModuleID, "artifacts")
        XCTAssertEqual(c.page, .appFiles)
        XCTAssertTrue(c.selectApplication("a"))
        c.openBackstage()
        XCTAssertEqual(c.page, .members)
        c.navigate(to: .sceneRules)
        XCTAssertTrue(c.selectApplication("b"))
        c.openBackstage()
        XCTAssertEqual(c.page, .appModels)
        XCTAssertTrue(c.selectApplication("a"))
        c.openBackstage()
        XCTAssertEqual(c.page, .sceneRules)
    }

    func testRunAndDockSynchronizeArea() throws {
        let c = try controller()
        c.openBackstage()
        c.openRun(.init(id: "result", appID: "b", instanceID: "one", prompt: "", status: .completed, response: ""))
        XCTAssertEqual(c.appArea, .frontend)
        c.openBackstage()
        c.openFromDock()
        XCTAssertEqual(c.appArea, .frontend)
    }
    func testFrontendNonModulePageReturnsAfterBackstage() throws {
        let c = try controller()
        for destination in [AgentXPage.inbox, .overview] {
            c.navigate(to: destination)
            c.openBackstage()
            c.openFrontend()
            XCTAssertEqual(c.page, destination)
            XCTAssertEqual(c.appArea, .frontend)
        }
    }
    func testPendingDockAndSpecialRunsSynchronizeArea() throws {
        let c = try controller()
        XCTAssertTrue(c.selectApplication("a"))
        c.openBackstage()
        c.openFromDock()
        XCTAssertEqual(c.page, .inbox)
        XCTAssertEqual(c.appArea, .frontend)
        for (purpose, page) in [(AgentXRunPurpose.configuration, AgentXPage.configuration), (.workflow, .workflows), (.characterPreview, .characters)] {
            var run = AgentXRun(id: "special", appID: "b", instanceID: "one", prompt: "", status: .completed, response: "")
            run.purpose = purpose
            c.openRun(run)
            XCTAssertEqual(c.page, page)
            XCTAssertEqual(c.appArea, .backstage)
        }
    }
    func testInvalidRememberedModuleFallsBackOnReturn() throws {
        let c = try controller()
        c.selectModule("members")
        c.navigate(to: .providers)
        c.frontendSession(appID: "b").selectedModule = "removed-module"
        c.returnToApplication()
        XCTAssertEqual(c.page, .chat)
        XCTAssertEqual(c.currentModuleID, "chat")
    }
    func testAssistantPurposeUsesAreaForSamePage() throws {
        let c = try controller()
        c.selectModule("members")
        XCTAssertTrue(c.usesUsageAssistant)
        c.navigate(to: .members)
        XCTAssertFalse(c.usesUsageAssistant)
        c.navigate(to: .providers)
        XCTAssertFalse(c.usesUsageAssistant)
    }
    func testDockIgnoresOtherApplicationsUnreadResults() throws {
        let c = try controller()
        XCTAssertEqual(c.selectedAppID, "b")
        c.openFromDock()
        XCTAssertEqual(c.page, .chat)
    }
    func testApplicationSelectionLeavesPreviousBackstageContext() throws {
        let c = try controller()
        c.page = .characters
        XCTAssertTrue(c.selectApplication("a"))
        XCTAssertEqual(c.page, .chat)
    }
    func testPlatformReturnPreservesApplicationPageAndModule() throws {
        let c = try controller()
        c.selectModule("members")
        XCTAssertEqual(c.page, .members)
        c.navigate(to: .providers)
        c.navigate(to: .platformOverview)
        XCTAssertEqual(c.currentApp?.id, "b")
        c.returnToApplication()
        XCTAssertEqual(c.page, .members)
        XCTAssertEqual(c.currentModuleID, "members")
        XCTAssertTrue(c.selectApplication("a"))
        c.navigate(to: .configuration)
        XCTAssertTrue(c.selectApplication("b"))
        XCTAssertEqual(c.page, .members)
    }
    func testSelectingSameApplicationAndStoppingAnotherPreservesCurrentPage() async throws {
        let c = try controller()
        c.selectModule("members")
        c.navigate(to: .providers)
        c.returnToApplication()
        c.navigate(to: .characters)
        XCTAssertTrue(c.selectApplication("b"))
        XCTAssertEqual(c.page, .characters)
        try await c.setApplicationEnabled("a", enabled: false)
        XCTAssertEqual(c.selectedAppID, "b")
        XCTAssertEqual(c.page, .characters)
    }
    func testSwitcherInitialEnterKeepsCurrentApplication() throws {
        let c = try controller()
        let selected = try XCTUnwrap(AgentXAppNavigationPolicy.initialSwitcherSelection(in: c.enabledApps, currentID: c.selectedAppID))
        XCTAssertEqual(selected, "b")
        XCTAssertTrue(c.selectApplication(selected))
        XCTAssertEqual(c.currentApp?.id, "b")
        XCTAssertEqual(AgentXAppNavigationPolicy.initialSwitcherSelection(in: c.enabledApps.filter { $0.id == "a" }, currentID: "b"), "a")
        XCTAssertNil(AgentXAppNavigationPolicy.initialSwitcherSelection(in: [], currentID: "b"))
    }
    func testDisablingCurrentAppRestoresFallbackMemberDraftAndModel() async throws {
        let c = try controller()
        try c.addProvider(name: "Local", address: "http://localhost:1234", models: "one,two", secret: "")
        try c.addDefinition(name: "Writer", prompt: "Write")
        let definitionID = try XCTUnwrap(c.state.definitions.first?.id)
        let providerID = try XCTUnwrap(c.state.providers.first?.id)
        for name in ["First", "Second"] {
            try c.addInstance(name: name, appID: "b", definitionID: definitionID, providerID: providerID, model: "one")
        }
        let second = try XCTUnwrap(c.currentInstances.last)
        c.selectedInstanceID = second.id
        c.drafts[second.id] = "Second member draft"
        try c.selectConversationModel(instanceID: second.id, providerID: providerID, model: "two")
        c.navigate(to: .members)
        XCTAssertTrue(c.selectApplication("a"))
        try await c.setApplicationEnabled("a", enabled: false)
        XCTAssertEqual(c.selectedAppID, "b")
        XCTAssertEqual(c.selectedInstanceID, second.id)
        XCTAssertEqual(c.currentInstance?.id, second.id)
        XCTAssertEqual(c.page, .members)
        XCTAssertEqual(c.drafts[c.currentInstance?.id ?? ""], "Second member draft")
        XCTAssertEqual(c.currentInstance?.conversationModel?.model, "two")
    }
    func testDisplayedCharacterMemoryUsesMembersPinnedPublishedRevision() throws {
        let c = try controller()
        try c.addProvider(name: "Local", address: "http://localhost:1234", models: "m", secret: "")
        let providerID = try XCTUnwrap(c.state.providers.first?.id)
        let definitionID = try c.addDefinitionDraft(name: "Writer", document: .init(source: "Version one", files: ["character.yaml": "memory: First memory\n"]))
        try c.publishDefinition(id: definitionID)
        try c.addInstance(name: "Pinned", appID: "b", definitionID: definitionID, providerID: providerID, model: "m", definitionRevision: 1)
        let pinnedID = try XCTUnwrap(c.currentInstances.last?.id)
        try c.addInstance(name: "Follow", appID: "b", definitionID: definitionID, providerID: providerID, model: "m")
        let followID = try XCTUnwrap(c.currentInstances.last?.id)
        try c.saveDefinitionDraft(id: definitionID, name: "Writer", document: .init(source: "Version two", files: ["character.yaml": "memory: Second memory\n"]))
        try c.publishDefinition(id: definitionID)
        XCTAssertEqual(c.displayedCharacterMemory(instanceID: pinnedID), "First memory")
        XCTAssertEqual(c.displayedCharacterMemory(instanceID: followID), "Second memory")
        XCTAssertTrue(c.selectApplication("a"))
        XCTAssertNil(c.displayedCharacterMemory(instanceID: pinnedID))
    }
    func testNewCrossApplicationEditorSurvivesDelayedContextChangeWhileOldEditorCloses() throws {
        let c = try controller()
        XCTAssertTrue(c.selectApplication("a"))
        let old = AgentXEditorPresentation(create: .instance).scoped(to: c.shellContextGeneration)
        c.navigate(to: .instances)
        XCTAssertTrue(c.selectApplication("b"))
        let member = AgentXInstance(id: "member-b", name: "B member", appID: "b", definitionID: "writer", providerID: "local", model: "m")
        let new = AgentXEditorPresentation(instance: member).scoped(to: c.shellContextGeneration)
        // SwiftUI observes the generation change after the button has created B's request.
        XCTAssertNil(old.retained(in: c.shellContextGeneration))
        XCTAssertEqual(new.retained(in: c.shellContextGeneration)?.id, new.id)
        XCTAssertEqual(new.retained(in: c.shellContextGeneration)?.existingInstance, member)
        for presentation in [AgentXEditorPresentation(create: .app), .init(create: .provider), .init(create: .definition), .init(create: .instance),
                             .init(provider: .init(id: "local", name: "Local", baseURL: "http://localhost", models: ["m"])),
                             .init(definition: .init(id: "writer", name: "Writer", prompt: "Write")), .init(instance: member)] {
            let scoped = presentation.scoped(to: c.shellContextGeneration)
            XCTAssertEqual(scoped.retained(in: c.shellContextGeneration)?.id, scoped.id)
            XCTAssertNil(scoped.retained(in: c.shellContextGeneration + 1))
        }
    }
    func testPaletteKeysRespectMarkedTextAndResumeNavigationAfterComposition() {
        _ = NSApplication.shared
        let editor = NSTextView(frame: .init(x: 0, y: 0, width: 200, height: 40))
        let keys: [(UInt16, AgentXPaletteKeyPolicy.Action)] = [(125, .move(1)), (126, .move(-1)), (36, .choose), (76, .choose), (53, .close)]
        editor.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        for (key, _) in keys {
            XCTAssertNil(AgentXPaletteKeyPolicy.action(keyCode: key, modifiers: [], firstResponder: editor))
        }
        editor.unmarkText()
        XCTAssertFalse(editor.hasMarkedText())
        for (key, action) in keys {
            XCTAssertEqual(AgentXPaletteKeyPolicy.action(keyCode: key, modifiers: [], firstResponder: editor), action)
            XCTAssertNil(AgentXPaletteKeyPolicy.action(keyCode: key, modifiers: .command, firstResponder: editor))
        }
        XCTAssertNil(AgentXPaletteKeyPolicy.action(keyCode: 0, modifiers: [], firstResponder: editor))
    }
    func testDeclaredModulesOverrideDefaultsAndMapToRealRoutes() throws {
        var app = AgentXApplication(id: "a", name: "A", kind: .chat)
        XCTAssertEqual(AgentXAppNavigationPolicy.modules(for: app).map(\.id), ["chat", "runs", "members", "artifacts"])
        app.modules = ["stage", "world-state", "npc-memory", "director-intervention", "unknown"]
        let modules = AgentXAppNavigationPolicy.modules(for: app)
        XCTAssertEqual(modules.map(\.id), app.modules)
        XCTAssertEqual(modules.map(\.page), Array(repeating: .module, count: 5))
        XCTAssertFalse(modules.last!.available)
        for (id, page) in [("chat", AgentXPage.chat), ("history", .runs), ("runs", .runs), ("inbox", .inbox), ("members", .members), ("artifacts", .appFiles), ("settings", .appSettings)] {
            XCTAssertEqual(AgentXAppNavigationPolicy.module(id).page, page)
        }
    }
    func testSearchAndPendingStayInsideCurrentApplication() throws {
        let c = try controller()
        XCTAssertFalse(c.applicationSearch("").contains { $0.title == "Other secret" })
        XCTAssertTrue(c.applicationSearch("Other secret").isEmpty)
        XCTAssertFalse(c.openSearchResult(.init(appID: "a", title: "Other secret", detail: "", target: .run("other"))))
        XCTAssertEqual(c.selectedAppID, "b")
        XCTAssertTrue(c.selectApplication("a"))
        let result = try XCTUnwrap(c.applicationSearch("Other secret").first)
        XCTAssertEqual(result.appID, "a")
        XCTAssertTrue(c.openSearchResult(result))
        XCTAssertEqual(c.selectedAppID, "a")
        for (kind, expected) in [(AgentXAppKind.chat, 2), (.blackcat, 3), (.workbench, 9)] {
            XCTAssertEqual(AgentXAppNavigationPolicy.pending(app: .init(id: "x", name: "X", kind: kind), unread: 2, travel: true, workbench: 7), expected)
        }
        XCTAssertEqual(AgentXAppNavigationPolicy.pending(app: nil, unread: 2, travel: true, workbench: 7), 0)
    }
    func testSwitchClearsPresentationButRetainsInputsSessionsAndModelChoice() throws {
        let c = try controller()
        c.drafts["draft"] = "unsent"
        c.usageAssistantInputs["b"] = "assistant"
        c.experienceEditorDrafts["b"] = Data([1])
        c.frontendSession(appID: "b").values = ["chat": ["input": "unsaved"]]
        c.frontendSession(appID: "b").selectedModule = "chat"
        c.selectedInstanceID = "remembered"
        c.shellOverlay = .search; c.assistantPresented = true
        XCTAssertTrue(c.selectApplication("a"))
        XCTAssertNil(c.shellOverlay); XCTAssertFalse(c.assistantPresented)
        XCTAssertTrue(c.selectApplication("b"))
        XCTAssertEqual(c.selectedInstanceID, "remembered")
        XCTAssertEqual(c.drafts["draft"], "unsent")
        XCTAssertEqual(c.usageAssistantInputs["b"], "assistant")
        XCTAssertEqual(c.experienceEditorDrafts["b"], Data([1]))
        XCTAssertEqual(c.frontendSession(appID: "b").values["chat"]?["input"], "unsaved")
    }
    func testShortcutsDisabledAndSingleModeCannotBypassPolicy() throws {
        let c = try controller()
        XCTAssertFalse(c.selectApplication("off"))
        try c.setSingleApp("b")
        c.selectApplicationShortcut(0)
        XCTAssertEqual(c.selectedAppID, "b")
        c.navigate(to: .apps)
        XCTAssertEqual(c.state.singleAppID, "b")
        try c.setSingleApp(nil)
        c.selectApplicationShortcut(0)
        XCTAssertEqual(c.selectedAppID, "a")
        c.selectApplicationShortcut(8)
        XCTAssertEqual(c.selectedAppID, "a")
    }
    func testEnableOnlyGrantsPermissionAndStopFeedbackAllowsExplicitRetry() async throws {
        var responseCalls = 0
        let c = try controller(respond: { _, _, _, _ in responseCalls += 1; return "unexpected" })
        for app in c.enabledApps { try await c.setApplicationEnabled(app.id, enabled: false) }
        XCTAssertNil(c.currentApp)
        XCTAssertEqual(c.page, .apps)
        c.shellOverlay = .switcher
        try await c.setApplicationEnabled("off", enabled: true)
        XCTAssertEqual(c.page, .apps)
        XCTAssertEqual(c.shellOverlay, .switcher)
        XCTAssertEqual(c.state.runs.count, 1)
        XCTAssertEqual(responseCalls, 0)
        let stopping = AgentXAppNavigationPolicy.stopAction(enabled: false, state: .stopping)
        XCTAssertFalse(stopping.enabled)
        let retry = AgentXAppNavigationPolicy.stopAction(enabled: false, state: .unverified("still running"))
        XCTAssertTrue(retry.enabled); XCTAssertFalse(retry.targetEnabled)
        XCTAssertEqual(retry.title, "重试停止")
    }
    func testDeclarativeHeaderSelectionRetainsUnsavedModuleInputsAndModels() throws {
        let original = try controller()
        let repo = original.repository
        var state = try repo.load()
        state.apps[1].modules = ["draft", "review"]
        state.providers = [.init(id: "local", name: "Local", baseURL: "http://localhost:1234", models: ["one", "two"])]
        state.definitions = [.init(id: "writer", name: "Writer", prompt: "Write")]
        state.instances = [.init(id: "writer-b", name: "Writer B", appID: "b", definitionID: "writer", providerID: "local", model: "one")]
        try repo.save(state)
        let payload = repo.root.appendingPathComponent("apps/b/payload")
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        let contract = AppFrontendContract(title: "Writing", modules: ["draft", "review"].map {
            .init(id: $0, title: $0, fields: [.init(id: "input", label: "Input")], submit: .init(title: "Send", prompt: "{{input}}"))
        })
        let manifest = AppManifest(id: "b", name: "B", version: "1", dataSchemaVersion: 1, hostAPIMajor: 1, kind: "chat", runtime: "host-text", modules: ["draft", "review"])
        try JSONEncoder().encode(manifest).write(to: repo.root.appendingPathComponent("apps/b/manifest.json"))
        try JSONEncoder().encode(contract).write(to: payload.appendingPathComponent("frontend.json"))
        let c = AgentXController(repository: repo, credentials: AgentXTestCredentials(), autoRefreshCatalogs: false)
        let session = c.frontendSession(appID: "b")
        let loaded = try AgentXFrontendStore(root: repo.root, appID: "b").load()
        session.restore(contract: loaded.0, persisted: loaded.1)
        session.values = ["draft": ["input": "Unsent draft"], "review": ["input": "Unsent review"]]
        try c.selectConversationModel(instanceID: "writer-b", providerID: "local", model: "two")
        c.selectModule("review")
        XCTAssertEqual(c.page, .chat)
        XCTAssertEqual(session.selectedModule, "review")
        c.navigate(to: .providers); c.returnToApplication()
        XCTAssertEqual(c.currentModuleID, "review")
        XCTAssertTrue(c.selectApplication("a")); XCTAssertTrue(c.selectApplication("b"))
        XCTAssertEqual(c.frontendSession(appID: "b").values["draft"]?["input"], "Unsent draft")
        XCTAssertEqual(c.frontendSession(appID: "b").selectedModule, "review")
        XCTAssertEqual(c.currentInstances.first?.conversationModel?.model, "two")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.root.appendingPathComponent("apps/b/state/frontend-values.json").path))
    }
    func testSettingsAndPlatformRoutesReturnWithoutLosingModuleDraft() throws {
        let c = try controller()
        c.selectModule("artifacts")
        c.drafts["member"] = "unsent"
        for page in [AgentXPage.members, .sceneRules, .characters, .workflows, .appModels, .runs, .appFiles, .appSettings, .configuration] {
            c.navigate(to: page)
            XCTAssertEqual(c.appArea, .backstage)
            c.openFrontend()
            XCTAssertEqual(c.page, .appFiles)
            XCTAssertEqual(c.currentModuleID, "artifacts")
        }
        for page in [AgentXPage.apps, .providers, .backups, .settings, .platformOverview, .definitions, .instances, .governance] {
            c.navigate(to: page)
            XCTAssertEqual(c.page, page)
            c.returnToApplication()
            XCTAssertEqual(c.page, .appFiles)
            XCTAssertEqual(c.currentModuleID, "artifacts")
        }
        XCTAssertEqual(c.drafts["member"], "unsent")
        XCTAssertFalse(c.assistantPresented)
    }

    func testNativeShellAndPalettesRenderAtBothSizesAndAppearances() async throws {
        _ = NSApplication.shared
        let c = try controller()
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 960, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        for empty in [false, true] {
            if empty { for app in c.enabledApps { try await c.setApplicationEnabled(app.id, enabled: false) } }
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance)
                for width in [960, 1280] {
                    for surface in ["shell", "switcher", "search"] {
                        c.navigate(to: empty ? .apps : .overview)
                        let view: AnyView
                        switch surface {
                        case "switcher": view = AnyView(AgentXAppSwitcher(controller: c))
                        case "search": view = AnyView(AgentXAppSearch(controller: c))
                        default: view = AnyView(AgentXManagerView(controller: c))
                        }
                        let host = NSHostingView(rootView: view)
                        window.contentView = host
                        window.setContentSize(.init(width: width, height: width == 960 ? 640 : 820))
                        try await Task.sleep(for: .milliseconds(40))
                        host.layoutSubtreeIfNeeded()
                        XCTAssertFalse(host.hasAmbiguousLayout)
                        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        XCTAssertGreaterThan(png.count, 5_000)
                        if let output = ProcessInfo.processInfo.environment["AGENTX_RENDER_DIR"] {
                            try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
                            try png.write(to: URL(fileURLWithPath: output).appendingPathComponent("shell-\(surface)-\(empty)-\(width)-\(appearance.rawValue).png"))
                        }
                    }
                }
            }
        }
    }

}
