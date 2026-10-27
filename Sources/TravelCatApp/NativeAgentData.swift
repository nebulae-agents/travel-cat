import Foundation

/// Find a local Codex without invoking a shell or reading any account state.
enum NativeCodexExecutableDiscovery {
    static func detect(environmentPath: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
                       applicationDirectories: [URL] = [URL(fileURLWithPath: "/Applications"),
                           FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")],
                       isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String {
        let directories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
            + environmentPath.split(separator: ":").map(String.init)
        let candidates = directories.filter { $0.hasPrefix("/") }.map {
            URL(fileURLWithPath: $0).appendingPathComponent("codex").path
        } + applicationDirectories.flatMap { directory in
            ["Codex.app/Contents/Resources/codex",
             "ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"].map {
                directory.appendingPathComponent($0).path
            }
        }
        return candidates.first(where: isExecutable) ?? ""
    }
}

/// The product contract is independent of a runtime's transport and authentication.
enum WorkbenchRuntimeKind: String, Codable, Sendable {
    case acpDocker, codexNative
}

struct NativeRuntimeConfiguration: Codable, Equatable, Sendable {
    var executable: String
    var workspace: String
    var model: String

    func validate(requireModel: Bool = true) throws {
        let fm = FileManager.default
        var directory: ObjCBool = false
        let location = URL(fileURLWithPath: workspace).resolvingSymlinksInPath().standardizedFileURL
        guard executable.hasPrefix("/"), !executable.contains("\n"), !executable.contains("\0"),
              fm.isExecutableFile(atPath: executable),
              workspace.hasPrefix("/"), !workspace.contains("\n"), !workspace.contains("\0"),
              fm.fileExists(atPath: workspace, isDirectory: &directory), directory.boolValue,
              location.path != "/", location != fm.homeDirectoryForCurrentUser.resolvingSymlinksInPath(),
              !requireModel || !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkbenchFailure("请选择可执行的 Codex、独立工作目录和可用模型；不能使用整个个人目录或磁盘根目录。")
        }
    }
}

enum NativeConnectionState: String, Codable, Sendable {
    case connected, reconnecting, disconnected
    var title: String {
        switch self { case .connected: "已连接"; case .reconnecting: "正在核对会话"; case .disconnected: "连接已断开" }
    }
}
struct NativeOperation: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable { case start, prompt, approval, interrupt, resume, detach }
    enum Status: String, Codable, Sendable { case requested, accepted, confirmed, unknown, rejected }
    var id = UUID()
    var kind: Kind
    var targetID: String
    var status: Status = .requested
    var createdAt = Date()
}
struct NativeTimelineItem: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var turnID: String?
    var kind: String
    var title: String
    var detail: String
    var status: String
    /// Nil in legacy snapshots, whose old default "completed" was not evidence.
    var completionObserved: Bool? = nil
    var reconciledStatus: String? = nil
    var liveCompletionObserved: Bool? = nil
    var evidenceStatus: String { reconciledStatus ?? status }

    // Official App Server schema: each typed process has its own closed status enum.
    static func terminalStatuses(for kind: String) -> Set<String> {
        switch kind {
        case "commandExecution", "fileChange": ["completed", "failed", "declined"]
        case "mcpToolCall", "dynamicToolCall": ["completed", "failed"]
        case "collabAgentToolCall": ["completed", "failed", "interrupted"]
        default: []
        }
    }
    static let statuslessKinds: Set<String> = ["userMessage", "hookPrompt", "agentMessage", "functionCallOutput", "plan", "reasoning", "subAgentActivity", "webSearch", "imageView", "sleep", "enteredReviewMode", "exitedReviewMode", "contextCompaction"]
    var hasTerminalEvidence: Bool {
        completionObserved == true && (Self.terminalStatuses(for: kind).contains(evidenceStatus) || Self.statuslessKinds.contains(kind) && evidenceStatus == "unknown")
    }

    func accepts(_ incoming: NativeTimelineItem) -> Bool {
        guard id == incoming.id, turnID == incoming.turnID, kind == incoming.kind else { return false }
        guard hasTerminalEvidence else { return true }
        // A status-only query cannot freeze partial output before the actual final event arrives.
        return liveCompletionObserved != true && incoming.liveCompletionObserved == true &&
            incoming.hasTerminalEvidence && incoming.evidenceStatus == evidenceStatus
    }
}
struct NativeTaskState: Codable, Equatable, Sendable {
    var executionID = UUID()
    var threadID: String?
    var turnID: String?
    var connection: NativeConnectionState = .disconnected
    var pendingOperation: NativeOperation?
    var items: [NativeTimelineItem] = []
    var lastReconciledAt: Date?
    var historyNotice: String?
    var turnStatuses: [String: String]? = nil

