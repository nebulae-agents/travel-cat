import XCTest
import Yams
@testable import TravelCatApp

@MainActor
final class AgentXApplicationLifecycleTests: XCTestCase {
    func repository() throws -> AgentXRepository {
        let root = URL(fileURLWithPath: "/private/tmp/Lifecycle-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repository = AgentXRepository(root: root)
        var state = AgentXState()
        state.providers = [.init(id: "local", name: "Local", baseURL: "http://localhost:1234", models: ["model"])]
        state.apps.append(.init(id: "untouched", name: "Other", kind: .chat))
        try repository.save(state)
        return repository
    }
    func testBackgroundBackupReaderVerifiesRealCatalogAndHonorsCancellation() async throws {
        let repo = try repository()
        let service = AgentXApplicationLifecycle(repository: repo, requireIdle: { _ in })
        try service.install(service.previewTemplate(.conversation, appID: "async-backup", providerID: "local", model: "model"))
        let receipt = try service.uninstall("async-backup")
        let reader = AgentXApplicationBackupReader(root: repo.root)
        let catalog = try await reader.load()
        XCTAssertEqual(catalog.receipts, [receipt])
        let cancelled = Task { try await reader.load() }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancelled scans must not publish results") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        try Data("changed".utf8).write(to: receipt.backupURL.appendingPathComponent("app/changed"))
        let changed = try await reader.load()
        XCTAssertTrue(changed.receipts.isEmpty)
        XCTAssertEqual(changed.warnings.count, 1)
    }
    func testBackupCatalogSurvivesRestartAndSkipsTamperedOrLinkedReceipts() throws {
        let repo = try repository()
        let service = AgentXApplicationLifecycle(repository: repo, requireIdle: { _ in })
        try service.install(service.previewTemplate(.conversation, appID: "catalog", providerID: "local", model: "model"))
        let receipt = try service.uninstall("catalog")
        let restarted = AgentXApplicationLifecycle(repository: repo, requireIdle: { _ in })
        XCTAssertEqual(try restarted.backups().receipts, [receipt])
        let receiptURL = receipt.backupURL.appendingPathComponent("receipt.json")
        try Data("{}".utf8).write(to: receiptURL)
        XCTAssertTrue(try restarted.backups().receipts.isEmpty)
        XCTAssertEqual(try restarted.backups().warnings.count, 1)
        try FileManager.default.removeItem(at: receiptURL)
        try FileManager.default.createSymbolicLink(at: receiptURL, withDestinationURL: repo.root.appendingPathComponent("agentx.yaml"))
        XCTAssertTrue(try restarted.backups().receipts.isEmpty)
        XCTAssertEqual(try restarted.backups().warnings.count, 1)
    }
    func testBackupCatalogRejectsOutsideReceiptAndSnapshotChanges() throws {
        let repo = try repository()
        let service = AgentXApplicationLifecycle(repository: repo, requireIdle: { _ in })
        try service.install(service.previewTemplate(.scene, appID: "catalog", providerID: "local", model: "model"))
        let receipt = try service.uninstall("catalog")
        let forged = AgentXApplicationBackup(id: receipt.id, appID: receipt.appID, backupURL: repo.root, digest: receipt.digest)
        try JSONEncoder().encode(forged).write(to: receipt.backupURL.appendingPathComponent("receipt.json"))
        XCTAssertTrue(try service.backups().receipts.isEmpty)
        try JSONEncoder().encode(receipt).write(to: receipt.backupURL.appendingPathComponent("receipt.json"))
        try Data("changed".utf8).write(to: receipt.backupURL.appendingPathComponent("app/changed"))
        XCTAssertTrue(try service.backups().receipts.isEmpty)
    }
    func testInterruptedPublishRecoveryRunsBeforeAppEnumeration() throws {
        let repo = try repository()
        let settings = try Data(contentsOf: repo.root.appendingPathComponent("agentx.yaml"))
        let stage = ".agentx-local-" + UUID().uuidString.lowercased()
        try FileManager.default.createDirectory(at: repo.root.appendingPathComponent(stage), withIntermediateDirectories: false)
        let staged = repo.root.appendingPathComponent(stage + "/new-0")
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: false)
        try Data("incomplete".utf8).write(to: staged.appendingPathComponent("app.yaml"))
        let journal = try AgentXLocalAppTransaction.prepare(root: repo.root, stage: stage, additions: ["apps/partial"], removing: nil, settings: settings, expectedSettings: settings)
        try journal.write(root: repo.root)
        let target = repo.root.appendingPathComponent("apps/partial")
        try FileManager.default.moveItem(at: staged, to: target)
        XCTAssertNoThrow(try repo.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try Data(contentsOf: repo.root.appendingPathComponent("agentx.yaml")), settings)
    }
    func testMissingRecoveryStageMustNotDeleteExistingApp() throws {
        let repo = try repository()
        let before = try AgentXPackageFiles.snapshot(repo.root.appendingPathComponent("apps/untouched"))
        let journal = AgentXLocalAppTransaction(stage: ".agentx-local-" + UUID().uuidString.lowercased(), additions: ["apps/untouched"], removing: nil, settings: Data("version: 1".utf8))
        try JSONEncoder().encode(journal).write(to: repo.root.appendingPathComponent(AgentXLocalAppTransaction.filename))
        XCTAssertThrowsError(try repo.load())
        XCTAssertEqual(try AgentXPackageFiles.snapshot(repo.root.appendingPathComponent("apps/untouched")), before)
    }
    func testRecoveryPreflightsEveryPathBeforeMutatingAnyApp() throws {
        let repo = try repository()
        let before = try AgentXPackageFiles.snapshot(repo.root.appendingPathComponent("apps/untouched"))
        let journal = AgentXLocalAppTransaction(stage: ".agentx-local-" + UUID().uuidString.lowercased(), additions: ["apps/untouched", "../outside"], removing: nil, settings: Data())
        try JSONEncoder().encode(journal).write(to: repo.root.appendingPathComponent(AgentXLocalAppTransaction.filename))
        XCTAssertThrowsError(try repo.load())
        XCTAssertEqual(try AgentXPackageFiles.snapshot(repo.root.appendingPathComponent("apps/untouched")), before)
    }
    func testUninstallKeepsOtherAppAuditAndUnknownRootSettingsAndRejectsTamperedBackup() throws {
        let repo = try repository()
        let service = AgentXApplicationLifecycle(repository: repo, requireIdle: { _ in })
        try service.install(service.previewTemplate(.conversation, appID: "target", providerID: "local", model: "model"))
        let other = try AgentXPackageFiles.snapshot(repo.root.appendingPathComponent("apps/untouched"))
        let audit = repo.root.appendingPathComponent("audit/target/events.jsonl")
        try FileManager.default.createDirectory(at: audit.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("audit bytes\n".utf8).write(to: audit)
        let settingsURL = repo.root.appendingPathComponent("agentx.yaml")
        var settings = try String(contentsOf: settingsURL, encoding: .utf8)
        settings += "\nuser_extension:\n  keep: 123\n"
        try Data(settings.utf8).write(to: settingsURL)
        let receipt = try service.uninstall("target")
        XCTAssertEqual(try AgentXPackageFiles.snapshot(repo.root.appendingPathComponent("apps/untouched")), other)
        XCTAssertEqual(try Data(contentsOf: audit), Data("audit bytes\n".utf8))
        let saved = try XCTUnwrap(Yams.load(yaml: String(contentsOf: settingsURL, encoding: .utf8)) as? [String: Any])
        XCTAssertEqual((saved["user_extension"] as? [String: Int])?["keep"], 123)
        try Data("tamper".utf8).write(to: receipt.backupURL.appendingPathComponent("app/newfile"))
        XCTAssertThrowsError(try service.restore(receipt))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.root.appendingPathComponent("apps/target").path))
    }
    func testEnabledApplicationAndUnverifiedStopCannotUninstall() throws {
        let repo = try repository()
        let service = AgentXApplicationLifecycle(repository: repo, requireIdle: { _ in })
        XCTAssertThrowsError(try service.uninstall("untouched"))
        try service.install(service.previewTemplate(.conversation, appID: "target", providerID: "local", model: "model"))
        let blocked = AgentXApplicationLifecycle(repository: repo, requireIdle: { _ in throw AgentXError.unavailable })
        let before = try AgentXPackageFiles.snapshot(repo.root)
        XCTAssertThrowsError(try blocked.uninstall("target"))
        XCTAssertEqual(try AgentXPackageFiles.snapshot(repo.root), before)
    }
    func testUnknownInstanceFieldsAndManifestCapabilitiesAreNotSilentlyReady() throws {
        let repo = try repository()
        let service = AgentXApplicationLifecycle(repository: repo, requireIdle: { _ in })
        var package = AgentXLocalAppPackage.template(.conversation, appID: "target", providerID: "local", model: "model")
        let source = URL(fileURLWithPath: "/private/tmp/Source-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: source) }
        var files = try package.files()
        files["instances/assistant/config/agent.yaml"]!.append(Data("\napi_key: secret\n".utf8))
        try AgentXPackageFiles.write(files, to: source)
        XCTAssertThrowsError(try service.preview(directory: source))
        package.application.manifest?["requires"] = .object(["runtime": .string("host-text"), "tools": .array([.string("shell")])])
        try AgentXPackageFiles.write(package.files(), to: source)
        XCTAssertFalse(try service.preview(directory: source).canInstall)
    }
    func testRecoveryCannotDeleteUnownedDirectoryEvenWithExistingStage() throws {
        let repo = try repository()
        let before = try AgentXPackageFiles.snapshot(repo.root.appendingPathComponent("apps/untouched"))
        let stage = ".agentx-local-" + UUID().uuidString.lowercased()
        try FileManager.default.createDirectory(at: repo.root.appendingPathComponent(stage), withIntermediateDirectories: false)
        let journal = AgentXLocalAppTransaction(stage: stage, additions: ["apps/untouched"], removing: nil, settings: Data("version: 1".utf8))
        try JSONEncoder().encode(journal).write(to: repo.root.appendingPathComponent(AgentXLocalAppTransaction.filename))
        XCTAssertThrowsError(try repo.load())
        XCTAssertEqual(try AgentXPackageFiles.snapshot(repo.root.appendingPathComponent("apps/untouched")), before)
    }
    func testLifecyclePreservesUnknownLargeUnsignedAndQuotedNumericSettings() throws {
        let repo = try repository()
        let url = repo.root.appendingPathComponent("agentx.yaml")
        var source = try String(contentsOf: url, encoding: .utf8)
        source += "\ncustom:\n  deep:\n    maximum: 18446744073709551615\n    quoted: \"18446744073709551615\"\n"
        try Data(source.utf8).write(to: url)
        let service = AgentXApplicationLifecycle(repository: repo, requireIdle: { _ in })
        try service.install(service.previewTemplate(.conversation, appID: "target", providerID: "local", model: "model"))
        struct Settings: Decodable { struct Custom: Decodable { struct Deep: Decodable { let maximum: UInt64; let quoted: String }; let deep: Deep }; let custom: Custom }
        let installed = try YAMLDecoder().decode(Settings.self, from: String(contentsOf: url, encoding: .utf8))
        XCTAssertEqual(installed.custom.deep.maximum, UInt64.max)
        XCTAssertEqual(installed.custom.deep.quoted, "18446744073709551615")
        let parsed = try Yams.compose(yaml: String(contentsOf: url, encoding: .utf8))
        XCTAssertEqual(parsed?["custom"]?["deep"]?["maximum"]?.tag, Tag(.int))
        XCTAssertEqual(parsed?["custom"]?["deep"]?["quoted"]?.tag, Tag(.str))
        _ = try service.uninstall("target")
        let removed = try Yams.compose(yaml: String(contentsOf: url, encoding: .utf8))
        XCTAssertEqual(removed?["custom"]?["deep"]?["maximum"]?.tag, Tag(.int))
        XCTAssertEqual(removed?["custom"]?["deep"]?["quoted"]?.tag, Tag(.str))
    }

    func testRecoveryPreflightsOwnershipOfAllPublishedTargetsBeforeDeletion() throws {
        let repo = try repository(), fm = FileManager.default
        let settings = try Data(contentsOf: repo.root.appendingPathComponent("agentx.yaml"))
        let stage = ".agentx-local-" + UUID().uuidString.lowercased()
        for index in 0..<2 {
            try AgentXPackageFiles.write(["data": Data("owned".utf8)], to: repo.root.appendingPathComponent(stage + "/new-\(index)"))
        }
        let journal = try AgentXLocalAppTransaction.prepare(root: repo.root, stage: stage, additions: ["apps/first", "apps/second"], removing: nil, settings: settings, expectedSettings: settings)
        try journal.write(root: repo.root)
        try fm.moveItem(at: repo.root.appendingPathComponent(stage + "/new-0"), to: repo.root.appendingPathComponent("apps/first"))
        try fm.moveItem(at: repo.root.appendingPathComponent(stage + "/new-1"), to: repo.root.appendingPathComponent("apps/second"))
        let replacement = repo.root.appendingPathComponent("replacement")
        try AgentXPackageFiles.write(["data": Data("owned".utf8)], to: replacement)
        try fm.removeItem(at: repo.root.appendingPathComponent("apps/second"))
        try fm.moveItem(at: replacement, to: repo.root.appendingPathComponent("apps/second"))
        XCTAssertThrowsError(try AgentXLocalAppTransaction.recover(root: repo.root))
        XCTAssertTrue(fm.fileExists(atPath: repo.root.appendingPathComponent("apps/first/data").path))
        XCTAssertTrue(fm.fileExists(atPath: repo.root.appendingPathComponent("apps/second/data").path))
    }
    func testInterruptedRemovalRestoresOwnedDirectoryAndRefusesChangedSettings() throws {
        let repo = try repository(), fm = FileManager.default
        let settingsURL = repo.root.appendingPathComponent("agentx.yaml")
        let settings = try Data(contentsOf: settingsURL)
        let stage = ".agentx-local-" + UUID().uuidString.lowercased()
        try fm.createDirectory(at: repo.root.appendingPathComponent(stage), withIntermediateDirectories: false)
        let journal = try AgentXLocalAppTransaction.prepare(root: repo.root, stage: stage, additions: [], removing: "apps/untouched", settings: settings, expectedSettings: Data("version: 1".utf8))
        try journal.write(root: repo.root)
        try fm.moveItem(at: repo.root.appendingPathComponent("apps/untouched"), to: repo.root.appendingPathComponent(stage + "/removed"))
        try Data("manually changed settings".utf8).write(to: settingsURL)
        XCTAssertThrowsError(try AgentXLocalAppTransaction.recover(root: repo.root))
        XCTAssertTrue(fm.fileExists(atPath: repo.root.appendingPathComponent(stage + "/removed/app.yaml").path))
        try settings.write(to: settingsURL)
        try AgentXLocalAppTransaction.recover(root: repo.root)
        XCTAssertNotNil(try repo.load().apps.first { $0.id == "untouched" })
    }

    func testExportRejectsPinnedRevisionThatWouldChangePromptWithoutCreatingDestination() throws {
        let repo = try repository()
        let service = AgentXApplicationLifecycle(repository: repo, requireIdle: { _ in })
        try service.install(service.previewTemplate(.conversation, appID: "target", providerID: "local", model: "model"))
        var state = try repo.load()
        let instanceIndex = try XCTUnwrap(state.instances.firstIndex { $0.appID == "target" })
        let definitionIndex = try XCTUnwrap(state.definitions.firstIndex { $0.id == state.instances[instanceIndex].definitionID })
        state.definitions[definitionIndex].revisions = [.init(number: 1, document: .init(source: "Pinned old prompt")), .init(number: 2, document: .init(source: "Latest different prompt"))]
        state.definitions[definitionIndex].publishedRevision = 2
        state.instances[instanceIndex].definitionRevision = 1
        try repo.save(state)
        let exportParent = URL(fileURLWithPath: "/private/tmp/PinnedExport-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: exportParent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: exportParent) }
        let destination = exportParent.appendingPathComponent("export")
        let before = try AgentXPackageFiles.snapshot(repo.root)
        XCTAssertThrowsError(try service.exportApplication("target", to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try AgentXPackageFiles.snapshot(repo.root), before)
        state.instances[instanceIndex].definitionRevision = 2
        try repo.save(state)
        XCTAssertNoThrow(try service.exportApplication("target", to: destination))
    }
    func testPreviewRejectsMalformedManifestSectionsBeforeConfirmation() throws {
        let repo = try repository(), service = AgentXApplicationLifecycle(repository: repo, requireIdle: { _ in })
        let source = URL(fileURLWithPath: "/private/tmp/MalformedPackage-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: source) }
        for bad in [
            ["requires": AgentXManifestValue.object(["providers": .string("local")])],
            ["permissions": AgentXManifestValue.string("all")],
            ["requires": AgentXManifestValue.string("host-text")]
        ] {
            var package = AgentXLocalAppPackage.template(.conversation, appID: "target", providerID: "local", model: "model")
            package.application.manifest = bad
            try AgentXPackageFiles.write(package.files(), to: source)
            XCTAssertThrowsError(try service.preview(directory: source))
        }
    }

    func testLegacyDisabledProjectionBackupRestoresOriginalManifestBytes() throws {
        let repo = try repository()
        let service = AgentXApplicationLifecycle(repository: repo, requireIdle: { _ in })
        try service.install(service.previewTemplate(.conversation, appID: "target", providerID: "local", model: "model"))
        let appURL = repo.root.appendingPathComponent("apps/target/app.yaml")
        let legacy = try String(contentsOf: appURL, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.hasPrefix("enabled:") }.joined(separator: "\n")
        try Data(legacy.utf8).write(to: appURL)
        XCTAssertEqual(try repo.load().apps.first { $0.id == "target" }?.enabled, false)
        let receipt = try service.uninstall("target")
        try service.restore(receipt)
        XCTAssertEqual(try Data(contentsOf: appURL), Data(legacy.utf8))
        XCTAssertEqual(try repo.load().apps.first { $0.id == "target" }?.enabled, false)
    }
    func testExportImportPreservesPromptBodyThatBeginsWithFrontmatter() throws {
        let repo = try repository()
        let service = AgentXApplicationLifecycle(repository: repo, requireIdle: { _ in })
        try service.install(service.previewTemplate(.conversation, appID: "target", providerID: "local", model: "model"))
        var state = try repo.load()
        let index = try XCTUnwrap(state.definitions.firstIndex { $0.id == state.instances.first { $0.appID == "target" }?.definitionID })
        let original = "---\nname: outer\n---\n---\nname: example\n---\nActual text"
        state.definitions[index].prompt = original
        state.definitions[index].draft = .init(source: original)
        try repo.save(state)
        let expected = try AgentXDefinitionDocument(source: original).executionPrompt()
        XCTAssertEqual(expected, "---\nname: example\n---\nActual text")
        let parent = URL(fileURLWithPath: "/private/tmp/PromptExport-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("package")
        try service.exportApplication("target", to: destination)
        try service.install(service.preview(directory: destination, appIDOverride: "copy"))
        let installed = try repo.load()
        let copied = try XCTUnwrap(installed.instances.first { $0.appID == "copy" })
        let definition = try XCTUnwrap(installed.definitions.first { $0.id == copied.definitionID })
        XCTAssertEqual(try definition.publishedDocument().executionPrompt(), expected)
    }

    func testLegacyProjectionReceiptCannotAuthorizeExplicitEnabledTrueBackup() throws {
        let repo = try repository()
        let service = AgentXApplicationLifecycle(repository: repo, requireIdle: { _ in })
        try service.install(service.previewTemplate(.conversation, appID: "target", providerID: "local", model: "model"))
        let receipt = try service.uninstall("target")
        let appURL = receipt.backupURL.appendingPathComponent("app/app.yaml")
        let text = try String(contentsOf: appURL, encoding: .utf8).replacingOccurrences(of: "enabled: false", with: "enabled: true")
        try Data(text.utf8).write(to: appURL)
        let forged = AgentXApplicationBackup(id: receipt.id, appID: receipt.appID, backupURL: receipt.backupURL, digest: try AgentXPackageFiles.fullSnapshot(receipt.backupURL.appendingPathComponent("app")).digest, legacyDisabledProjection: true)
        try JSONEncoder().encode(forged).write(to: receipt.backupURL.appendingPathComponent("receipt.json"))
        XCTAssertThrowsError(try service.restore(forged))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.root.appendingPathComponent("apps/target").path))
    }

}
