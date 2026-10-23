import Foundation

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

    mutating func upsert(_ item: NativeTimelineItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item }
        else { items.append(item) }
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
