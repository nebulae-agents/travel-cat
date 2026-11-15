import AppKit
import SwiftUI
import XCTest
@testable import TravelCatApp

@MainActor
final class AgentXAppManagementTests: XCTestCase {
    private func setup() throws -> (AgentXController, AgentXManagedApplicationService) {
        let root = URL(fileURLWithPath: "/private/tmp/Management-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repository = AgentXRepository(root: root)
        var state = AgentXState()
        state.providers = [.init(id: "local", name: "Local", baseURL: "http://localhost:1234", models: ["model"])]
        try repository.save(state)
        let controller = AgentXController(repository: repository, credentials: AgentXTestCredentials(), autoRefreshCatalogs: false)
        return (controller, AgentXManagedApplicationService(controller: controller, requireIdle: { _ in }))
    }
    func testBackupRefreshLoadsOnceAndDiscardsCancelledLateResults() async throws {
        let (c, service) = try setup()
        var reads = 0
        var pending: CheckedContinuation<AgentXApplicationBackupCatalog, any Error>?
        let model = AgentXAppManagementModel(controller: c, service: service, backupLoader: {
            reads += 1
            return try await withCheckedThrowingContinuation { pending = $0 }
        })
        let first = model.refreshBackups()
        for _ in 0..<100 where pending == nil { await Task.yield() }
        XCTAssertTrue(model.loadingBackups)
        _ = model.refreshBackups()
        XCTAssertEqual(reads, 1)
        model.cancelBackupRefresh()
        try XCTUnwrap(pending).resume(returning: .init(warnings: ["stale result"]))
        await first?.value
        XCTAssertFalse(model.loadingBackups)
        XCTAssertTrue(model.catalog.warnings.isEmpty)
        pending = nil
        let second = model.refreshBackups()
        for _ in 0..<100 where pending == nil { await Task.yield() }
        try XCTUnwrap(pending).resume(returning: .init(warnings: ["fresh warning"]))
        await second?.value
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(model.catalog.warnings, ["fresh warning"])
        model.loadBackupsIfNeeded()
        XCTAssertEqual(reads, 2)
    }
    func testReturningToManagementRestartsCancelledScanWithoutOverlap() async throws {
        let (c, service) = try setup()
        var reads = 0
        var pending: CheckedContinuation<AgentXApplicationBackupCatalog, any Error>?
        let model = AgentXAppManagementModel(controller: c, service: service, backupLoader: {
            reads += 1
            if reads == 1 { return try await withCheckedThrowingContinuation { pending = $0 } }
            return .init(warnings: ["new scan"])
        })
        let first = model.refreshBackups()
        for _ in 0..<100 where pending == nil { await Task.yield() }
        model.cancelBackupRefresh(); model.loadBackupsIfNeeded()
        XCTAssertEqual(reads, 1)
        try XCTUnwrap(pending).resume(returning: .init(warnings: ["old scan"]))
        await first?.value
        for _ in 0..<100 where reads < 2 { await Task.yield() }
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(model.catalog.warnings, ["new scan"])
    }
    func testManifestFormattingMapsOnlyKnownPermissionScopesAndPreservesExtensions() {
        let value = AgentXManifestValue.object([
            "files": .array([.string("self"), .string("shared/published")]),
            "network": .array([.string("configured-provider"), .string("https://example.test")]),
            "shell": .bool(false), "schedule": .bool(true),
            "custom": .object(["enabled": .bool(true)]), "secrets": .array([.string("self")])
        ])
        XCTAssertEqual(AgentXAppManifestFormatter.permissions(value), [
            "网络：已配置的模型服务、https://example.test",
            "文件：仅本应用目录、shared/published",
            "Shell：未要求", "定时任务：请求使用（需另行授权）",
            "密钥 profile：self", "custom：{\"enabled\":true}"
        ])
        XCTAssertEqual(AgentXAppManifestFormatter.permissions(nil), ["未声明"])
        XCTAssertEqual(AgentXAppManifestFormatter.permissions(.object([:])), ["未列出权限"])
    }
    func testRequirementsFormattingKeepsUnknownCapabilitiesVisible() {
        let requires = AgentXManifestValue.object([
            "runtime": .string("host-text"), "providers": .array([.string("local")]),
            "tools": .array([.string("shell")]), "extension": .integer(3)
        ])
        XCTAssertEqual(AgentXAppManifestFormatter.requirements(requires), [
            "运行框架：host-text", "模型服务：local", "工具：shell", "extension：3"
        ])
        XCTAssertEqual(AgentXAppManifestFormatter.permissions(.object(["files": .string("configured-provider")])), ["文件：configured-provider"])
    }
    func testPreviewIsRequiredAndEditingInvalidatesItAndInstallNeverRuns() throws {
        let (c, service) = try setup()
        let model = AgentXAppManagementModel(controller: c, service: service)
        model.beginTemplate(.conversation)
        model.appID = "new-app"; model.selection = .init(providerID: "local", model: "model")
        model.install()
        XCTAssertNotNil(model.failure)
        XCTAssertFalse(c.state.apps.contains { $0.id == "new-app" })
        model.preparePreview()
        XCTAssertTrue(model.preview?.canInstall == true)
        XCTAssertEqual(model.preview?.definitions.count, 1)
        XCTAssertTrue(model.preview?.definitions.first?.prompt.contains("No tools") == true)
        model.appID = "changed"
        XCTAssertNil(model.preview)
        model.preparePreview(); model.install()
        XCTAssertEqual(c.state.apps.first { $0.id == "changed" }?.enabled, false)
        XCTAssertTrue(c.state.runs.isEmpty)
        XCTAssertEqual(model.creationStep, .installed(appID: "changed"))
    }
    func testCreationEditsInvalidatePreviewAndServiceRepairRetainsInput() async throws {
        let (c, service) = try setup()
        let model = AgentXAppManagementModel(controller: c, service: service)
        model.beginTemplate(.conversation)
        model.appID = "wizard"; model.selection = .init(providerID: "local", model: "model")
        model.preparePreview()
        model.applicationName = "My App"
        XCTAssertNil(model.preview)
        model.preparePreview()
        XCTAssertEqual(model.preview?.application.name, "My App")
        model.beginServiceRepair()
        XCTAssertNil(model.preview)
        model.endServiceRepair()
        XCTAssertEqual(model.appID, "wizard")
        XCTAssertEqual(model.applicationName, "My App")
        model.preparePreview(); model.install()
        XCTAssertEqual(model.creationStep, .installed(appID: "wizard"))
        XCTAssertFalse(try XCTUnwrap(c.state.apps.first { $0.id == "wizard" }).enabled)
        await model.enableInstalledApplication()
        XCTAssertTrue(try XCTUnwrap(c.state.apps.first { $0.id == "wizard" }).enabled)
        XCTAssertTrue(c.state.runs.isEmpty)
    }
    func testInvalidMemberEditCannotInstallAndCancellationLeavesNoApplication() throws {
        let (c, service) = try setup()
        let model = AgentXAppManagementModel(controller: c, service: service)
        model.beginTemplate(.conversation); model.appID = "invalid-member"
        model.selection = .init(providerID: "local", model: "model")
        model.preparePreview()
        let id = try XCTUnwrap(model.preview?.instances.first?.id)
        model.memberNames[id] = " "
        model.preparePreview()
        XCTAssertNil(model.preview)
        XCTAssertNotNil(model.failure)
        model.install()
        XCTAssertFalse(c.state.apps.contains { $0.id == "invalid-member" })
        model.close()
        XCTAssertNil(model.source)
        XCTAssertFalse(c.state.apps.contains { $0.id == "invalid-member" })
    }
    func testMemberEditsAndDependencyChangesAreRevalidated() throws {
        let (c, service) = try setup()
        let model = AgentXAppManagementModel(controller: c, service: service)
        model.beginTemplate(.conversation); model.appID = "members"
        model.selection = .init(providerID: "local", model: "model")
        model.preparePreview()
        let id = try XCTUnwrap(model.preview?.instances.first?.id)
        model.memberNames[id] = "Writer"
        XCTAssertNil(model.preview)
        model.preparePreview()
        XCTAssertEqual(model.preview?.instances.first?.name, "Writer")
        try c.setProviderEnabled("local", enabled: false)
        model.install()
        XCTAssertFalse(c.state.apps.contains { $0.id == "members" })
        XCTAssertNotNil(model.failure)
    }
    func testImportedBindingsSurviveUneditedInstallation() throws {
        let (c, service) = try setup()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wizard-import-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var package = AgentXLocalAppPackage.template(.conversation, appID: "imported", providerID: "local", model: "model")
        package.instances[0].name = "Original Member"
        try AgentXPackageFiles.write(package.files(), to: directory)
        let model = AgentXAppManagementModel(controller: c, service: service)
        model.beginImport(directory, directory: true)
        model.preparePreview()
        XCTAssertTrue(model.preview?.canInstall == true, model.failure ?? String(describing: model.preview?.missingRequirements))
        model.install()
        let app = try XCTUnwrap(c.state.apps.first { $0.id == "imported" })
        XCTAssertEqual(app.manifest, package.application.manifest)
        let member = try XCTUnwrap(c.state.instances.first { $0.appID == "imported" })
        XCTAssertEqual(member.name, "Original Member")
        XCTAssertEqual(member.providerID, "local")
        XCTAssertEqual(member.model, "model")
        XCTAssertFalse(app.enabled)
    }
    func testUnknownManifestIsPreservedInPreviewButRemainsBlocked() throws {
        let (c, service) = try setup()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wizard-unknown-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var package = AgentXLocalAppPackage.template(.conversation, appID: "unknown", providerID: "local", model: "model")
        package.application.manifest?["future-extension"] = .object(["flag": .bool(true)])
        try AgentXPackageFiles.write(package.files(), to: directory)
        let model = AgentXAppManagementModel(controller: c, service: service)
        model.beginImport(directory, directory: true); model.preparePreview()
        XCTAssertEqual(model.preview?.application.manifest?["future-extension"], package.application.manifest?["future-extension"])
        XCTAssertEqual(model.preview?.canInstall, false)
        model.install()
        XCTAssertFalse(c.state.apps.contains { $0.id == "unknown" })
    }
    func testUnavailableServiceAndBlockedPreviewSurfaceFailure() throws {
        let (c, service) = try setup()
        let missing = AgentXAppManagementModel(controller: c, service: nil)
        missing.beginTemplate(.conversation); missing.preparePreview()
        XCTAssertNotNil(missing.failure)
        let model = AgentXAppManagementModel(controller: c, service: service)
        model.beginTemplate(.scene); model.appID = "scene"; model.selection = .init(providerID: "missing", model: "model")
        model.preparePreview()
        XCTAssertFalse(model.preview?.canInstall ?? true)
        model.install()
        XCTAssertFalse(c.state.apps.contains { $0.id == "scene" })
        XCTAssertNotNil(model.failure)
        model.close(); model.beginTemplate(.conversation)
        XCTAssertNil(model.preview); XCTAssertNil(model.selection); XCTAssertNil(model.failure)
    }
    func testUninstallFailureKeepsTargetAndBackupRestoreReloads() async throws {
        let (c, service) = try setup()
        try service.install(service.previewTemplate(.conversation, appID: "remove", providerID: "local", model: "model"))
        let model = AgentXAppManagementModel(controller: c, service: service)
        model.requestUninstall("remove")
        await model.confirmUninstall()
        XCTAssertFalse(c.state.apps.contains { $0.id == "remove" })
        await model.refreshBackups()?.value
        XCTAssertEqual(model.catalog.receipts.count, 1)
        let receipt = try XCTUnwrap(model.catalog.receipts.first)
        model.requestRestore(receipt); model.confirmRestore()
        XCTAssertEqual(c.state.apps.first { $0.id == "remove" }?.enabled, false)
        model.requestRestore(receipt); model.confirmRestore()
        XCTAssertNotNil(model.failure)
    }
    func testPlatformContentIdentitySurvivesApplicationChange() {
        XCTAssertEqual(AgentXAppNavigationPolicy.contentScope(page: .apps, appID: "a"), AgentXAppNavigationPolicy.contentScope(page: .apps, appID: "b"))
        XCTAssertNotEqual(AgentXAppNavigationPolicy.contentScope(page: .chat, appID: "a"), AgentXAppNavigationPolicy.contentScope(page: .chat, appID: "b"))
    }
    func testDisablingCurrentAppKeepsManagementVisible() async throws {
        let (c, service) = try setup()
        try service.install(service.previewTemplate(.conversation, appID: "current", providerID: "local", model: "model"))
        try await c.setApplicationEnabled("current", enabled: true)
        c.openApp("current"); c.navigate(to: .apps)
        try await c.setApplicationEnabled("current", enabled: false)
        XCTAssertEqual(c.page, .apps)
    }
    func testPendingStopCannotReplaceDialogAndFailureNeverRemovesApp() async throws {
        let (c, service) = try setup()
        try service.install(service.previewTemplate(.conversation, appID: "target", providerID: "local", model: "model"))
        var stop: CheckedContinuation<Void, any Error>?
        c.externalRuntimeStop = { _ in try await withCheckedThrowingContinuation { stop = $0 } }
        let model = AgentXAppManagementModel(controller: c, service: service)
        model.requestUninstall("target")
        let token = model.dialog?.id
        let operation = Task { await model.confirmUninstall() }
        for _ in 0..<100 where stop == nil { await Task.yield() }
        let continuation = try XCTUnwrap(stop)
        XCTAssertTrue(model.busy)
        model.close(); model.beginTemplate(.scene); model.requestUninstall("blackcat")
        XCTAssertEqual(model.dialog?.id, token)
        continuation.resume(throwing: AgentXError.invalid("stop failed"))
        await operation.value
        XCTAssertFalse(model.busy)
        XCTAssertNotNil(model.failure)
        XCTAssertTrue(c.state.apps.contains { $0.id == "target" })
        let backups = try await service.backups()
        XCTAssertTrue(backups.receipts.isEmpty)
    }
    func testNativeManagementTemplateAndPreviewRender() async throws {
        _ = NSApplication.shared
        let (c, service) = try setup()
        let model = AgentXAppManagementModel(controller: c, service: service)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 960, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            for width in [960, 1280] {
                for surface in ["installed", "template", "preview", "blocked"] {
                    model.beginTemplate(.scene); model.appID = "render-scene"
                    if surface != "template" { model.selection = .init(providerID: surface == "blocked" ? "missing" : "local", model: "model") }
                    if surface == "preview" || surface == "blocked" { model.preparePreview() }
                    let view = surface == "installed"
                        ? AnyView(ScrollView { AgentXAppManagementView(controller: c, service: service) }.padding().background(Color(nsColor: .windowBackgroundColor)))
                        : AnyView(AgentXAppManagementDialog(controller: c, model: model))
                    let host = NSHostingView(rootView: view)
                    window.contentView = host
                    window.setContentSize(.init(width: surface == "installed" ? width : 680, height: surface == "installed" ? 640 : 550))
                    window.orderFront(nil)
                    try await Task.sleep(for: .milliseconds(40))
                    host.layoutSubtreeIfNeeded()
                    XCTAssertFalse(host.hasAmbiguousLayout)
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    XCTAssertGreaterThan(png.count, 5000)
                    if let output = ProcessInfo.processInfo.environment["AGENTX_RENDER_DIR"] {
                        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
                        try png.write(to: URL(fileURLWithPath: output).appendingPathComponent("management-\(surface)-\(width)-\(appearance.rawValue).png"))
                    }
                }
            }
        }
    }

