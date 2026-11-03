import Foundation
import AgentXAppSDK
#if canImport(Darwin)
import Darwin
#endif

/// Host-only request queue outside root. Requests never execute app code. Lifecycle mutations
/// run on the next startup before services reopen, after the old host PID has actually exited.
struct AgentXOfflineAppLifecycle {
    enum Operation: Codable {
        case register(appID: String, manifest: AppManifest)
        case exportPackage(appID: String, destination: String)
        case backupApplication(appID: String, destination: String)
        case importPackage(source: String)
        case upgrade(appID: String, source: String)
        case rollback(AppUpgradeReceipt)

        var appID: String? {
            switch self {
            case .register(let id, _), .exportPackage(let id, _), .backupApplication(let id, _), .upgrade(let id, _): id
            case .rollback(let receipt): receipt.appID
            case .importPackage: nil
            }
        }
        var title: String {
            switch self {
            case .register: "登记应用版本基线"
            case .exportPackage: "导出代码包（不含用户数据）"
            case .backupApplication: "导出完整应用备份（含用户数据）"
            case .importPackage: "导入代码包"
            case .upgrade: "升级应用"
            case .rollback: "回滚应用快照"
            }
        }
    }
    struct Result: Codable {
        let requestID: UUID
        let succeeded: Bool
        let message: String
        let rollbackReceipt: AppUpgradeReceipt?
    }
    private struct Request: Codable {
        let id: UUID
        let sourceRoot: String
        let operation: Operation
        var phase: String
    }
    private struct ExitReceipt: Codable { let requestID: UUID; let processID: Int32 }
    enum Failure: LocalizedError {
        case pending, migrationPending, unsafePath, mismatchedRoot, writersActive, previousHostActive
        var errorDescription: String? {
            switch self {
            case .pending: "已有应用操作等待下次启动，请先完成或取消。"
            case .migrationPending: "根目录迁移或历史数据导入已排队，请先完成或取消后再登记应用操作。"
            case .unsafePath: "离线操作记录路径不安全，未执行请求。"
            case .mismatchedRoot: "请求绑定的根目录已变化，请取消并在当前根目录重新登记。"
            case .writersActive: "执行器尚未停止，无法执行应用操作。"
            case .previousHostActive: "尚无上次宿主及子进程完全退出的证据，请正常退出后重新启动。"
            }
        }
    }
    let root: URL
    let locator: URL
    var requestURL: URL { locator.deletingLastPathComponent().appendingPathComponent("app-lifecycle-request.json") }
    var exitReceiptURL: URL { locator.deletingLastPathComponent().appendingPathComponent("app-lifecycle-exit.json") }
    var resultURL: URL { locator.deletingLastPathComponent().appendingPathComponent("app-lifecycle-result.json") }
    private var fm: FileManager { .default }
    var hasPendingOperation: Bool { fm.fileExists(atPath: requestURL.path) }

    func pendingTitle() throws -> String? {
        guard hasPendingOperation else { return nil }
        return try readRequest().operation.title
    }
    func latestResult() throws -> Result? {
        try checkFile(resultURL)
        guard fm.fileExists(atPath: resultURL.path) else { return nil }
        return try JSONDecoder().decode(Result.self, from: Data(contentsOf: resultURL))
    }
    func latestRollbackReceipt(appID: String) throws -> AppUpgradeReceipt? {
        if let latest = try latestResult(), latest.succeeded, latest.rollbackReceipt?.appID == appID { return latest.rollbackReceipt }
        let history = locator.deletingLastPathComponent().appendingPathComponent("app-lifecycle-history")
        guard fm.fileExists(atPath: history.path) else { return nil }
        try checkFile(history.appendingPathComponent(".validation-probe"))
        let files = try fm.contentsOfDirectory(at: history, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "json" }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for file in files {
            try checkFile(file)
            let result = try JSONDecoder().decode(Result.self, from: Data(contentsOf: file))
            if result.succeeded, result.rollbackReceipt?.appID == appID { return result.rollbackReceipt }
        }
        return nil
    }
    func request(_ operation: Operation) throws {
        let migration = locator.deletingLastPathComponent().appendingPathComponent("pending-migration.json")
        try checkFile(migration)
        guard !fm.fileExists(atPath: migration.path) else { throw Failure.migrationPending }
        guard !hasPendingOperation else { throw Failure.pending }
        try checkFile(requestURL)
        try revokeExitReceipt()
        try save(Request(id: UUID(), sourceRoot: root.path, operation: operation, phase: "pending"), to: requestURL)
    }
    func cancel() throws {
        try checkFile(requestURL)
        if hasPendingOperation { try fm.removeItem(at: requestURL) }
        try revokeExitReceipt()
    }
    func revokeExitReceipt() throws {
        try checkFile(exitReceiptURL)
        if fm.fileExists(atPath: exitReceiptURL.path) { try fm.removeItem(at: exitReceiptURL) }
    }
    /// Call only after the host seals new work and confirms every owned child has exited.
    func recordCleanChildExit() throws {
        guard hasPendingOperation else { return }
        let request = try readRequest()
        guard request.sourceRoot == root.path else { throw Failure.mismatchedRoot }
        try save(ExitReceipt(requestID: request.id, processID: getpid()), to: exitReceiptURL)
    }
    func previousHostHasExited() -> Bool {
        guard let request = try? readRequest(), request.sourceRoot == root.path,
              (try? checkFile(exitReceiptURL)) != nil,
              let receipt = try? JSONDecoder().decode(ExitReceipt.self, from: Data(contentsOf: exitReceiptURL)),
              receipt.requestID == request.id, receipt.processID > 0 else { return false }
        return kill(receipt.processID, 0) == -1 && errno == ESRCH
    }

