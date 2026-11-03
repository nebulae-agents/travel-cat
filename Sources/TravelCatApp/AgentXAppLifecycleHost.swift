import Foundation
import AgentXAppSDK
import Yams
#if canImport(Darwin)
import Darwin
#endif

/// Host adapter for app.yaml identity and the SDK's independently-versioned manifest.json.
/// All calls are synchronous. The caller must hold a real stop-writing barrier for their duration;
/// the readiness closure is a check, not a process lock. No imported payload code is executed.
final class AgentXAppLifecycleHost {
    enum Failure: LocalizedError {
        case busy, invalidPackage, missingBaseline, migrationRequired, alreadyInstalled, metadataMismatch, unsafePath
        var errorDescription: String? {
            switch self {
            case .busy: "应用仍在运行或写入，请等待所有执行器停止后再操作。"
            case .invalidPackage: "应用包格式、应用类型或宿主 API 不兼容。"
            case .missingBaseline: "应用尚未声明独立版本，请先显式登记版本与数据 schema。"
            case .migrationRequired: "新版本的数据 schema 不同；宿主尚未提供已授权的可信迁移，原应用与数据保持不变。"
            case .alreadyInstalled: "目标应用或导出目录已存在；请使用升级，不能覆盖导入。"
            case .metadataMismatch: "app.yaml 与应用 manifest 身份不一致，未修改应用。"
            case .unsafePath: "应用路径包含链接、特殊文件或越界目录。"
            }
        }
    }
    let root: URL
    private let major: Int
    private let writersHaveStopped: () -> Bool
    private let sdk: AppUpgradeManager
    private let fm = FileManager.default

    init(root: URL, hostAPIMajor: Int, writersHaveStopped: @escaping () -> Bool) throws {
        self.root = root; self.major = hostAPIMajor; self.writersHaveStopped = writersHaveStopped
        sdk = try AppUpgradeManager(root: root, hostAPIMajor: hostAPIMajor)
    }

    /// Read-only metadata for a management surface; does not imply the app payload is executable.
    func inspectApplication(appID: String) throws -> AppManifest? {
        let app = try appDirectory(appID)
        let file = app.appendingPathComponent("manifest.json")
        guard fm.fileExists(atPath: file.path) else { return nil }
        return try installedManifest(app)
    }

    /// Explicitly establishes a baseline for an existing app; no version/schema is guessed.
    /// Existing user directories and app.yaml remain unchanged. Re-registering is refused.
    func register(appID: String, manifest: AppManifest) throws {
        try requireIdle()
        let app = try appDirectory(appID)
        try validateTree(app)
        try validateManifest(manifest)
        let metadata = try readYAML(app)
        try checkIdentity(metadata, manifest: manifest)
        guard manifest.id == appID else { throw Failure.metadataMismatch }
        let target = app.appendingPathComponent("manifest.json")
        guard !fm.fileExists(atPath: target.path) else { throw Failure.alreadyInstalled }
        let payload = app.appendingPathComponent("payload")
        if !fm.fileExists(atPath: payload.path) { try fm.createDirectory(at: payload, withIntermediateDirectories: false) }
        try requireDirectory(payload)
        try JSONEncoder().encode(manifest).write(to: target, options: .atomic)
    }

    /// Exports executable/resource payload and manifest only, never user state, runs or host secrets.
    func exportPackage(appID: String, to destination: URL) throws {
        try requireIdle()
        let app = try appDirectory(appID)
        try validateTree(app)
        let manifest = try installedManifest(app)
        try checkIdentity(readYAML(app), manifest: manifest)
        try validateDestination(destination)
        guard !isWithin(destination, root) else { throw Failure.unsafePath }
        let scratch = try temporaryDirectory()
        defer { try? fm.removeItem(at: scratch) }
        let package = scratch.appendingPathComponent("package")
        try fm.createDirectory(at: package, withIntermediateDirectories: false)
        try JSONEncoder().encode(manifest).write(to: package.appendingPathComponent("manifest.json"))
        try fm.copyItem(at: app.appendingPathComponent("payload"), to: package.appendingPathComponent("payload"))
        _ = try sdk.inspectPackage(package)
        try copier.importVerifiedTree(from: package, to: destination, isIdle: true)
    }

