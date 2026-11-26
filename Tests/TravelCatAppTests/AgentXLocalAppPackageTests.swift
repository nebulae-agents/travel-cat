import XCTest
import Yams
import AgentXAppSDK
@testable import TravelCatApp

@MainActor
final class AgentXLocalAppPackageTests: XCTestCase {
    func directory() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("LocalPackage-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func repository() throws -> AgentXRepository {
        let repo = AgentXRepository(root: try directory())
        var state = AgentXState()
        state.providers = [.init(id: "local", name: "Local", baseURL: "http://localhost:1234", models: ["model"])]
        try repo.save(state)
        return repo
    }
    func testTemplateInstallIsDisabledAndCreatesConfiguredInstance() throws {
        let repo = try repository()
        let service = AgentXApplicationLifecycle(repository: repo, requireIdle: { _ in })
        let preview = try service.previewTemplate(.conversation, appID: "notes", providerID: "local", model: "model")
        XCTAssertTrue(preview.missingRequirements.isEmpty)
        try service.install(preview)
        let state = try repo.load()
        XCTAssertEqual(state.apps.first { $0.id == "notes" }?.enabled, false)
        let instance = try XCTUnwrap(state.instances.first { $0.appID == "notes" })
        XCTAssertEqual(instance.providerID, "local")
        XCTAssertEqual(instance.model, "model")
        XCTAssertTrue(state.runs.isEmpty)
        XCTAssertNoThrow(try state.definitions.first { $0.id == instance.definitionID }?.publishedDocument().executionPrompt())
        XCTAssertThrowsError(try service.install(preview))
    }
    func testRuntimeSelectionSurvivesInstallExportAndReimport() throws {
        let repo = try repository()
        let service = AgentXApplicationLifecycle(repository: repo, requireIdle: { _ in })
        for runtime in ["pi-agent-core", "native-http", "host-text"] {
            var package = AgentXLocalAppPackage.template(.conversation, appID: runtime, providerID: "local", model: "model")
            package.application.runtime = runtime
            package.application.manifest?["requires"] = .object(["runtime": .string(runtime)])
            let source = try directory(), exported = try directory().appendingPathComponent("export")
            try AgentXPackageFiles.write(package.files(), to: source)
            let original = try service.preview(directory: source)
            XCTAssertTrue(original.canInstall, original.missingRequirements.joined(separator: ", "))
            try service.install(original)
            try service.exportApplication(runtime, to: exported)
            let copy = try service.preview(directory: exported, appIDOverride: runtime + "-copy")
            XCTAssertTrue(copy.canInstall, copy.missingRequirements.joined(separator: ", "))
            try service.install(copy)
            let installed = try XCTUnwrap(repo.load().apps.first { $0.id == copy.application.id })
            XCTAssertEqual(installed.runtime, runtime)
            XCTAssertEqual(installed.manifest?["requires"]?.object?["runtime"], .string(runtime))
        }
    }

    func testUnknownAndConflictingRuntimeDeclarationsBlockInstallAndExport() throws {
        let repo = try repository()
        let service = AgentXApplicationLifecycle(repository: repo, requireIdle: { _ in })
        try service.install(service.previewTemplate(.conversation, appID: "existing", providerID: "local", model: "model"))
        for (runtime, required) in [("other", "other"), ("native-http", "pi-agent-core")] {
            var package = AgentXLocalAppPackage.template(.conversation, appID: "incoming", providerID: "local", model: "model")
            package.application.runtime = runtime
            package.application.manifest?["requires"] = .object(["runtime": .string(required)])
            let source = try directory()
            try AgentXPackageFiles.write(package.files(), to: source)
            let preview = try service.preview(directory: source)
            XCTAssertFalse(preview.canInstall)
            XCTAssertThrowsError(try service.install(preview))

            var state = try repo.load()
            let index = try XCTUnwrap(state.apps.firstIndex { $0.id == "existing" })
            state.apps[index].runtime = runtime
            state.apps[index].manifest?["requires"] = .object(["runtime": .string(required)])
            try repo.save(state)
            let exported = try directory().appendingPathComponent("export")
            XCTAssertThrowsError(try service.exportApplication("existing", to: exported))
            XCTAssertFalse(FileManager.default.fileExists(atPath: exported.path))
        }
    }