    /// Also requires a startup-local no-writer barrier. Refuses to replay an interrupted request.
    /// Operational failures are recorded and consumed; missing exit evidence leaves the request pending.
    @discardableResult
    func applyPending(writersHaveStopped: @escaping () -> Bool) throws -> Result? {
        guard hasPendingOperation else { return nil }
        var request = try readRequest()
        guard request.sourceRoot == root.path else { throw Failure.mismatchedRoot }
        guard previousHostHasExited() else { throw Failure.previousHostActive }
        guard writersHaveStopped() else { throw Failure.writersActive }
        guard request.phase == "pending" || request.phase == "applying" else { throw Failure.unsafePath }
        let interrupted = request.phase == "applying"
        request.phase = "applying"
        try save(request, to: requestURL)
        let result: Result
        do {
            let host = try AgentXAppLifecycleHost(root: root, hostAPIMajor: 1, writersHaveStopped: writersHaveStopped)
            if let appID = request.operation.appID { try host.recover(appID: appID) }
            if interrupted {
                result = Result(requestID: request.id, succeeded: false,
                    message: "上次应用操作被中断，已检查恢复快照；未自动重试。请核对当前应用版本后重新登记。", rollbackReceipt: nil)
            } else {
                var receipt: AppUpgradeReceipt?
                switch request.operation {
                case .register(let id, let manifest): try host.register(appID: id, manifest: manifest)
                case .exportPackage(let id, let path): try host.exportPackage(appID: id, to: try absoluteURL(path))
                case .backupApplication(let id, let path): try host.backupApplication(appID: id, to: try absoluteURL(path))
                case .importPackage(let path): _ = try host.importPackage(from: try absoluteURL(path))
                case .upgrade(let id, let path): receipt = try host.upgrade(appID: id, package: try absoluteURL(path))
                case .rollback(let value): try host.rollback(value)
                }
                result = Result(requestID: request.id, succeeded: true, message: "\(request.operation.title)已完成。", rollbackReceipt: receipt)
            }
        } catch {
            result = Result(requestID: request.id, succeeded: false, message: "\(request.operation.title)未完成：\(error.localizedDescription)", rollbackReceipt: nil)
        }
        try save(result, to: resultURL)
        // A historical receipt survives a later export, backup or failure overwriting latestResult.
        let history = locator.deletingLastPathComponent().appendingPathComponent("app-lifecycle-history/\(request.id.uuidString).json")
        try save(result, to: history)
        try cancel()
        return result
    }

    private func readRequest() throws -> Request {
        try checkFile(requestURL)
        return try JSONDecoder().decode(Request.self, from: Data(contentsOf: requestURL))
    }
    private func absoluteURL(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), !path.contains("\0"), !path.contains("\\"),
              !path.split(separator: "/").contains(".."), !path.split(separator: "/").contains(".") else { throw Failure.unsafePath }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    private func save<Value: Encodable>(_ value: Value, to file: URL) throws {
        try checkFile(file)
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    private func checkFile(_ file: URL) throws {
        guard file.isFileURL, !file.path.contains("\0"), !file.pathComponents.contains(".."), !file.pathComponents.contains(".") else { throw Failure.unsafePath }
        var cursor = URL(fileURLWithPath: "/")
        for part in file.pathComponents.dropFirst() {
            cursor.appendPathComponent(part)
            var info = stat()
            if lstat(cursor.path, &info) != 0 {
                guard errno == ENOENT else { throw Failure.unsafePath }
                continue
            }
            if cursor.path == file.path {
                guard (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else { throw Failure.unsafePath }
            } else {
                guard (info.st_mode & S_IFMT) == S_IFDIR else { throw Failure.unsafePath }
            }
        }
    }
}