    /// Explicit full backup, including app-owned private state. Not an installable code package.
    func backupApplication(appID: String, to destination: URL) throws {
        try requireIdle()
        try requireNoPendingTransaction(appID)
        let app = try appDirectory(appID)
        try validateTree(app)
        try validateDestination(destination)
        guard !isWithin(destination, root) else { throw Failure.unsafePath }
        try copier.importVerifiedTree(from: app, to: destination, isIdle: true)
    }

    /// Imports a new app with empty user-data directories; existing IDs are never overwritten.
    @discardableResult
    func importPackage(from package: URL) throws -> AppManifest {
        try requireIdle()
        let manifest = try sdk.inspectPackage(package)
        try validateManifest(manifest)
        try requireNoPendingTransaction(manifest.id)
        let destination = try appDirectory(manifest.id, mustExist: false)
        guard !fm.fileExists(atPath: destination.path) else { throw Failure.alreadyInstalled }
        let scratch = try temporaryDirectory()
        defer { try? fm.removeItem(at: scratch) }
        let staged = scratch.appendingPathComponent("app")
        try copier.importVerifiedTree(from: package, to: staged, isIdle: true)
        for path in ["state", "artifacts", "instances", "runs"] {
            try fm.createDirectory(at: staged.appendingPathComponent(path), withIntermediateDirectories: false)
        }
        try writeYAML([:], manifest: manifest, directory: staged)
        try copier.importVerifiedTree(from: staged, to: destination, isIdle: true)
        return manifest
    }

    @discardableResult
    func upgrade(appID: String, package: URL, migration: AppUpgradeManager.TrustedMigration? = nil) throws -> AppUpgradeReceipt {
        try requireIdle()
        let app = try appDirectory(appID)
        try validateTree(app)
        let before = try installedManifest(app)
        let metadata = try readYAML(app)
        try checkIdentity(metadata, manifest: before)
        let after = try sdk.inspectPackage(package)
        try validateManifest(after)
        guard after.id == appID else { throw Failure.metadataMismatch }
        if before.dataSchemaVersion != after.dataSchemaVersion && migration == nil { throw Failure.migrationRequired }
        return try sdk.upgrade(appID: appID, package: package, migration: migration, prepareStaging: { staged in
            try self.writeYAML(metadata, manifest: after, directory: staged)
        })
    }

    func rollback(_ receipt: AppUpgradeReceipt) throws {
        try requireIdle()
        try sdk.rollback(receipt)
    }

    /// Run before loading the repository at startup, while all writers are stopped.
    func recover(appID: String) throws {
        try requireIdle()
        try sdk.recover(appID: appID)
    }