    func testSourceChangeRequiresNewPreviewAndExportRemapsDuplicateIDs() throws {
        let repo = try repository()
        let service = AgentXApplicationLifecycle(repository: repo, requireIdle: { _ in })
        try service.install(service.previewTemplate(.scene, appID: "stage", providerID: "local", model: "model"))
        let exported = try directory().appendingPathComponent("package")
        try service.exportApplication("stage", to: exported)
        let preview = try service.preview(directory: exported, appIDOverride: "second")
        let file = exported.appendingPathComponent("app.yaml")
        var bytes = try Data(contentsOf: file); bytes.append(Data("\n# changed\n".utf8)); try bytes.write(to: file)
        XCTAssertThrowsError(try service.install(preview))
        try service.install(service.preview(directory: exported, appIDOverride: "second"))
        let state = try repo.load()
        XCTAssertEqual(Set(state.instances.map(\.id)).count, 2)
        XCTAssertEqual(Set(state.definitions.map(\.id)).count, 2)
        XCTAssertEqual(state.apps.first { $0.id == "second" }?.experience?.published?.configuration.layout, .scene)
    }
    func testMissingModelAndUnsupportedPayloadAreExplicit() throws {
        let service = AgentXApplicationLifecycle(repository: try repository(), requireIdle: { _ in })
        let preview = try service.previewTemplate(.conversation, appID: "notes", providerID: "missing", model: "none")
        XCTAssertFalse(preview.missingRequirements.isEmpty)
        XCTAssertThrowsError(try service.install(preview))
        let source = try directory()
        try Data("anything".utf8).write(to: source.appendingPathComponent("execute.sh"))
        XCTAssertThrowsError(try service.preview(directory: source))
    }
    func testUninstallVerifiesBackupPreservesAuditAndCanRestore() throws {
        let repo = try repository()
        var calls: [String] = []
        let service = AgentXApplicationLifecycle(repository: repo, requireIdle: { calls.append($0) })
        try service.install(service.previewTemplate(.conversation, appID: "notes", providerID: "local", model: "model"))
        let history = repo.root.appendingPathComponent("apps/notes/private-history.txt")
        try Data("private history".utf8).write(to: history)
        let audit = repo.root.appendingPathComponent("audit/notes.txt")
        try Data("audit unchanged".utf8).write(to: audit)
        let receipt = try service.uninstall("notes")
        XCTAssertEqual(calls, ["notes", "notes"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.path))
        XCTAssertEqual(try Data(contentsOf: receipt.backupURL.appendingPathComponent("app/private-history.txt")), Data("private history".utf8))
        XCTAssertEqual(try String(contentsOf: audit, encoding: .utf8), "audit unchanged")
        try service.restore(receipt)
        XCTAssertEqual(try String(contentsOf: history, encoding: .utf8), "private history")
        XCTAssertEqual(try repo.load().apps.first { $0.id == "notes" }?.enabled, false)
        XCTAssertThrowsError(try service.uninstall("blackcat"))
    }
    func testLinksOversizeAndUnknownCapabilitiesAreRejected() throws {
        let repo = try repository()
        let service = AgentXApplicationLifecycle(repository: repo, requireIdle: { _ in })
        let source = try directory()
        try AgentXPackageFiles.write(AgentXLocalAppPackage.template(.conversation, appID: "x", providerID: "local", model: "model").files(), to: source)
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("linked.yaml").path, withDestinationPath: "/etc/hosts")
        XCTAssertThrowsError(try service.preview(directory: source))
        try FileManager.default.removeItem(at: source.appendingPathComponent("linked.yaml"))
        let app = source.appendingPathComponent("app.yaml")
        var text = try String(contentsOf: app, encoding: .utf8)
        text += "\nfrontend: arbitrary.js\n"
        try Data(text.utf8).write(to: app)
        XCTAssertThrowsError(try service.preview(directory: source))
    }
    func testMutationFailureRollsBackAndIdleBarrierPrecedesWrites() throws {
        let repo = try repository()
        let blocked = AgentXApplicationLifecycle(repository: repo, requireIdle: { _ in throw AgentXError.unavailable })
        let preview = try blocked.previewTemplate(.conversation, appID: "x", providerID: "local", model: "model")
        let before = try AgentXPackageFiles.snapshot(repo.root)
        XCTAssertThrowsError(try blocked.install(preview))
        XCTAssertEqual(try AgentXPackageFiles.snapshot(repo.root), before)
        let failing = AgentXApplicationLifecycle(repository: repo, requireIdle: { _ in }, mutationCheckpoint: { point in
            if point == "publishedBeforeSettings" { throw AgentXError.unavailable }
        })
        XCTAssertThrowsError(try failing.install(preview))
        XCTAssertEqual(try AgentXPackageFiles.snapshot(repo.root), before)
        let service = AgentXApplicationLifecycle(repository: repo, requireIdle: { _ in })
        try service.install(preview)
        let own = try AgentXPackageFiles.snapshot(repo.root.appendingPathComponent("apps/x"))
        XCTAssertThrowsError(try failing.uninstall("x"))
        XCTAssertEqual(try AgentXPackageFiles.snapshot(repo.root.appendingPathComponent("apps/x")), own)
        XCTAssertNotNil(try repo.load().apps.first { $0.id == "x" })
    }
    func testExportDoesNotIncludeHistoryMemoryCredentialReferencesOrUnknownManifest() throws {
        let repo = try repository()
        let service = AgentXApplicationLifecycle(repository: repo, requireIdle: { _ in })
        try service.install(service.previewTemplate(.conversation, appID: "x", providerID: "local", model: "model"))
        try Data("secret history".utf8).write(to: repo.root.appendingPathComponent("apps/x/conversation.json"))
        var state = try repo.load()
        let index = try XCTUnwrap(state.apps.firstIndex { $0.id == "x" })
        state.apps[index].manifest?["private_key"] = .string("SECRET_KEY")
        state.apps[index].experience?.draft?.sharedMemory = "PRIVATE_MEMORY"
        try repo.save(state)
        let destination = try directory().appendingPathComponent("export")
        try service.exportApplication("x", to: destination)
        let text = try AgentXPackageFiles.snapshot(destination).values.map { String(decoding: $0, as: UTF8.self) }.joined()
        for forbidden in ["secret history", "PRIVATE_MEMORY", "SECRET_KEY", "credentialProfile"] { XCTAssertFalse(text.contains(forbidden)) }
    }
    func testZIPPreviewAndChangedArchiveAndUnsafePaths() throws {
        let repo = try repository()
        let service = AgentXApplicationLifecycle(repository: repo, requireIdle: { _ in })
        let source = try directory()
        try AgentXPackageFiles.write(AgentXLocalAppPackage.template(.conversation, appID: "zipapp", providerID: "local", model: "model").files(), to: source)
        let archive = try directory().appendingPathComponent("package.zip")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = source; process.arguments = ["-qr", archive.path, "."]
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        let preview = try service.preview(zip: archive)
        XCTAssertTrue(preview.canInstall)
        try service.install(preview)
        let data = try Data(contentsOf: archive)
        try (data + Data([0])).write(to: archive)
        XCTAssertThrowsError(try service.install(preview))
        for path in ["../evil", "/absolute", "a\\b", "a/../b", "a\0b"] { XCTAssertThrowsError(try AgentXPackageFiles.validatePath(path)) }
        try Data(repeating: 0, count: AgentXPackageFiles.maximumBytes + 1).write(to: archive)
        XCTAssertThrowsError(try service.preview(zip: archive))
    }

    func testDeclarationFrontendSurvivesInstallExportAndIDRemap() throws {
        let repo = try repository()
        let service = AgentXApplicationLifecycle(repository: repo, requireIdle: { _ in })
        var package = AgentXLocalAppPackage.template(.conversation, appID: "forms", providerID: "local", model: "model")
        package.application.modules = ["compose"]
        var files = try package.files()
        let contract = AppFrontendContract(title: "Compose", modules: [.init(id: "compose", title: "Compose", fields: [.init(id: "topic", label: "Topic")], submit: .init(title: "Send", prompt: "Write about {{topic}}"))])
        files["payload/frontend.json"] = try JSONEncoder().encode(contract)
        files["manifest.json"] = try JSONEncoder().encode(AppManifest(id: "forms", name: package.application.name, version: "1", dataSchemaVersion: 1, hostAPIMajor: 1, kind: "chat", runtime: "host-text", modules: ["compose"]))
        let source = try directory()
        try AgentXPackageFiles.write(files, to: source)
        try service.install(service.preview(directory: source, appIDOverride: "forms-copy"))
        let installed = try AgentXFrontendStore(root: repo.root, appID: "forms-copy").load()
        XCTAssertEqual(installed.0, contract)
        try AgentXFrontendStore(root: repo.root, appID: "forms-copy").save(["compose": ["topic": "Private user input"]])
        let exported = try directory().appendingPathComponent("export")
        try service.exportApplication("forms-copy", to: exported)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.appendingPathComponent("payload/frontend.json").path))
        try service.install(service.preview(directory: exported, appIDOverride: "forms-again"))
        XCTAssertEqual(try AgentXFrontendStore(root: repo.root, appID: "forms-again").load().0, contract)
    }
    func testFormManifestCannotMaskAnExplicitAdapterInAppYAML() throws {
        let repo = try repository()
        let service = AgentXApplicationLifecycle(repository: repo, requireIdle: { _ in })
        var package = AgentXLocalAppPackage.template(.conversation, appID: "form", providerID: "local", model: "model")
        package.application.modules = ["compose"]
        package.frontend = AppFrontendContract(title: "Compose", modules: [
            .init(id: "compose", title: "Compose", fields: [.init(id: "topic", label: "Topic")],
                  submit: .init(title: "Send", prompt: "Write about {{topic}}"))
        ])
        var files = try package.files()
        for runtime in ["pi-agent-core", "native-http"] {
            package.application.runtime = runtime
            files["app.yaml"] = Data(try YAMLEncoder().encode(package.application).utf8)
            let source = try directory()
            try AgentXPackageFiles.write(files, to: source)
            XCTAssertThrowsError(try service.preview(directory: source))
        }
    }

    func testOmittedRuntimeRemainsLegacyAndExplicitRequirementCannotSelectAdapter() throws {
        let service = AgentXApplicationLifecycle(repository: try repository(), requireIdle: { _ in })
        var package = AgentXLocalAppPackage.template(.conversation, appID: "legacy", providerID: "local", model: "model")
        package.application.runtime = nil
        let source = try directory()
        try AgentXPackageFiles.write(package.files(), to: source)
        let legacy = try service.preview(directory: source)
        XCTAssertTrue(legacy.canInstall)
        XCTAssertNil(legacy.application.runtime)
        package.application.manifest?["requires"] = .object(["runtime": .string("pi-agent-core")])
        try AgentXPackageFiles.write(package.files(), to: source)
        let conflicting = try service.preview(directory: source)
        XCTAssertFalse(conflicting.canInstall)
    }

    func testSceneModulesAndMemberReferencesAreRemapped() throws {
        let repo = try repository(), source = try directory()
        let service = AgentXApplicationLifecycle(repository: repo, requireIdle: { _ in })
        var package = AgentXLocalAppPackage.template(.scene, appID: "scene", providerID: "local", model: "model")
        package.application.modules = ["stage", "world-state", "npc-memory", "director-intervention"]
        package.application.experience?.draft?.memberOverrides = [.init(instanceID: "assistant", providerID: "local", model: "model")]
        package.application.experience?.revisions[0].configuration.memberOverrides = [.init(instanceID: "assistant", providerID: "local", model: "model")]
        let workflow = AgentXWorkflowDefinition(name: "Conversation", steps: [.init(name: "Answer", instanceID: "assistant", instruction: "Answer")])
        package.application.workflow = .init(draft: workflow, revisions: [.init(number: 1, definition: workflow, publishedAt: Date())], publishedRevision: 1)
        try AgentXPackageFiles.write(package.files(), to: source)
        let preview = try service.preview(directory: source, appIDOverride: "scene-copy")
        XCTAssertTrue(preview.canInstall)
        try service.install(preview)
        let state = try repo.load(), instance = try XCTUnwrap(state.instances.first { $0.appID == "scene-copy" })
        let app = try XCTUnwrap(state.apps.first { $0.id == "scene-copy" })
        XCTAssertEqual(app.experience?.draft?.memberOverrides.first?.instanceID, instance.id)
        XCTAssertEqual(app.experience?.published?.configuration.memberOverrides.first?.instanceID, instance.id)
        XCTAssertEqual(app.workflow?.published?.definition.steps.first?.instanceID, instance.id)
        XCTAssertEqual(app.workflow?.draft?.steps.first?.instanceID, instance.id)
    }
    func testRestoreIncludesEmptyDirectoriesAndReinstallAfterUninstallWorks() throws {
        let repo = try repository()
        let service = AgentXApplicationLifecycle(repository: repo, requireIdle: { _ in })
        try service.install(service.previewTemplate(.conversation, appID: "x", providerID: "local", model: "model"))
        let empty = repo.root.appendingPathComponent("apps/x/private/empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let receipt = try service.uninstall("x")
        try service.restore(receipt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: empty.path))
        _ = try service.uninstall("x")
        XCTAssertNoThrow(try service.install(service.previewTemplate(.conversation, appID: "x", providerID: "local", model: "model")))
    }
    func testZIPRejectsTraversalDuplicatesLinksEncryptionSpecialFilesAndBombs() throws {
        func archive(_ names: [String], mode: Int = 0x8000, flags: Int = 0, advertisedSize: Int = 0, method: Int = 0) -> Data {
            func integer(_ value: Int, _ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }) }
            var local = Data(), central = Data()
            for name in names {
                let bytes = Data(name.utf8), offset = local.count
                local += integer(0x04034b50, 4) + integer(20, 2) + integer(flags, 2) + integer(method, 2) + Data(repeating: 0, count: 8)
                local += integer(0, 4) + integer(advertisedSize, 4) + integer(bytes.count, 2) + integer(0, 2) + bytes
                central += integer(0x02014b50, 4) + integer(0x0314, 2) + integer(20, 2) + integer(flags, 2) + integer(method, 2) + Data(repeating: 0, count: 8)
                central += integer(0, 4) + integer(advertisedSize, 4) + integer(bytes.count, 2) + Data(repeating: 0, count: 8) + integer(mode << 16, 4) + integer(offset, 4) + bytes
            }
            let end = integer(0x06054b50, 4) + Data(repeating: 0, count: 4) + integer(names.count, 2) + integer(names.count, 2) + integer(central.count, 4) + integer(local.count, 4) + Data(repeating: 0, count: 2)
            return local + central + end
        }
        XCTAssertNoThrow(try AgentXLocalAppZIP.entries(archive(["app.yaml"])))
        for name in ["../evil", "/absolute", "a\\b", "a/../b", "a\0b"] { XCTAssertThrowsError(try AgentXLocalAppZIP.entries(archive([name]))) }
        XCTAssertThrowsError(try AgentXLocalAppZIP.entries(archive(["a", "A"])))
        XCTAssertThrowsError(try AgentXLocalAppZIP.entries(archive(["a", "a/b"])))
        XCTAssertThrowsError(try AgentXLocalAppZIP.entries(archive(["a"], mode: 0xa000)))
        XCTAssertThrowsError(try AgentXLocalAppZIP.entries(archive(["a"], mode: 0x1000)))
        XCTAssertThrowsError(try AgentXLocalAppZIP.entries(archive(["a"], flags: 1)))
        XCTAssertThrowsError(try AgentXLocalAppZIP.entries(archive(["a"], advertisedSize: 9_000_000, method: 8)))
        XCTAssertThrowsError(try AgentXLocalAppZIP.entries(archive((0...256).map { "entry-\($0)" })))
    }

}
