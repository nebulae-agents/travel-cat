import Darwin
import Foundation

/// Contains no process IDs, paths or provider output. Observations never reap or signal.
struct AgentXOwnedProcessSnapshot: Sendable, Equatable {
    enum State: Sendable { case unobserved, alive, exited, unknown }
    enum Reason: Sendable { case noRegisteredObjects, unsupported, busy, identityMismatch, partialIdentity }
    var state: State
    var reason: Reason? = nil
    var observedCount: Int = 0
    static let limit = 128

    static func observe(_ identity: AgentXStopProcessIdentity) -> Self {
        guard identity.pid > 0 else { return .init(state: .unknown, reason: .partialIdentity) }
        var info = proc_bsdinfo()
        errno = 0
        let size = proc_pidinfo(identity.pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        if size == MemoryLayout<proc_bsdinfo>.size {
            guard info.pbi_pid == UInt32(identity.pid), info.pbi_uid == getuid(),
                  info.pbi_start_tvsec == identity.seconds, info.pbi_start_tvusec == identity.microseconds else {
                return .init(state: .unknown, reason: .identityMismatch)
            }
            return .init(state: info.pbi_status == 5 ? .exited : .alive, observedCount: 1)
        }
        return errno == ESRCH ? .init(state: .exited, observedCount: 1) : .init(state: .unknown, reason: .partialIdentity)
    }

    static func combine(_ values: [Self]) -> Self {
        guard !values.isEmpty else { return .init(state: .unobserved, reason: .noRegisteredObjects) }
        let count = values.reduce(0) { $0 + $1.observedCount }
        if let unknown = values.first(where: { $0.state == .unknown || $0.state == .unobserved }) {
            return .init(state: .unknown, reason: unknown.reason ?? .partialIdentity, observedCount: count)
        }
        return .init(state: values.contains { $0.state == .alive } ? .alive : .exited, observedCount: count)
    }
}

/// Bounded current-host receipts only. Disk-only records are deliberately not loaded by observation.
final class AgentXPiObservationCache: @unchecked Sendable {
    static let shared = AgentXPiObservationCache()
    private let lock = NSLock()
    private var records: [String: [UUID: AgentXPiProcessLedger.Record]] = [:]
    private var overflow = Set<String>()
    func record(_ record: AgentXPiProcessLedger.Record, root: URL) {
        lock.lock(); defer { lock.unlock() }
        let key = root.standardizedFileURL.path
        guard records[key] != nil || records.count < 32 else { return }
        if records[key]?[record.id] == nil && (records[key]?.count ?? 0) >= AgentXOwnedProcessSnapshot.limit {
            overflow.insert(key); return
        }
        records[key, default: [:]][record.id] = record
    }
    func observe(root: URL, owner: AgentXStopProcessIdentity, runIDs: Set<String>) -> AgentXOwnedProcessSnapshot {
        guard AgentXStopProcessIdentity.read(getpid()) == owner else { return .init(state: .unknown, reason: .identityMismatch) }
        guard !runIDs.isEmpty else { return .init(state: .unobserved, reason: .noRegisteredObjects) }
        guard lock.try() else { return .init(state: .unknown, reason: .busy) }
        let key = root.standardizedFileURL.path
        let entries = records[key]
        let exceeded = overflow.contains(key)
        lock.unlock()
        guard !exceeded else { return .init(state: .unknown, reason: .partialIdentity) }
        guard let entries else { return .init(state: .unobserved, reason: .unsupported) }
        let matching = entries.values.filter { $0.owner == owner && runIDs.contains($0.runID) }
        guard !matching.isEmpty else { return .init(state: .unobserved, reason: .noRegisteredObjects) }
        return .combine(matching.map { record in
            if record.reaped { return .init(state: .exited, observedCount: 1) }
            guard let child = record.child else { return .init(state: .unknown, reason: .partialIdentity) }
            return .observe(child)
        })
    }
}
