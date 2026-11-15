import Foundation
import Darwin

struct AgentXStopOperation: Codable, Equatable, Identifiable {
    enum Status: String, Codable { case stopping, unverified, stopped }
    struct Item: Codable, Equatable, Identifiable {
        enum Kind: String, Codable { case task, runtime }
        enum Status: String, Codable { case waiting, confirmed, unverified }
        var id: String
        var title: String
        var kind: Kind
        var status: Status = .waiting
        var observedAt: Date?
        var detail: String?
        var owner: AgentXStopProcessIdentity?
        var runtimeCore: String?
    }
    var id: UUID = UUID()
    var appID: String
    var startedAt: Date = Date()
    var updatedAt: Date = Date()
    var status: Status = .stopping
    var items: [Item]
    var persistenceFailure: String?
}

struct AgentXRuntimeObservation: Equatable {
    var title: String
    var observedAt: Date?
}

struct AgentXStopOperationStore {
    let root: URL
    private func safeURL(_ relative: String) throws -> URL {
        var cursor = root.standardizedFileURL
        for part in [""] + relative.split(separator: "/").map(String.init) {
            if !part.isEmpty { cursor.appendPathComponent(part) }
            if (try? cursor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw AgentXError.unsafePath }
        }
        return cursor
    }
    struct Document: Codable { var version = 1; var operations: [String: AgentXStopOperation] }
    func load() throws -> [String: AgentXStopOperation] {
        let url = try safeURL("manager/stop-operations.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
        guard document.version == 1, document.operations.allSatisfy({ $0.key == $0.value.appID }) else { throw AgentXError.unavailable }
        return document.operations
    }
    func save(_ operations: [String: AgentXStopOperation]) throws {
        let url = try safeURL("manager/stop-operations.json")
        for operation in operations.values {
            let archive = try safeURL("manager/stop-history/" + operation.id.uuidString + ".json")
            try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(operation).write(to: archive, options: .atomic)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Document(operations: operations)).write(to: url, options: .atomic)
    }
}

struct AgentXStopProcessIdentity: Codable, Equatable {
    var pid: Int32
    var seconds: UInt64
    var microseconds: UInt64
    static func read(_ pid: Int32) -> Self? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
              info.pbi_pid == UInt32(pid), info.pbi_uid == getuid() else { return nil }
        return .init(pid: pid, seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
    }
    func definitelyExited(read: (Int32) -> Self? = Self.read, absent: (Int32) -> Bool = { kill($0, 0) == -1 && errno == ESRCH }) -> Bool {
        if let current = read(pid) { return current != self }
        return absent(pid)
    }
}

enum AgentXStopFailure: Error {
    case unregistered, activeWork, replacedRuntime, unavailable
    var safeMessage: String {
        switch self {
        case .unregistered: "运行器未注册停止确认，请检查宿主适配器。"
        case .activeWork: "运行器仍有活动工作或尚未确认退出，请稍后重试。"
        case .replacedRuntime: "运行器已更换，旧停止证据失效，请重新检查。"
        case .unavailable: "停止检查不可用，请确认宿主运行器后重试。"
        }
    }
}