    func testConvergenceShellAndCreationRenderMatrix() async throws {
        _ = NSApplication.shared
        let (c, service) = try setup()
        try service.install(service.previewTemplate(.conversation, appID: "matrix-app", providerID: "local", model: "model"))
        try await c.setApplicationEnabled("matrix-app", enabled: true)
        c.openApp("matrix-app")
        let model = AgentXAppManagementModel(controller: c, service: service)
        model.beginTemplate(.conversation); model.appID = "matrix-new"
        model.selection = .init(providerID: "local", model: "model")
        model.preparePreview()
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 960, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            for width in [960, 1280] {
                for surface in ["frontend", "backstage", "creation-members", "creation-preview"] {
                    let view: AnyView
                    if surface.hasPrefix("creation") {
                        model.creationStep = surface == "creation-members" ? .members : .preview
                        view = AnyView(AgentXAppCreationView(controller: c, model: model)
                            .frame(width: 680, height: 550)
                            .background(Color(nsColor: .windowBackgroundColor))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color(nsColor: .underPageBackgroundColor)))
                    } else {
                        if surface == "frontend" { c.openFrontend() } else { c.openBackstage() }
                        view = AnyView(AgentXManagerView(controller: c))
                    }
                    let host = NSHostingView(rootView: view)
                    window.contentView = host
                    window.setContentSize(.init(width: width, height: width == 960 ? 640 : 820))
                    try await Task.sleep(for: .milliseconds(80))
                    host.layoutSubtreeIfNeeded()
                    XCTAssertFalse(host.hasAmbiguousLayout)
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    XCTAssertGreaterThan(png.count, 5000)
                    if let output = ProcessInfo.processInfo.environment["AGENTX_RENDER_DIR"] {
                        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
                        try png.write(to: URL(fileURLWithPath: output).appendingPathComponent("convergence-\(surface)-\(width)-\(appearance.rawValue).png"))
                    }
                }
            }
        }
    }

}
