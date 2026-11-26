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
    func prepare(appID: String) throws { _ = try open(appID) }

    func deliver(_ records: ArraySlice<[String: Any]>, run: AgentXRun) throws {
        let store = try open(run.appID)
        for record in records {
            guard record["taskId"] as? String == run.id, record["instanceId"] as? String == run.instanceID else {
                throw AgentXError.corrupt
            }
            try AgentXAuditHelper.validate(record, appID: run.appID)
            try store.appendIdempotent(record: record)
        }
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
    /// Called under the desktop writer's exclusive root lease. Re-read the chain
    /// before appending: the previous process may have committed a terminal event.
    func finishInterrupted(_ run: AgentXRun) throws -> String? {
        guard let id = UUID(uuidString: run.id) else { throw AgentXError.corrupt }
        let directory = try Self.directory(root: root, appID: run.appID)
        let reader = try AgentAuditStore.open(root: directory, credentials: credentials, readOnly: true)
        let records = try reader.records(taskID: id)
        guard let start = records.first(where: { $0["kind"] as? String == "model.request.started" }),
              start["appId"] as? String == run.appID, start["instanceId"] as? String == run.instanceID else {
            throw AgentXError.corrupt
        }
        let terminal = records.filter { ["model.request.completed", "model.request.cancelled", "model.request.failed"].contains($0["kind"] as? String ?? "") }
        guard terminal.count <= 1 else { throw AgentXError.corrupt }
        if let event = terminal.first {
            return event["kind"] as? String == "model.request.failed" ? nil : "原审计已记录终态，桌面中断前未保存完整运行结果。"
        }
        let retained = ["taskId", "runId", "appId", "instanceId", "providerId", "model", "promptBytes", "requestTextBytes"]
        let ticket = Ticket(store: try open(run.appID), fields: start.filter { retained.contains($0.key) })
        try finish(ticket, status: .failed, responseBytes: run.response.utf8.count)
        return nil
    }
    func verifiedReport(for run: AgentXRun, storedStatus: String?) throws -> [String: Any] {
        let directory = try Self.directory(root: root, appID: run.appID)
        let reader = try AgentAuditStore.open(root: directory, credentials: credentials, readOnly: true)
        let chain = try reader.inventory()
        let records = try UUID(uuidString: run.id).map { try reader.records(taskID: $0) } ?? []
        let visible = AgentXAuditHelper.publicRecords(records, appID: run.appID)
        // Older snapshots predate delivery acknowledgements. Verification below
        // still returns the actual records, independently of that legacy label.
        let status = storedStatus ?? "legacy"
        return ["runId": run.id, "appID": run.appID, "auditStatus": status,
                "verified": true, "chainRecords": chain.records, "records": visible]
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
