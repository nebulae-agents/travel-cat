import Foundation
import Darwin

/// The only host-persisted absolute locations are the root locator and a pending relocation.
struct AgentXHostStorage {
    let root: URL
    let hostDirectory: URL
    var blackCatRoot: URL { root.appendingPathComponent("apps/blackcat/state/travel", isDirectory: true) }
    var workbenchRoot: URL { root.appendingPathComponent("apps/workbench/state/runtime", isDirectory: true) }
    var coordinator: AgentXRootCoordinator { .init(locator: hostDirectory.appendingPathComponent("location.json")) }
    private var requestURL: URL { hostDirectory.appendingPathComponent("pending-migration.json") }
    private var receiptURL: URL { hostDirectory.appendingPathComponent("migration-exit.json") }
    private struct Import: Codable { var source: String; var relativeTarget: String }
    private struct Request: Codable { var id: UUID; var source: String; var destination: String?; var imports: [Import]? }
    private var rebindingMarker: URL { root.appendingPathComponent("apps/workbench/state/needs-rebinding") }
    var workbenchNeedsRebinding: Bool { FileManager.default.fileExists(atPath: rebindingMarker.path) }
    private func saveRequest(_ request: Request) throws {
        guard !offlineLifecycle.hasPendingOperation else { throw Failure.invalidRequest }
        try FileManager.default.createDirectory(at: hostDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(request).write(to: requestURL, options: .atomic)
    }
    private func requestImport(from source: URL, to target: URL) throws {
        let allowed = [blackCatRoot.path, workbenchRoot.path]
        guard allowed.contains(target.path) else { throw Failure.invalidRequest }
        var request = hasPendingMigration ? try JSONDecoder().decode(Request.self, from: Data(contentsOf: requestURL))
            : Request(id: UUID(), source: root.path, destination: nil, imports: [])
        guard request.source == root.path else { throw Failure.invalidRequest }
        let relative = String(target.path.dropFirst(root.path.count + 1))
        var imports = request.imports ?? []
        if let existing = imports.first(where: { $0.relativeTarget == relative }) {
            guard existing.source == source.path else { throw Failure.invalidRequest }
            return
        }
        imports.append(Import(source: source.path, relativeTarget: relative))
        request.id = UUID(); request.imports = imports
        try saveRequest(request)
    }
    private struct Receipt: Codable { var requestID: UUID; var processID: Int32 }
    enum Failure: LocalizedError {
        case writersActive, legacyRequiresOfflineImport(String), invalidRequest
        var errorDescription: String? {
            switch self {
            case .writersActive: "尚未验证旧宿主与子进程完全退出，迁移请求已保留。请正常退出应用后重新启动。"
            case .legacyRequiresOfflineImport(let path): "发现旧应用数据，尚未导入；应用已暂停，原文件保留：\(path)。已登记离线复制校验；正常退出再启动后导入。旧 workspace 授权保持禁用并供只读核对。"
            case .invalidRequest: "迁移请求与当前根目录不一致，未修改数据。请取消请求后重新选择。"
            }
        }
    }
    var offlineLifecycle: AgentXOfflineAppLifecycle { .init(root: root, locator: hostDirectory.appendingPathComponent("location.json")) }
    var hasPendingMigration: Bool { FileManager.default.fileExists(atPath: requestURL.path) }
    func requestMigration(to destination: URL) throws {
        guard !offlineLifecycle.hasPendingOperation else { throw Failure.invalidRequest }
        guard destination.isFileURL, destination.path != "/", destination.standardizedFileURL != root.standardizedFileURL,
              !destination.path.hasPrefix(root.path + "/"), !root.path.hasPrefix(destination.path + "/"),
              !FileManager.default.fileExists(atPath: destination.path) else { throw Failure.invalidRequest }
        let imports = hasPendingMigration ? try JSONDecoder().decode(Request.self, from: Data(contentsOf: requestURL)).imports : nil
        try saveRequest(Request(id: UUID(), source: root.path, destination: destination.path, imports: imports))
    }
    func cancelMigration() throws {
        if hasPendingMigration { try FileManager.default.removeItem(at: requestURL) }
        if FileManager.default.fileExists(atPath: receiptURL.path) { try FileManager.default.removeItem(at: receiptURL) }
    }
    func revokeExitReceipt() throws {
        if FileManager.default.fileExists(atPath: receiptURL.path) { try FileManager.default.removeItem(at: receiptURL) }
    }
    /// Write only after external execution is sealed and every owned child has exited.
    func recordCleanChildExit() throws {
        guard hasPendingMigration else { return }
        let request = try JSONDecoder().decode(Request.self, from: Data(contentsOf: requestURL))
        guard request.source == root.path else { throw Failure.invalidRequest }
        try JSONEncoder().encode(Receipt(requestID: request.id, processID: getpid())).write(to: receiptURL, options: .atomic)
    }
    func previousHostHasExited() -> Bool {
        guard let request = try? JSONDecoder().decode(Request.self, from: Data(contentsOf: requestURL)),
              let receipt = try? JSONDecoder().decode(Receipt.self, from: Data(contentsOf: receiptURL)),
              request.id == receipt.requestID, receipt.processID > 0 else { return false }
        return kill(receipt.processID, 0) == -1 && errno == ESRCH
    }
    func applyPendingMigration(writersHaveStopped: () -> Bool, inspectLegacyWorkbench: (URL) throws -> Void = { _ in }, migrateCredentials: ((URL, URL) throws -> Void)? = nil) throws -> URL {
        guard hasPendingMigration else { return root }
        var request = try JSONDecoder().decode(Request.self, from: Data(contentsOf: requestURL))
        guard request.source == root.path else { throw Failure.invalidRequest }
        guard !offlineLifecycle.hasPendingOperation else { throw Failure.invalidRequest }
        guard nativeDaemonsHaveExited() else { throw Failure.writersActive }
        guard writersHaveStopped() else { throw Failure.writersActive }
        request.imports?.sort { $0.relativeTarget < $1.relativeTarget }
        while let item = request.imports?.first {
            guard ["apps/blackcat/state/travel", "apps/workbench/state/runtime"].contains(item.relativeTarget), item.source.hasPrefix("/") else { throw Failure.invalidRequest }
            let target = root.appendingPathComponent(item.relativeTarget, isDirectory: true)
            try validateAppDirectory(target)
            if target == workbenchRoot {
                try inspectLegacyWorkbench(URL(fileURLWithPath: item.source, isDirectory: true))
                try FileManager.default.createDirectory(at: rebindingMarker.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("Imported legacy permissions require explicit relative rebinding.\n".utf8).write(to: rebindingMarker, options: .atomic)
            }
            try coordinator.importVerifiedTree(from: URL(fileURLWithPath: item.source, isDirectory: true), to: target, isIdle: true,
                excludedTopLevel: target == workbenchRoot ? ["native-runtime"] : [])
            request.imports?.removeFirst()
            try saveRequest(request)
        }
        let destination = request.destination.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? root
        if destination != root { try coordinator.migrate(from: root, to: destination, isIdle: true, beforePublish: { source, target in
            guard nativeDaemonsHaveExited() else { throw Failure.writersActive }
            try migrateCredentials?(source, target)
        }) }
        // Locator is already committed; cleanup failure must not make callers reopen the old root.
        try? cancelMigration()
        return destination
    }
    /// A clean sidecar exit does not imply its persistent app-server daemon exited.
    func nativeDaemonsHaveExited() -> Bool {
        func isCanonical(_ url: URL) -> Bool {
            guard let pointer = realpath(url.path, nil) else { return false }
            defer { free(pointer) }
            return String(cString: pointer) == url.path
        }
        let directory = workbenchRoot.appendingPathComponent("native-runtime")
        guard FileManager.default.fileExists(atPath: directory.path) else { return true }
        guard let profiles = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return false }
        for profile in profiles {
            guard UUID(uuidString: profile.lastPathComponent) != nil,
                  isCanonical(profile) else { return false }
            let receipt = profile.appendingPathComponent("travelcat-daemon.json")
            guard FileManager.default.fileExists(atPath: receipt.path) else { continue }
            guard isCanonical(receipt),
                  let data = try? Data(contentsOf: receipt),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = object["pid"] as? Int32, pid > 1,
                  kill(pid, 0) == -1, errno == ESRCH else { return false }
        }
        return true
    }
    private func validateAppDirectory(_ target: URL) throws {
        guard target.isFileURL, [blackCatRoot.path, workbenchRoot.path].contains(target.path),
              !target.pathComponents.contains("."), !target.pathComponents.contains("..") else { throw Failure.invalidRequest }
        var cursor = URL(fileURLWithPath: "/", isDirectory: true)
        for component in target.path.split(separator: "/") {
            cursor.appendPathComponent(String(component))
            if let attributes = try? FileManager.default.attributesOfItem(atPath: cursor.path),
               attributes[.type] as? FileAttributeType != .typeDirectory { throw Failure.invalidRequest }
        }
    }
    func prepareAppData(at target: URL, legacy: URL?) throws {
        try validateAppDirectory(target)
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) { return }
        if let legacy, target.standardizedFileURL != legacy.standardizedFileURL,
           fm.fileExists(atPath: legacy.path),
           !(try fm.contentsOfDirectory(atPath: legacy.path)).isEmpty {
            try requestImport(from: legacy, to: target)
            throw Failure.legacyRequiresOfflineImport(legacy.path)
        }
        try fm.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
}

/// Resolve one host namespace before reading locators or legacy application data.
struct AgentXHostEnvironment {
    let fallbackRoot: URL
    let hostDirectory: URL
    let importsLegacyData: Bool
    init(environment: [String: String], applicationSupport: URL) throws {
        func absolute(_ value: String) throws -> URL {
            guard value.hasPrefix("/"), value != "/", !value.contains("\0"),
                  !value.split(separator: "/").contains(".."), !value.split(separator: "/").contains(".") else { throw AgentXHostStorage.Failure.invalidRequest }
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        if let value = environment["AGENTX_ROOT"] {
            fallbackRoot = try absolute(value)
            importsLegacyData = false
            hostDirectory = try environment["AGENTX_HOST_DIRECTORY"].map(absolute)
                ?? fallbackRoot.deletingLastPathComponent().appendingPathComponent("." + fallbackRoot.lastPathComponent + ".agentx-host", isDirectory: true)
        } else {
            fallbackRoot = applicationSupport.appendingPathComponent("AgentXManager", isDirectory: true)
            hostDirectory = try environment["AGENTX_HOST_DIRECTORY"].map(absolute)
                ?? applicationSupport.appendingPathComponent("AgentXHost", isDirectory: true)
            importsLegacyData = true
        }
        guard hostDirectory.path != fallbackRoot.path, !hostDirectory.path.hasPrefix(fallbackRoot.path + "/") else { throw AgentXHostStorage.Failure.invalidRequest }
    }
}
