import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum AppUpgradeError: Error { case invalidPackage, migrationRequired, pendingRecovery, invalidReceipt }

/// Host-issued receipt. Paths are root-relative so the root can be relocated.
public struct AppUpgradeReceipt: Codable, Sendable {
    public let appID: String
    public let snapshotRelativePath: String
    public let installedManifest: AppManifest
    fileprivate init(appID: String, snapshotRelativePath: String, installedManifest: AppManifest) {
        self.appID = appID; self.snapshotRelativePath = snapshotRelativePath; self.installedManifest = installedManifest
    }
}

/// Trusted, synchronous host service. Stop app writes and exclusively control all root/package
/// directory mutation for the entire call. This is not a sandbox for migration code.
/// Packages contain exactly manifest.json and payload/. Everything else in the installed app
/// belongs to the user and is copied into staging. No package code is ever executed.
public final class AppUpgradeManager {
    public typealias TrustedMigration = (URL, AppManifest, AppManifest) throws -> Void
    private let root: URL
    private let hostAPIMajor: Int
    private let fm = FileManager.default
    private struct Pending: Codable { let transaction: String; let before: AppManifest; let after: AppManifest }

    public init(root: URL, hostAPIMajor: Int) throws {
        try Self.validateAncestors(root)
        guard hostAPIMajor > 0 else { throw AppSDKError.incompatibleHost }
        self.root = root; self.hostAPIMajor = hostAPIMajor
    }

    public func upgrade(appID: String, package: URL, migration: TrustedMigration? = nil, prepareStaging: ((URL) throws -> Void)? = nil) throws -> AppUpgradeReceipt {
        let live = try appURL(appID)
        try Self.validateAncestors(package); try Self.validateTree(package); try Self.validateTree(live)
        guard Set(try fm.contentsOfDirectory(atPath: package.path)) == ["manifest.json", "payload"] else { throw AppUpgradeError.invalidPackage }
        try Self.requireDirectory(package.appendingPathComponent("payload"))
        let before = try readManifest(live, appID: appID)
        let after = try readManifest(package, appID: appID)
        guard before.paths == after.paths else { throw AppUpgradeError.invalidPackage }
        if before.dataSchemaVersion != after.dataSchemaVersion && migration == nil { throw AppUpgradeError.migrationRequired }
        let transaction = try prepareTransaction(appID: appID)
        let snapshot = transaction.appendingPathComponent("before")
        let staging = transaction.appendingPathComponent("staging")
        try copyVerified(live, snapshot); try copyVerified(live, staging)
        let payload = staging.appendingPathComponent("payload")
        if fm.fileExists(atPath: payload.path) { try fm.removeItem(at: payload) }
        try copyVerified(package.appendingPathComponent("payload"), payload)
        try JSONEncoder().encode(after).write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
        if before.dataSchemaVersion != after.dataSchemaVersion { try migration?(staging, before, after) }
        try prepareStaging?(staging)
        try Self.validateTree(staging)
        guard try readManifest(staging, appID: appID) == after else { throw AppUpgradeError.invalidPackage }
        try publish(staging: staging, live: live, transaction: transaction, before: before, after: after)
        return AppUpgradeReceipt(appID: appID, snapshotRelativePath: "backups/apps/\(appID)/\(transaction.lastPathComponent)/before", installedManifest: after)
    }

    /// Read-only package validation for a trusted host import/export adapter. Does not execute code.
    public func inspectPackage(_ package: URL) throws -> AppManifest {
        try Self.validateAncestors(package); try Self.validateTree(package)
        guard Set(try fm.contentsOfDirectory(atPath: package.path)) == ["manifest.json", "payload"] else { throw AppUpgradeError.invalidPackage }
        try Self.requireDirectory(package.appendingPathComponent("payload"))
        let manifestFile = package.appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(AppManifest.self, from: Data(contentsOf: manifestFile))
        return try readManifest(package, appID: manifest.id)
    }

    /// Restores the prior snapshot and first retains the current app in a new backup transaction.
    /// Refuses a receipt after another app version has been installed.
    public func rollback(_ receipt: AppUpgradeReceipt) throws {
        let live = try appURL(receipt.appID)
        let parts = try components(receipt.snapshotRelativePath)
        guard parts.count == 5, parts[0] == "backups", parts[1] == "apps", parts[2] == receipt.appID,
              UUID(uuidString: parts[3]) != nil, parts[4] == "before" else { throw AppUpgradeError.invalidReceipt }
        let snapshot = root.appendingPathComponent(receipt.snapshotRelativePath)
        try Self.validateAncestors(snapshot); try Self.validateTree(snapshot); try Self.validateTree(live)
        let current = try readManifest(live, appID: receipt.appID)
        guard current == receipt.installedManifest else { throw AppUpgradeError.invalidReceipt }
        let old = try readManifest(snapshot, appID: receipt.appID)
        let transaction = try prepareTransaction(appID: receipt.appID)
        try copyVerified(live, transaction.appendingPathComponent("before"))
        let staging = transaction.appendingPathComponent("staging")
        try copyVerified(snapshot, staging)
        try publish(staging: staging, live: live, transaction: transaction, before: current, after: old)
    }

