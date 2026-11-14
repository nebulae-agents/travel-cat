import Foundation

/// Carries ownership into Pi before the process worker leaves the Swift task.
enum AgentXPiExecutionContext {
    @TaskLocal static var runID: String?
}

/// One atomic receipt per child; no credentials, prompts, responses, or arbitrary paths.
struct AgentXPiProcessLedger: Sendable {
    let root: URL
    struct Record: Codable {
        var id: UUID
        var owner: AgentXStopProcessIdentity
        var runID: String
        var child: AgentXStopProcessIdentity?
        var reaped: Bool = false
    }
    private func directory() throws -> URL {
        var cursor = root.standardizedFileURL
        for part in ["", "manager", "pi-processes"] {
            if !part.isEmpty { cursor.appendPathComponent(part) }
            if (try? cursor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw AgentXPiRuntimeError.processFailed }
        }
        return cursor
    }
    private func url(_ id: UUID) throws -> URL {
        let value = try directory().appendingPathComponent(id.uuidString + ".json")
        if (try? value.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw AgentXPiRuntimeError.processFailed }
        return value
    }
    private func save(_ record: Record) throws {
        let target = try url(record.id)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: target, options: .atomic)
        AgentXPiObservationCache.shared.record(record, root: root)
    }
    func begin(owner: AgentXStopProcessIdentity, runID: String) throws -> UUID {
        let record = Record(id: UUID(), owner: owner, runID: runID)
        try save(record)
        return record.id
    }
    func launched(id: UUID, child: AgentXStopProcessIdentity) throws {
        var record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: url(id)))
        guard record.id == id else { throw AgentXPiRuntimeError.processFailed }
        record.child = child
        try save(record)
    }
    func reaped(id: UUID) throws {
        var record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: url(id)))
        guard record.id == id else { throw AgentXPiRuntimeError.processFailed }
        record.reaped = true
        try save(record)
    }
    /// Current-host cache only; prior-session disk receipts are outside this observation scope.
    func observeOwnedProcesses(owner: AgentXStopProcessIdentity, runIDs: Set<String>) -> AgentXOwnedProcessSnapshot {
        AgentXPiObservationCache.shared.observe(root: root, owner: owner, runIDs: runIDs)
    }
    /// Missing/partial receipts are unknown, never proof that no child was created.
    func confirmedExited(owner: AgentXStopProcessIdentity, runID: String) throws -> Bool {
        let directory = try directory()
        guard FileManager.default.fileExists(atPath: directory.path) else { return false }
        var matches: [Record] = []
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey]) where file.pathExtension == "json" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { throw AgentXPiRuntimeError.processFailed }
            let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: url(id)))
            guard record.id == id else { throw AgentXPiRuntimeError.processFailed }
            if record.owner == owner && record.runID == runID { matches.append(record) }
        }
        return !matches.isEmpty && matches.allSatisfy { $0.reaped || $0.child?.definitelyExited() == true }
    }
}
