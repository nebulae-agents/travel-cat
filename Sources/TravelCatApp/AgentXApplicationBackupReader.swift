import Foundation
import Yams

/// Read-only, independently constructed parser state. Never captures a live repository.
struct AgentXApplicationBackupReader: Sendable {
    let root: URL
    func load() async throws -> AgentXApplicationBackupCatalog {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) { try read() }
        return try await withTaskCancellationHandler {
            let catalog = try await worker.value
            try Task.checkCancellation()
            return catalog
        } onCancel: { worker.cancel() }
    }
    /// Only direct UUID-named children are considered; full snapshots retain strict limits.
    func read() throws -> AgentXApplicationBackupCatalog {
        try Task.checkCancellation()
        let fm = FileManager.default
        let directory = try AgentXPackageFiles.safeURL("backups", root: root)
        guard fm.fileExists(atPath: directory.path) else { return .init() }
        let names = try fm.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("local-app-") }.sorted()
        guard names.count <= 256 else { throw AgentXError.invalid("备份超过 256 个，请先在本机整理后重试。") }
        var result = AgentXApplicationBackupCatalog()
        for name in names {
            try Task.checkCancellation()
            do {
                let id = String(name.dropFirst("local-app-".count))
                guard UUID(uuidString: id) != nil else { throw AgentXError.unsafePath }
                let expected = try AgentXPackageFiles.safeURL("backups/" + name, root: root)
                let receiptURL = try AgentXPackageFiles.safeURL("backups/" + name + "/receipt.json", root: root)
                let bytes = try AgentXLocalAppZIP.read(receiptURL)
                guard bytes.count <= 64 * 1024 else { throw AgentXError.corrupt }
                let receipt = try JSONDecoder().decode(AgentXApplicationBackup.self, from: bytes)
                try AgentXPackageFiles.validateID(receipt.appID)
                guard receipt.id == id, !["blackcat", "workbench"].contains(receipt.appID), receipt.backupURL.isFileURL,
                      receipt.backupURL.standardizedFileURL.path == expected.standardizedFileURL.path else { throw AgentXError.unsafePath }
                let snapshot = try AgentXPackageFiles.fullSnapshot(expected.appendingPathComponent("app"), checkCancellation: { try Task.checkCancellation() })
                guard snapshot.digest == receipt.digest, let manifest = snapshot.files["app.yaml"] else { throw AgentXError.corrupt }
                let app = try YAMLDecoder().decode(AgentXApplication.self, from: String(decoding: manifest, as: UTF8.self))
                guard app.id == receipt.appID else { throw AgentXError.corrupt }
                if receipt.legacyDisabledProjection == true {
                    guard let node = try Yams.compose(yaml: String(decoding: manifest, as: UTF8.self)),
                          case .mapping(let entries) = node,
                          !entries.contains(where: { key, _ in key.string == "enabled" }) else { throw AgentXError.corrupt }
                } else { guard !app.enabled else { throw AgentXError.corrupt } }
                try Task.checkCancellation()
                // A concurrent writer or removal must not leave a stale verified receipt.
                guard try AgentXLocalAppZIP.read(AgentXPackageFiles.safeURL("backups/" + name + "/receipt.json", root: root)) == bytes else { throw AgentXError.corrupt }
                result.receipts.append(receipt)
            } catch is CancellationError { throw CancellationError() }
            catch { result.warnings.append("备份 \(name) 无效或已变更，未提供恢复入口。") }
        }
        try Task.checkCancellation()
        return result
    }
}