    /// Call before reopening an app after host termination. A missing live app is restored
    /// from the completed pre-upgrade snapshot; an already-published valid app is retained.
    /// This covers process interruption, not power-loss durability (no fsync protocol).
    public func recover(appID: String) throws {
        let live = try appURL(appID, mustExist: false)
        let base = try backupBase(appID)
        let marker = base.appendingPathComponent("pending.json")
        guard fm.fileExists(atPath: marker.path) else { return }
        try Self.validateTree(marker)
        let pending = try JSONDecoder().decode(Pending.self, from: Data(contentsOf: marker))
        guard UUID(uuidString: pending.transaction) != nil, pending.before.id == appID, pending.after.id == appID else { throw AppUpgradeError.invalidReceipt }
        let transaction = base.appendingPathComponent(pending.transaction)
        try Self.validateAncestors(transaction)
        if fm.fileExists(atPath: live.path) {
            try Self.validateTree(live)
            let current = try readManifest(live, appID: appID)
            guard current == pending.before || current == pending.after else { throw AppUpgradeError.pendingRecovery }
        } else {
            let snapshot = transaction.appendingPathComponent("before")
            try Self.validateTree(snapshot)
            guard try readManifest(snapshot, appID: appID) == pending.before else { throw AppUpgradeError.invalidReceipt }
            let restored = transaction.appendingPathComponent("recovery-\(UUID().uuidString)")
            try copyVerified(snapshot, restored)
            try fm.moveItem(at: restored, to: live)
        }
        try fm.removeItem(at: marker)
    }

    private func publish(staging: URL, live: URL, transaction: URL, before: AppManifest, after: AppManifest) throws {
        // Foundation may implement cross-volume moves as copy/delete; publication requires rename semantics.
        var liveInfo = stat(); var stageInfo = stat(); var parentInfo = stat()
        guard lstat(live.path, &liveInfo) == 0, lstat(staging.path, &stageInfo) == 0,
              lstat(live.deletingLastPathComponent().path, &parentInfo) == 0,
              liveInfo.st_dev == stageInfo.st_dev, liveInfo.st_dev == parentInfo.st_dev else { throw AppSDKError.unsafeFile }
        let marker = transaction.deletingLastPathComponent().appendingPathComponent("pending.json")
        try JSONEncoder().encode(Pending(transaction: transaction.lastPathComponent, before: before, after: after)).write(to: marker, options: .atomic)
        let displaced = transaction.appendingPathComponent("displaced")
        do {
            try fm.moveItem(at: live, to: displaced)
            do { try fm.moveItem(at: staging, to: live) }
            catch {
                try fm.moveItem(at: displaced, to: live)
                throw error
            }
        } catch {
            // If restoring failed, leave the marker and snapshot for recover(appID:).
            if fm.fileExists(atPath: live.path) { try? fm.removeItem(at: marker) }
            throw error
        }
        // Publication is complete; a retained marker can be cleared by recover on reopen.
        try? fm.removeItem(at: marker)
    }

    private func readManifest(_ directory: URL, appID: String) throws -> AppManifest {
        let file = directory.appendingPathComponent("manifest.json")
        try Self.validateTree(file)
        let manifest = try JSONDecoder().decode(AppManifest.self, from: Data(contentsOf: file))
        try manifest.validate(hostAPIMajor: hostAPIMajor)
        guard manifest.id == appID else { throw AppUpgradeError.invalidPackage }
        for path in [manifest.paths.state, manifest.paths.artifacts, manifest.paths.instances, manifest.paths.runs] {
            let parts = try components(path)
            guard parts.count >= 3, parts[2].lowercased() != "payload", parts[2].lowercased() != "manifest.json" else { throw AppUpgradeError.invalidPackage }
        }
        return manifest
    }
    private func appURL(_ appID: String, mustExist: Bool = true) throws -> URL {
        guard validID(appID) else { throw AppSDKError.invalidPath }
        try Self.validateAncestors(root)
        let apps = root.appendingPathComponent("apps"); try Self.validateAncestors(apps)
        let app = apps.appendingPathComponent(appID)
        if mustExist || fm.fileExists(atPath: app.path) { try Self.validateAncestors(app) }
        return app
    }
    private func backupBase(_ appID: String) throws -> URL {
        var path = root
        for name in ["backups", "apps", appID] {
            path.appendPathComponent(name)
            if !fm.fileExists(atPath: path.path) { try fm.createDirectory(at: path, withIntermediateDirectories: false) }
            try Self.validateAncestors(path)
        }
        return path
    }
    private func prepareTransaction(appID: String) throws -> URL {
        let base = try backupBase(appID)
        guard !fm.fileExists(atPath: base.appendingPathComponent("pending.json").path) else { throw AppUpgradeError.pendingRecovery }
        let transaction = base.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: transaction, withIntermediateDirectories: false)
        return transaction
    }
    private func copyVerified(_ source: URL, _ destination: URL) throws {
        try Self.validateTree(source)
        try fm.copyItem(at: source, to: destination)
        try Self.validateTree(destination)
        guard fm.contentsEqual(atPath: source.path, andPath: destination.path) else { throw AppSDKError.unsafeFile }
    }
    private static func requireDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { throw AppSDKError.unsafeFile }
    }
    private static func validateAncestors(_ url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\\"), !url.path.contains("\0"),
              !url.pathComponents.contains("."), !url.pathComponents.contains("..") else { throw AppSDKError.invalidPath }
        var path = URL(fileURLWithPath: "/")
        for component in url.pathComponents.dropFirst() {
            path.appendPathComponent(component); try requireDirectory(path)
        }
    }
    private static func validateTree(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw AppSDKError.unsafeFile }
        let kind = info.st_mode & S_IFMT
        if kind == S_IFREG {
            guard info.st_nlink == 1 else { throw AppSDKError.unsafeFile }
        } else if kind == S_IFDIR {
            for name in try FileManager.default.contentsOfDirectory(atPath: url.path) {
                _ = try components(name)
                try validateTree(url.appendingPathComponent(name))
            }
        } else { throw AppSDKError.unsafeFile }
    }
}
