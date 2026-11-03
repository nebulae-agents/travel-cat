import Foundation
import Darwin

/// Host-owned encrypted/hash-chained model lifecycle metadata; never prompt, response or secrets.
@MainActor
final class AgentXRunAudit {
    struct Ticket {
        fileprivate let store: AgentAuditStore
        fileprivate let fields: [String: Any]
    }
    private let root: URL
    private let credentials: any TravelServiceCredentialStoring
    init(root: URL, credentials: any TravelServiceCredentialStoring) { self.root = root; self.credentials = credentials }

    static func directory(root: URL, appID: String) throws -> URL {
        guard !appID.isEmpty, appID.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { throw WorkbenchFailure("审计应用标识无效。") }
        // The trusted host selected root may include macOS /var or /tmp aliases.
        let base = root.resolvingSymlinksInPath()
        var cursor = base
        for part in ["audit", appID] {
            cursor.appendPathComponent(part)
            var info = stat()
            if lstat(cursor.path, &info) == 0 {
                guard (info.st_mode & S_IFMT) == S_IFDIR else { throw WorkbenchFailure("审计路径包含链接或非目录，已阻止调用。") }
            } else if errno != ENOENT { throw WorkbenchFailure("审计路径不可检查，已阻止调用。") }
        }
        return cursor
    }
    private func open(_ appID: String) throws -> AgentAuditStore {
        try AgentAuditStore.open(root: Self.directory(root: root, appID: appID), credentials: credentials)
    }
    func begin(run: AgentXRun, providerID: String, model: String, requestBytes: Int) throws -> Ticket {
        guard UUID(uuidString: run.id) != nil else { throw WorkbenchFailure("审计运行标识无效。") }
        let store = try open(run.appID)
        let ticket = Ticket(store: store, fields: ["taskId": run.id, "runId": run.id, "appId": run.appID,
            "instanceId": run.instanceID, "providerId": providerID, "model": model,
            "promptBytes": run.prompt.utf8.count, "requestTextBytes": requestBytes])
        try append(ticket, kind: "model.request.started", fields: [:])
        return ticket
    }
    func cancelRequested(_ ticket: Ticket) throws { try append(ticket, kind: "model.request.cancel_requested", fields: [:]) }
    func finish(_ ticket: Ticket, status: AgentXRunStatus, responseBytes: Int) throws {
        guard status.terminal else { throw WorkbenchFailure("审计结束状态无效。") }
        try append(ticket, kind: "model.request.\(status.rawValue)", fields: ["status": status.rawValue, "responseBytes": responseBytes])
    }
    func records(appID: String, runID: String) throws -> [[String: Any]] {
        guard let id = UUID(uuidString: runID) else { throw WorkbenchFailure("审计运行标识无效。") }
        return try open(appID).records(taskID: id)
    }
    private func append(_ ticket: Ticket, kind: String, fields: [String: Any]) throws {
        var record = ticket.fields
        record.merge(fields) { _, new in new }
        record["eventId"] = UUID().uuidString; record["kind"] = kind
        record["timestamp"] = ISO8601DateFormatter().string(from: Date())
        try ticket.store.append(record: record)
    }
}
