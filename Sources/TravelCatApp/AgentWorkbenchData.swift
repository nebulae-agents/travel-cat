import Foundation

struct WorkbenchFailure: LocalizedError {
    let message: String
    let taskRetained: Bool?
    var errorDescription: String? { message }
    init(_ message: String, taskRetained: Bool? = nil) { self.message = message; self.taskRetained = taskRetained }
}

enum WorkbenchAPI: String, Codable, CaseIterable, Identifiable {
    case responses, messages, chatCompletions
    var id: String { rawValue }
    var title: String {
        switch self { case .responses: "Responses"; case .messages: "Messages"; case .chatCompletions: "Chat Completions" }
    }
}

struct WorkbenchProvider: Codable, Equatable, Sendable {
    var baseURL = "https://api.openai.com/v1"
    var model = ""
    var api: WorkbenchAPI = .responses
    var credentialID = UUID().uuidString
    func validate() throws {
        guard let url = URLComponents(string: baseURL), url.scheme == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              ["", "/", "/v1", "/v1/"].contains(url.path),
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkbenchFailure("请填写 HTTPS 模型服务地址（域名或 /v1），不含账号、查询参数，并指定模型。")
        }
    }
}

struct WorkbenchInstance: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var image: String
    var command: [String]
    var host = ""
    var dockerContext = ""
    var role = ""
    var symbol = "terminal"
    var provider = WorkbenchProvider()
    var native: NativeRuntimeConfiguration? = nil
    var runtimeKind: WorkbenchRuntimeKind { native == nil ? .acpDocker : .codexNative }
    func validate() throws {
        if let native {
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WorkbenchFailure("请填写实例名称。") }
            try native.validate(); return
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              image.range(of: #"^[A-Za-z0-9][A-Za-z0-9._/:-]*@sha256:[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              !command.isEmpty, !command[0].hasPrefix("-"), command.allSatisfy({ !$0.isEmpty && !$0.contains("\0") && !$0.contains("\n") }),
              command.count <= 64, command.allSatisfy({ $0.utf8.count <= 4096 }) else {
            throw WorkbenchFailure("请输入实例名称、固定 sha256 镜像和启动命令；每行一个参数。")
        }
        guard dockerContext.isEmpty || dockerContext.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$"#, options: .regularExpression) != nil else {
            throw WorkbenchFailure("Docker context 只能包含字母、数字、点、横线和下划线。")
        }
        guard host.isEmpty || host.range(of: #"^(?:[A-Za-z0-9][A-Za-z0-9_.-]{0,63}@)?[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$"#, options: .regularExpression) != nil else {
            throw WorkbenchFailure("远程主机须为 SSH 别名或 user@host，不能包含选项或空格。")
        }
    }
}

enum WorkbenchTaskStatus: String, Codable, Sendable {
    case connecting, running, awaitingPermission, cancelling, completed, cancelled, failed, unknown
    var title: String {
        switch self {
        case .connecting: "连接中"; case .running: "执行中"; case .awaitingPermission: "等待确认"
        case .cancelling: "正在取消"; case .completed: "本轮完成"; case .cancelled: "已取消"
        case .failed: "失败"; case .unknown: "状态待核实"
        }
    }
    var active: Bool { [.connecting, .running, .awaitingPermission, .cancelling].contains(self) }
}

struct WorkbenchMessage: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var role: String
    var text: String
    var date = Date()
    var runtimeItemID: String? = nil
}
struct WorkbenchTask: Codable, Identifiable, Sendable {
    var modelPolicy: String? = nil
    var id = UUID()
    var instanceID: UUID
    var title: String
    var status: WorkbenchTaskStatus = .connecting
    var sessionID: String?
    var parentTaskID: UUID?
    var messages: [WorkbenchMessage] = []
    var unread = false
    var createdAt = Date()
    var nativeState: NativeTaskState? = nil
    var artifactReviews: [WorkbenchArtifactReview]? = nil
}
struct WorkbenchSnapshot: Codable, Sendable {
    var schemaVersion = 1
    var auditRetentionDays: Int?
    var instances: [WorkbenchInstance] = []
    var tasks: [WorkbenchTask] = []
    var pythonPath = "/opt/homebrew/bin/python3"
    var drafts: WorkbenchDraftCollection? = nil
}

struct WorkbenchStore {
    let root: URL
    let keyData: Data?
    // Nil keys are retained only for legacy fixtures/offline tools; app entry points use encrypted(root:credentials:).
    init(root: URL, keyData: Data? = nil) { self.root = root; self.keyData = keyData }
    var legacyURL: URL { root.appendingPathComponent("workbench.json") }
    var url: URL { root.appendingPathComponent(keyData == nil ? "workbench.json" : "workbench.sealed") }
    func load() throws -> WorkbenchSnapshot {
        let raw: Data
        if let keyData {
            guard let data = try EncryptedWorkbenchStorage(root: root, keyData: keyData).load() else { return WorkbenchSnapshot() }
            raw = data
        } else {
            guard FileManager.default.fileExists(atPath: url.path) else { return WorkbenchSnapshot() }
            raw = try Data(contentsOf: url)
        }
        guard raw.count <= 64 * 1024 * 1024 else { throw WorkbenchFailure("Agent 数据超过保存上限，原文件未覆盖。") }
        var state = try JSONDecoder().decode(WorkbenchSnapshot.self, from: raw)
        try state.drafts?.validate()
        guard state.schemaVersion == 1 else { throw WorkbenchFailure("不支持的 Agent 配置版本，未覆盖原文件。") }
        for index in state.tasks.indices {
            if state.tasks[index].nativeState != nil { state.tasks[index].nativeState?.connection = .disconnected }
        }
        for index in state.tasks.indices where state.tasks[index].status.active {
            state.tasks[index].status = .unknown
            state.tasks[index].unread = true
        }
        return state
    }
    func save(_ state: WorkbenchSnapshot) throws {
        guard state.schemaVersion == 1 else { throw WorkbenchFailure("不支持的配置版本。") }
        try state.drafts?.validate()
        if let keyData {
            try EncryptedWorkbenchStorage(root: root, keyData: keyData).save(JSONEncoder().encode(state))
            return
        }
        guard !root.resolvingSymlinksInPath().path.hasPrefix("/dev/") else { throw WorkbenchFailure("无效的存储位置。") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoded = try JSONEncoder().encode(state)
        guard encoded.count <= 64 * 1024 * 1024 else { throw WorkbenchFailure("Agent 数据超过保存上限，原文件未覆盖。") }
        try encoded.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