    private var copier: AgentXRootCoordinator { .init(locator: root.appendingPathComponent(".unused-app-copy-locator")) }
    private func requireIdle() throws {
        guard writersHaveStopped() else { throw Failure.busy }
        try validateAncestors(root)
        var journalInfo = stat()
        if lstat(root.appendingPathComponent(".agentx-transaction.json").path, &journalInfo) == 0 { throw Failure.busy }
        guard errno == ENOENT else { throw Failure.unsafePath }
        let apps = root.appendingPathComponent("apps")
        try requireDirectory(apps)
        // A persisted active run is an additional fail-closed check, not proof of OS child quiescence.
        for app in try fm.contentsOfDirectory(at: apps, includingPropertiesForKeys: nil) {
            try requireDirectory(app)
            let runs = app.appendingPathComponent("runs")
            if !fm.fileExists(atPath: runs.path) { continue }
            try validateTree(runs)
            for file in try fm.contentsOfDirectory(at: runs, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
                let run = try JSONDecoder().decode(AgentXRun.self, from: Data(contentsOf: file))
                guard run.appID == app.lastPathComponent, run.status.terminal else { throw Failure.busy }
            }
        }
    }
    private func validateManifest(_ manifest: AppManifest) throws {
        try manifest.validate(hostAPIMajor: major)
        guard ["blackcat", "chat", "workbench"].contains(manifest.kind), manifest.id.utf8.count <= 100,
              !manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (manifest.kind == "blackcat") == (manifest.id == "blackcat"),
              manifest.paths == AppManifest.Paths(appID: manifest.id) else { throw Failure.invalidPackage }
    }
    private func requireNoPendingTransaction(_ appID: String) throws {
        _ = try appDirectory(appID, mustExist: false)
        let marker = root.appendingPathComponent("backups/apps/\(appID)/pending.json")
        try validateAncestors(marker.deletingLastPathComponent(), allowMissing: true)
        var info = stat()
        if lstat(marker.path, &info) == 0 { throw AppUpgradeError.pendingRecovery }
        guard errno == ENOENT else { throw Failure.unsafePath }
    }
    private func installedManifest(_ app: URL) throws -> AppManifest {
        let file = app.appendingPathComponent("manifest.json")
        guard fm.fileExists(atPath: file.path) else { throw Failure.missingBaseline }
        try validateTree(file)
        let manifest = try JSONDecoder().decode(AppManifest.self, from: Data(contentsOf: file))
        try validateManifest(manifest)
        guard manifest.id == app.lastPathComponent else { throw Failure.metadataMismatch }
        return manifest
    }
    private func readYAML(_ directory: URL) throws -> [String: Any] {
        let file = directory.appendingPathComponent("app.yaml")
        try validateTree(file)
        guard let value = try Yams.load(yaml: String(contentsOf: file, encoding: .utf8)) as? [String: Any] else { throw Failure.metadataMismatch }
        return value
    }
    private func checkIdentity(_ metadata: [String: Any], manifest: AppManifest) throws {
        guard metadata["id"] as? String == manifest.id, metadata["name"] as? String == manifest.name,
              metadata["kind"] as? String == manifest.kind else { throw Failure.metadataMismatch }
    }
    private func writeYAML(_ original: [String: Any], manifest: AppManifest, directory: URL) throws {
        var metadata = original
        metadata["id"] = manifest.id; metadata["name"] = manifest.name; metadata["kind"] = manifest.kind
        try Data(Yams.dump(object: metadata, sortKeys: true).utf8).write(to: directory.appendingPathComponent("app.yaml"), options: .atomic)
    }
    private func appDirectory(_ appID: String, mustExist: Bool = true) throws -> URL {
        guard !appID.isEmpty, appID.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { throw Failure.unsafePath }
        let app = root.appendingPathComponent("apps/\(appID)")
        try validateAncestors(app, allowMissing: !mustExist)
        return app
    }
    private func temporaryDirectory() throws -> URL {
        let base = root.appendingPathComponent("backups/app-host-staging")
        try validateAncestors(base, allowMissing: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let scratch = base.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false)
        return scratch
    }
    private func validateDestination(_ destination: URL) throws {
        try validateAncestors(destination, allowMissing: true)
        guard !fm.fileExists(atPath: destination.path) else { throw Failure.alreadyInstalled }
        try validateAncestors(destination.deletingLastPathComponent())
    }
    private func isWithin(_ child: URL, _ parent: URL) -> Bool {
        // Conservative even on case-sensitive volumes; never permit a casing alias into managed root.
        let candidate = child.path.precomposedStringWithCanonicalMapping.lowercased()
        let base = parent.path.precomposedStringWithCanonicalMapping.lowercased()
        return candidate == base || candidate.hasPrefix(base + "/")
    }
    private func validateAncestors(_ url: URL, allowMissing: Bool = false) throws {
        guard url.isFileURL, !url.path.contains("\0"), !url.path.contains("\\"),
              !url.pathComponents.contains("."), !url.pathComponents.contains("..") else { throw Failure.unsafePath }
        var cursor = URL(fileURLWithPath: "/")
        for part in url.pathComponents.dropFirst() {
            cursor.appendPathComponent(part)
            var info = stat()
            if lstat(cursor.path, &info) != 0 {
                guard allowMissing, errno == ENOENT else { throw Failure.unsafePath }
                continue
            }
            guard (info.st_mode & S_IFMT) == S_IFDIR else { throw Failure.unsafePath }
        }
    }
    private func requireDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { throw Failure.unsafePath }
    }
    private func validateTree(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw Failure.unsafePath }
        if (info.st_mode & S_IFMT) == S_IFDIR {
            for child in try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) { try validateTree(child) }
        } else {
            guard (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else { throw Failure.unsafePath }
        }
    }
}
