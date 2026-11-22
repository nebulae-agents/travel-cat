import Foundation
import CoreFoundation
import Darwin

/// Restricted daemon bridge. The caller supplies metadata only; credentials stay in Swift.
@MainActor
final class AgentXAuditHelper {
    static let maximumInput = 16 * 1024
    private let appID: String
    private let rootPath: String
    private let identities: [(URL, UInt64, UInt64)]
    private let store: AgentAuditStore
    private static var invalid: WorkbenchFailure { WorkbenchFailure("AgentX audit request rejected.") }

    init(root path: String, appID: String, credentials: any TravelServiceCredentialStoring) throws {
        let root = URL(fileURLWithPath: path)
        guard path.hasPrefix("/"), !path.contains("\0"), let resolved = realpath(path, nil) else { throw Self.invalid }
        defer { free(resolved) }
        guard String(cString: resolved) == path else { throw Self.invalid }
        try Self.privateDirectory(root)
        try AgentXPackageFiles.validateID(appID)
        guard let pilot = try AgentXPilot.readMarker(at: root),
              pilot.root == path, pilot.appIDs.contains(appID) else { throw Self.invalid }
        var info = stat()
        let directory = try AgentXRunAudit.directory(root: root, appID: appID)
        for url in [root.appendingPathComponent("audit"), directory] {
            if lstat(url.path, &info) == 0 { try Self.privateDirectory(url) }
            else if errno != ENOENT { throw Self.invalid }
        }
        self.appID = appID
        rootPath = path
        store = try AgentAuditStore.open(root: directory, credentials: credentials)
        identities = try [root, root.appendingPathComponent("audit"), directory].map { url in
            try Self.privateDirectory(url)
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw Self.invalid }
            return (url, UInt64(info.st_dev), UInt64(info.st_ino))
        }
    }
    private static func privateDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw invalid }
    }
    func execute(_ input: Data) throws -> [String: Any] {
        // A service session keeps the key in Swift, but never keeps authority over a replaced root.
        guard let resolved = realpath(rootPath, nil) else { throw Self.invalid }
        defer { free(resolved) }
        guard String(cString: resolved) == rootPath else { throw Self.invalid }
        for (url, device, inode) in identities {
            try Self.privateDirectory(url)
            var info = stat()
            guard lstat(url.path, &info) == 0, UInt64(info.st_dev) == device, UInt64(info.st_ino) == inode else { throw Self.invalid }
        }
        guard let pilot = try AgentXPilot.readMarker(at: URL(fileURLWithPath: rootPath)),
              pilot.root == rootPath, pilot.appIDs.contains(appID) else { throw Self.invalid }
        guard input.count <= Self.maximumInput,
              let request = try JSONSerialization.jsonObject(with: input) as? [String: Any], let op = request["op"] as? String else { throw Self.invalid }
        switch op {
        case "append":
            guard Set(request.keys) == ["op", "record"], let record = request["record"] as? [String: Any] else { throw Self.invalid }
            try validate(record)
            try store.appendIdempotent(record: record)
            return ["ok": true]
        case "records":
            guard Set(request.keys) == ["op", "runId"], let run = request["runId"] as? String, let id = UUID(uuidString: run) else { throw Self.invalid }
            let records = try store.records(taskID: id)
            // Desktop journals may contain additional fields. Never expose content through this bridge.
            let filtered = records.filter { $0["appId"] as? String == appID }.map { $0.filter { Self.fields.contains($0.key) } }
            return ["ok": true, "records": filtered]
        case "verify":
            guard Set(request.keys) == ["op"] else { throw Self.invalid }
            return ["ok": true, "records": try store.inventory().records]
        default: throw Self.invalid
        }
    }
    private static let fields: Set<String> = ["eventId", "taskId", "appId", "instanceId", "providerId", "model", "promptBytes", "requestTextBytes", "responseBytes", "kind", "timestamp", "status"]
    private func validate(_ record: [String: Any]) throws {
        let required = Self.fields.subtracting(["responseBytes", "status"])
        guard Set(record.keys).isSubset(of: Self.fields), required.isSubset(of: Set(record.keys)), record["appId"] as? String == appID else { throw Self.invalid }
        for key in ["eventId", "taskId"] {
            guard let value = record[key] as? String, UUID(uuidString: value) != nil else { throw Self.invalid }
        }
        for key in ["instanceId", "providerId", "model"] {
            guard let value = record[key] as? String, !value.isEmpty, value.utf8.count <= 256,
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Self.invalid }
        }
        for key in ["promptBytes", "requestTextBytes", "responseBytes"] where record[key] != nil {
            guard let value = record[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite, value.doubleValue >= 0, value.doubleValue <= 1_073_741_824,
                  value.doubleValue.rounded() == value.doubleValue else { throw Self.invalid }
        }
        guard let kind = record["kind"] as? String, ["started", "cancel_requested", "completed", "failed", "cancelled"].contains(String(kind.dropFirst("model.request.".count))), kind.hasPrefix("model.request."),
              let timestamp = record["timestamp"] as? String, timestamp.utf8.count <= 40 else { throw Self.invalid }
        let formatter = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard formatter.date(from: timestamp) != nil || fractional.date(from: timestamp) != nil else { throw Self.invalid }
        if ["model.request.completed", "model.request.failed", "model.request.cancelled"].contains(kind) {
            guard record["responseBytes"] != nil, record["status"] as? String == String(kind.dropFirst("model.request.".count)) else { throw Self.invalid }
        } else if record["responseBytes"] != nil || record["status"] != nil { throw Self.invalid }
    }
    private static func readInput() throws -> Data {
        var input = Data()
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw invalid }
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(remaining * 1000))
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0 else { throw invalid }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw invalid }
            if count == 0 { return input }
            input.append(contentsOf: buffer.prefix(count))
            guard input.count <= maximumInput else { throw invalid }
        }
    }
    /// Idle sessions may wait indefinitely; an incomplete frame still has a 10s deadline.
    private static func readFrame(buffer: inout Data) throws -> Data? {
        var deadline: TimeInterval? = buffer.isEmpty ? nil : ProcessInfo.processInfo.systemUptime + 10
        while true {
            if let newline = buffer.firstIndex(of: 10) {
                guard buffer.distance(from: buffer.startIndex, to: newline) <= maximumInput else { throw invalid }
                let frame = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                return frame
            }
            guard buffer.count <= maximumInput else { throw invalid }
            let budget = deadline.map { $0 - ProcessInfo.processInfo.systemUptime }
            if let budget { guard budget > 0 else { throw invalid } }
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, budget.map { Int32($0 * 1000) } ?? -1)
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0 else { throw invalid }
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw invalid }
            if count == 0 {
                guard buffer.isEmpty else { throw invalid }
                return nil
            }
            if deadline == nil { deadline = ProcessInfo.processInfo.systemUptime + 10 }
            buffer.append(contentsOf: bytes.prefix(count))
        }
    }
    private static func writeReply(_ result: [String: Any]) throws {
        let output = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        guard output.count <= 4 * 1024 * 1024 else { throw invalid }
        FileHandle.standardOutput.write(output + Data([10]))
    }
    static func dispatch(arguments: [String]) -> Never {
        do {
            guard arguments.count == 5, ["--agentx-audit-helper", "--agentx-audit-session"].contains(arguments[0]),
                  arguments[1] == "--root", arguments[3] == "--app" else { throw invalid }
            if arguments[0] == "--agentx-audit-session" {
                let helper = try AgentXAuditHelper(root: arguments[2], appID: arguments[4], credentials: KeychainTravelServiceCredentialStore(service: "com.nebulae.agentx.model-services"))
                try writeReply(["ok": true, "ready": true])
                var buffer = Data()
                while let input = try readFrame(buffer: &buffer) { try writeReply(helper.execute(input)) }
            } else {
                let input = try readInput()
                let helper = try AgentXAuditHelper(root: arguments[2], appID: arguments[4], credentials: KeychainTravelServiceCredentialStore(service: "com.nebulae.agentx.model-services"))
                try writeReply(helper.execute(input))
            }
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("AgentX audit request rejected.\n".utf8))
            exit(1)
        }
    }
}