    static let terminalTurnStatuses: Set<String> = ["completed", "failed", "interrupted"]

    mutating func recordTurnStatus(_ turn: String, status: String?) {
        guard let status, Self.terminalTurnStatuses.union(["inProgress"]).contains(status),
              !Self.terminalTurnStatuses.contains(turnStatuses?[turn] ?? "") else { return }
        if turnStatuses == nil { turnStatuses = [:] }
        turnStatuses?[turn] = status
    }

    mutating func upsert(_ item: NativeTimelineItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            guard items[index].accepts(item) else { return }
            items[index] = item
        } else { items.append(item) }
    }
}
struct NativeApprovalBinding: Equatable, Sendable {
    let requestHash: String
    let threadID: String
    let turnID: String
    let itemID: String
    let expiresAt: Date
}
struct NativeModelChoice: Identifiable, Equatable, Sendable {
    let id: String
    let model: String
    let name: String
    let isDefault: Bool
}
struct NativeConnectionInfo: Equatable, Sendable {
    var authenticated: Bool
    var authMode: String?
    var version: String
    var models: [NativeModelChoice]
    var capabilities: [String: Bool]
    var notice: String?

    static func decode(_ data: [String: Any]) throws -> Self {
        guard data["connected"] as? Bool == true, let account = data["account"] as? [String: Any] else {
            throw WorkbenchFailure("Codex 连接未确认，请检查本机版本和权限。")
        }
        let models = (data["models"] as? [[String: Any]] ?? []).compactMap { value -> NativeModelChoice? in
            guard let model = value["model"] as? String, !model.isEmpty else { return nil }
            return .init(id: value["id"] as? String ?? model, model: model, name: value["displayName"] as? String ?? model, isDefault: value["isDefault"] as? Bool ?? false)
        }
        return .init(authenticated: account["authenticated"] as? Bool ?? false,
                     authMode: account["authMode"] as? String, version: data["version"] as? String ?? "未知版本",
                     models: models, capabilities: (data["capabilities"] as? [String: Any] ?? [:]).compactMapValues { $0 as? Bool })
    }
}

/// Current observations are intentionally not Codable and never enter a task snapshot.
struct NativeBackgroundBinding: Equatable, Sendable {
    let taskID: UUID
    let instanceID: UUID
    let executionID: UUID
    let threadID: String
    let turnID: String?
    let operationID: UUID?
    let connectionGeneration: UUID?
    let revision: UUID?
}

struct NativeBackgroundObservation: Equatable, Sendable {
    let count: Int
    let itemIDs: [String]
    let checkedAt: Date
    let requestToken: UUID
    let binding: NativeBackgroundBinding
}

struct NativeBackgroundRequest: Equatable, Sendable {
    let token: UUID
    let binding: NativeBackgroundBinding
    let visibilityToken: UUID?
}

struct NativeBackgroundPendingRefresh {
    let token: UUID
    let binding: NativeBackgroundBinding
    let visibilityToken: UUID
    let continuation: CheckedContinuation<Void, Never>
}
