import Foundation
import Combine
import CryptoKit
import OSLog

struct WorkbenchPermission: Identifiable {
    let id: String
    let taskID: UUID
    let title: String
    let detail: String
    let options: [Option]
    var nativeBinding: NativeApprovalBinding? = nil
    struct Option: Identifiable { let id: String; let title: String; let kind: String }
}

struct WorkbenchModelApproval: Identifiable {
    var id: UUID { callID }
    let taskID: UUID
    let callID: UUID
    let requestHash: String
    let destination: String
    let model: String
}

@MainActor
final class AgentWorkbenchModel: ObservableObject {
    @Published var state: WorkbenchSnapshot
    @Published var permissions: [WorkbenchPermission] = []
    @Published private(set) var modelApprovals: [WorkbenchModelApproval] = []
    @Published var auditError: String?
    @Published var auditRevision = 0
    @Published private(set) var storageNotice: String?
    var auditStore: (any AgentAuditStoring)?
    var nativeDeciding: Set<String> = []
    @Published var nativeRecovering: Set<UUID> = []
    @Published var nativeDetaching: Set<UUID> = []
    var nativeInterruptPending: Set<UUID> = []
    var nativeInterruptUnverified: Set<UUID> = []
    var nativeInterruptEvents: [UUID: [String: Any]] = [:]
    @Published var nativeBackgroundStopping: Set<UUID> = []
    @Published var nativeBackgroundObservations: [UUID: NativeBackgroundObservation] = [:]
    @Published var nativeBackgroundRequests: [UUID: NativeBackgroundRequest] = [:]
    @Published var nativeReconciliationRequests: [UUID: NativeBackgroundRequest] = [:]
    @Published var nativeReconciliationNotices: [UUID: String] = [:]
    var nativeBackgroundPendingRefreshes: [UUID: NativeBackgroundPendingRefresh] = [:]
    var nativeBackgroundRevisions: [UUID: UUID] = [:]
    var nativeConnectionGenerations: [UUID: UUID] = [:]
    var nativeBackgroundVisibility: [UUID: UUID] = [:]
    var nativeEventBuffers: [UUID: [[String: Any]]] = [:]
    @Published var nativeConnections: [UUID: NativeConnectionInfo] = [:]
    @Published var nativeBusy: Set<UUID> = []
    @Published var nativeNotice: String?
    @Published var nativeLoginIDs: [UUID: String] = [:]
    private var decidingCalls: Set<UUID> = []
    var hasConversationDecisionInFlight: Bool { !decidingCalls.isEmpty || !nativeDeciding.isEmpty }
    @Published var conversationNavigationRevision = 0
    @Published var conversationControls: Set<UUID> = []
    @Published var acpPermissionReplies: [UUID: Set<String>] = [:]
    @Published var selectedTaskID: UUID?
    @Published var preferredInstanceID: UUID?
    @Published var error: String?
    @Published private(set) var discovery = ""
    @Published private(set) var discovering = false
    @Published private(set) var availableImages: [String] = []
    @Published private(set) var localInventory: LocalRuntimeInventory?
    @Published private(set) var localScanError: String?
    @Published private(set) var scanningLocal = false
    @Published private(set) var probingLocal = false
    @Published private(set) var probeVerification: RuntimeProbeVerification?
    @Published private(set) var probeNotice: String?
    @Published private(set) var retainedProbe: (id: UUID, containerName: String?)?
    var store: WorkbenchStore
    let synchronousCredentials: (any TravelServiceCredentialStoring)?
    let credentialStores: AgentWorkbenchCredentialStores?
    @Published var storageStatus: AgentWorkbenchStorageStatus = .loading
    @Published var savingInstance = false
    var storageTask: Task<Void, Never>?
    var storageGeneration = UUID()
    var hasShutdown = false
    var isStorageReady: Bool { !loadFailed && storageStatus == .ready && !hasShutdown }
    let client: any AgentRuntimeClient
    private var saveTask: Task<Void, Never>?
    var draftSaveTask: Task<Void, Never>?
    var draftsDirty = false
    @Published var draftSaveNotice: String?
    @Published var submittingDrafts: [WorkbenchDraftTarget: Set<UUID>] = [:]
    var artifactReadRevisions: [UUID:UUID] = [:]
    var artifactReadRequests: Set<UUID> = []
    @Published var artifactInventories: [UUID:WorkbenchArtifactInventory] = [:]
    @Published var artifactHistoryNotice: [UUID:String] = [:]
    var liveTasks: Set<UUID> = []
    var loadFailed = false
    @Published private var startingSubmissionID: UUID?
    var isStarting: Bool { startingSubmissionID != nil }
    var attentionCount: Int { permissions.count + modelApprovals.count + state.tasks.filter(\.unread).count }

    init(root: URL, credentials: any TravelServiceCredentialStoring, client: (any AgentRuntimeClient)? = nil, auditStore: (any AgentAuditStoring)? = nil) {
        let contentStore: WorkbenchStore
        var contentError: Error?
        do { contentStore = try WorkbenchStore.encrypted(root: root, credentials: credentials) }
        catch { contentStore = WorkbenchStore(root: root, keyData: Data()); contentError = error }
        store = contentStore
        self.synchronousCredentials = credentials
        self.credentialStores = nil
        self.client = client ?? AgentSidecarClient()
        do { if let contentError { throw contentError }; state = try store.load() }
        catch {
            state = WorkbenchSnapshot(); loadFailed = true
            let reason = Self.storageFailureDescription(error)
            self.error = "Agent 数据读取失败，原文件未覆盖。\n" + reason
            Logger(subsystem: "com.nebulae.travelcat", category: "AgentStorage").error("Content storage open failed: \(reason, privacy: .public)")
        }
        do {
            self.auditStore = try auditStore ?? AgentAuditStore.open(root: root.appendingPathComponent("audit-v1"), credentials: credentials)
        } catch {
            let reason = Self.storageFailureDescription(error)
            auditError = "审计存储无法打开，受控调用已阻止。\n" + reason
            Logger(subsystem: "com.nebulae.travelcat", category: "AgentStorage").error("Audit storage open failed: \(reason, privacy: .public)")
        }
        if loadFailed || auditError != nil {
            loadFailed = true
            storageStatus = .blocked(self.error ?? auditError ?? "安全存储不可用，请重试。")
        } else { storageStatus = .ready }
        configureClient()
        Task { [weak self] in self?.applyScheduledRetention() }
    }

    init(root: URL, credentialStores: AgentWorkbenchCredentialStores = .system(), client: (any AgentRuntimeClient)? = nil) {
        store = WorkbenchStore(root: root, keyData: Data())
        state = WorkbenchSnapshot()
        synchronousCredentials = nil
        self.credentialStores = credentialStores
        self.client = client ?? AgentSidecarClient()
        loadFailed = true
        configureClient()
    }

    private func configureClient() {
        self.client.onEvent = { [weak self] event in self?.receive(event) }
        self.client.onExit = { [weak self] in
            guard let self, self.isStorageReady else { return }
            for index in self.state.tasks.indices where self.liveTasks.contains(self.state.tasks[index].id) {
                if self.state.tasks[index].status.active { self.state.tasks[index].status = .unknown; self.state.tasks[index].unread = true }
                self.state.tasks[index].cleanupEvidence = nil
                if self.state.tasks[index].requiresConversationAttention { self.state.tasks[index].archivedAt = nil }
            }
            for index in self.state.tasks.indices where self.state.tasks[index].nativeState != nil {
                self.state.tasks[index].nativeState?.connection = .disconnected
                if self.state.tasks[index].nativeState?.pendingOperation?.status == .requested { self.state.tasks[index].nativeState?.pendingOperation?.status = .unknown }
            }
            self.invalidateAllArtifactReads()
            self.invalidateAllNativeBackgroundStatus()
            self.nativeConnectionGenerations.removeAll()
            self.nativeConnections.removeAll()
            self.permissions.removeAll(); self.modelApprovals.removeAll(); self.liveTasks.removeAll()
            self.probeVerification = nil
            self.persist(); self.applyScheduledRetention()
        }

    }

    static func storageFailureDescription(_ error: Error) -> String {
        if case let TravelServiceCredentialError.keychain(status) = error {
            return "系统钥匙串访问失败（\(status)）。请解锁钥匙串并允许 Travel Cat 访问，然后点击工作台中的“重试”。"
        }
        if error is WorkbenchFailure || error is TravelServiceCredentialError { return error.localizedDescription }
        if error is DecodingError { return "保存的 Agent 数据格式无法读取；原文件已保留。" }
        if case CryptoKitError.authenticationFailure = error { return "加密校验失败，当前密钥与数据不匹配；请保留原钥匙串和数据。" }
        let failure = error as NSError
        return "存储操作失败（\(failure.domain)，\(failure.code)）；请保留原数据。"
    }

    func openInstance(_ id: UUID) {
        guard state.instances.contains(where: { $0.id == id }) else { return }
        preferredInstanceID = id
        let tasks = state.tasks.filter { $0.instanceID == id }.sorted { $0.createdAt > $1.createdAt }
        let pending = Set(permissions.map(\.taskID) + modelApprovals.map(\.taskID))
        let selection = (tasks.first { pending.contains($0.id) }
            ?? tasks.first { $0.unread }
            ?? tasks.first { $0.status.active }
            ?? tasks.first)?.id
        if let selection { openConversation(selection) } else { selectedTaskID = nil }
    }

    func save(instance: WorkbenchInstance, newKey: String) throws {
        guard let credentials = synchronousCredentials else { throw WorkbenchFailure("请使用异步保存，安全存储未确认。") }
        guard isStorageReady else { throw WorkbenchFailure("原数据读取失败，禁止覆盖。") }
        guard !savingInstance else { throw WorkbenchFailure("正在保存 Agent，请稍候。") }
        let next = try snapshotSaving(instance)
        if instance.native == nil && !newKey.isEmpty { try credentials.save(newKey, id: instance.provider.credentialID) }
        try store.save(next); state = next
    }
    func remove(instanceID: UUID) {
        guard isStorageReady, let credentials = synchronousCredentials else { error = "安全存储尚未就绪，删除已阻止。"; return }
        guard !state.tasks.contains(where: { $0.instanceID == instanceID && liveTasks.contains($0.id) }) else {
            error = "请先结束该实例的会话。"; return
        }
        guard let instance = state.instances.first(where: { $0.id == instanceID }) else { return }
        guard draft(for: .new(instanceID)).isEmpty else { error = "该 Agent 还有未发送草稿，请先保留或清空草稿再删除。"; return }
        guard instance.native == nil || !state.tasks.contains(where: { $0.instanceID == instanceID }) else {
            error = "此原生实例仍有会话记录，需保留配置以便恢复和控制后台任务。"; return
        }
        do {
            var next = state; next.instances.removeAll { $0.id == instanceID }
            try store.save(next); state = next
            if !state.instances.contains(where: { $0.id == preferredInstanceID }) {
                if let remaining = state.instances.first { openInstance(remaining.id) }
                else { preferredInstanceID = nil; selectedTaskID = nil }
            }
            if instance.native == nil { try credentials.save(nil, id: instance.provider.credentialID) }
        } catch { self.error = "删除实例或清理凭据失败，请重试。" }
    }
    func setPythonPath(_ path: String) {
        guard isStorageReady else { return }
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { error = "请选择可执行的 Python 3.11+ 绝对路径。"; return }
        state.pythonPath = path; persist()
    }
    func discover(host: String, context: String = "") async {
        guard isStorageReady else { return }
        guard !discovering else { return }
        discovering = true; defer { discovering = false }
        do {
            try client.launch(python: state.pythonPath)
            let result = try await client.request("discover", ["host": host, "dockerContext": context])
            availableImages = result["images"] as? [String] ?? []
            discovery = result["message"] as? String ?? ((result["docker"] as? Bool == true) ? "Docker 可用" : "Docker 未连接")
        } catch { discovery = error.localizedDescription }
    }
    func scanLocal() async {
        guard isStorageReady else { return }
        guard !scanningLocal else { return }
        scanningLocal = true; defer { scanningLocal = false }
        localInventory = nil; localScanError = nil; probeVerification = nil
        do {
            try client.launch(python: state.pythonPath)
            let result = try await client.request("scan_local", [:], timeout: 90)
            localInventory = try LocalRuntimeInventory.decode(result)
        } catch {
            localScanError = "本机环境扫描失败；请检查 Python、Docker 或权限后重试。"
        }
    }

    func probe(image: LocalRuntimeInventory.Image, preset: ACPAdapterPreset) async {
        guard isStorageReady else { return }
        guard !probingLocal, retainedProbe == nil else { return }
        guard let inventory = localInventory,
              inventory.images.contains(image),
              inventory.contexts.contains(where: { $0.name == image.context && $0.local && $0.available }) else {
            probeNotice = "候选镜像已变化，请重新扫描。"; return
        }
        probeVerification = nil; probeNotice = nil
        let probeID = UUID()
        do {
            try managementRecord("runtime.probe.request", fields: [
                "probeId": probeID.uuidString, "dockerContext": image.context,
                "image": image.ref, "preset": preset.rawValue, "phase": "requested"])
        } catch {
            probeNotice = "审计存储不可用，兼容性检查已阻止。"
            return
        }
        probingLocal = true; defer { probingLocal = false }
        do {
            try client.launch(python: state.pythonPath)
        } catch {
            try? managementRecord("runtime.probe.result", fields: [
                "probeId": probeID.uuidString, "compatible": false,
                "cleanupConfirmed": true, "phase": "launch-failed"])
            probeNotice = "隔离运行服务无法启动，请检查 Python 路径。"
            return
        }
        do {
            let result = try await client.request("probe", ["probeId": probeID.uuidString,
                "dockerContext": image.context, "image": image.ref, "command": preset.command], timeout: 180)
            let cleaned = result["cleanupConfirmed"] as? Bool == true
            let compatible = result["compatible"] as? Bool == true && cleaned
            if !cleaned { retainedProbe = (probeID, result["containerName"] as? String) }
            do {
                try managementRecord("runtime.probe.result", fields: [
                    "probeId": probeID.uuidString, "compatible": compatible,
                    "cleanupConfirmed": cleaned, "phase": "completed"])
            } catch {
                probeNotice = "审计结果未保存；兼容性检查不能用于创建实例。"
                return
            }
            if compatible {
                probeVerification = RuntimeProbeVerification(probeID: probeID, image: image, command: preset.command)
                probeNotice = "ACP 握手与容器清理均已确认。"
            } else {
                probeNotice = cleaned ? "ACP 握手未通过；请核对镜像与命令。" : "容器清理未确认，请先重试清理。"
            }
        } catch {
            let retained = (error as? WorkbenchFailure)?.taskRetained != false
            if retained { retainedProbe = (probeID, nil) }
            try? managementRecord("runtime.probe.result", fields: [
                "probeId": probeID.uuidString, "compatible": false,
                "cleanupConfirmed": !retained, "phase": retained ? "unconfirmed" : "rejected"])
            probeNotice = retained
                ? "兼容性检查结果待核实，请先重试清理或检查本机 Docker。"
                : "当前镜像或本机 Docker 环境已变化，请重新扫描。"
        }
    }

    func retryProbeCleanup() async {
        guard isStorageReady else { return }
        guard let retainedProbe, !probingLocal else { return }
        do {
            try managementRecord("runtime.probe.cleanup", fields: [
                "probeId": retainedProbe.id.uuidString, "phase": "requested"])
        } catch {
            probeNotice = "审计存储不可用，清理操作已阻止。"; return
        }
        probingLocal = true; defer { probingLocal = false }
        do {
            try client.launch(python: state.pythonPath)
            let result = try await client.request("probe_cleanup", ["probeId": retainedProbe.id.uuidString], timeout: 30)
            let cleaned = result["cleanupConfirmed"] as? Bool == true
            if cleaned { self.retainedProbe = nil }
            do {
                try managementRecord("runtime.probe.cleanup", fields: [
                    "probeId": retainedProbe.id.uuidString, "cleanupConfirmed": cleaned, "phase": "completed"])
            } catch {
                probeNotice = "容器状态已核实，但审计结果未保存；请检查审计存储。"
                return
            }
            if cleaned {
                self.retainedProbe = nil
                probeNotice = "隔离容器清理已确认；可重新检查兼容性。"
            } else {
                self.retainedProbe = (retainedProbe.id, result["containerName"] as? String ?? retainedProbe.containerName)
                probeNotice = "清理仍未确认，请检查本机 Docker 后重试。"
            }
        } catch {
            probeNotice = "未能确认清理；请检查 Docker 中的残留容器。"
        }
    }

    func start(instanceID: UUID, text: String, files: [[String: String]] = [], parentTaskID: UUID? = nil, modelPolicy: String = "review", onStarted: (@MainActor () -> Void)? = nil) async {
        guard isStorageReady else { return }
        guard !isStarting else { return }
        guard auditStore != nil, auditError == nil else { error = "审计存储不可用，禁止启动任务。"; return }
        guard ["review", "task"].contains(modelPolicy) else { error = "模型授权策略无效。"; return }
        guard text.count <= 100_000 else { error = "任务正文不能超过 100,000 字符，请缩短后重试；草稿已保留。"; return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let instance = state.instances.first(where: { $0.id == instanceID }), !loadFailed else { return }
        let instruction = instance.role.isEmpty ? text : "角色说明：\(instance.role)\n\n任务：\(text)"
        guard instruction.utf8.count <= 512 * 1024 else {
            error = "任务正文与角色说明合计不能超过 512 KiB（UTF-8），请缩短后重试；草稿已保留。"; return
        }
        let submissionID = UUID()
        startingSubmissionID = submissionID
        defer { if startingSubmissionID == submissionID { startingSubmissionID = nil } }
        do {
            if instance.native != nil {
                try await startNative(instance: instance, text: text, instruction: instruction, files: files, parentTaskID: parentTaskID, onStarted: onStarted)
                return
            }
            try instance.validate(); try instance.provider.validate()
            guard let key = try await readModelCredential(id: instance.provider.credentialID), !key.isEmpty else {
                throw WorkbenchFailure("该实例尚未配置模型凭据，请编辑实例。")
            }
            try Task.checkCancellation()
            try requireStorageReady()
            guard state.instances.first(where: { $0.id == instanceID }) == instance else {
                throw WorkbenchFailure("Agent 配置已变更或已删除，请确认当前配置后重试；草稿已保留。")
            }
            try client.launch(python: state.pythonPath)
            var task = WorkbenchTask(instanceID: instanceID, title: String(text.prefix(64)))
            task.parentTaskID = parentTaskID; task.modelPolicy = modelPolicy
            task.messages.append(.init(role: "user", text: text))
            if !files.isEmpty { task.messages.append(.init(role: "system", text: "已选择输入文件：" + files.compactMap { $0["name"] }.joined(separator: "、"))) }
            state.tasks.insert(task, at: 0); preferredInstanceID = instanceID; selectedTaskID = task.id; liveTasks.insert(task.id); persist()
            let params: [String: Any] = ["taskId": task.id.uuidString,
                "instance": ["name": instance.name, "image": instance.image, "command": instance.command, "host": instance.host, "dockerContext": instance.dockerContext],
                "provider": ["baseURL": instance.provider.baseURL, "apiKey": key, "model": instance.provider.model, "api": instance.provider.api.rawValue], "files": files, "modelPolicy": modelPolicy]
            do {
                let result = try await client.request("start", params, timeout: 180)
                guard liveTasks.contains(task.id),
                      let sessionID = result["sessionId"] as? String,
                      !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw WorkbenchFailure("启动结果未确认，草稿已保留。请检查连接与会话状态，不会自动重发。")
                }
                mutate(task.id) { $0.sessionID = sessionID; $0.status = .running }
                startingSubmissionID = nil
                try await sendPrompt(task.id, instruction)
                onStarted?()
            } catch {
                fail(task.id, error)
                self.error = "提交未成功或结果未确认，请先核对会话；草稿已保留，不会自动重发。"
            }
        } catch { self.error = error.localizedDescription }
    }
    @discardableResult
    func followUp(taskID: UUID, text: String) async -> Bool {
        guard text.count <= 100_000 else { error = "追问不能超过 100,000 字符，请缩短后重试；草稿已保留。"; return false }
        guard text.utf8.count <= 512 * 1024 else {
            error = "追问不能超过 512 KiB（UTF-8），请缩短后重试；草稿已保留。"; return false
        }
        guard canReply(taskID), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if state.tasks.first(where: { $0.id == taskID })?.nativeState != nil {
            do { try await promptNative(taskID, text: text, addUserMessage: true); return true }
            catch { nativeFailure(taskID, error); return false }
        }
        mutate(taskID) { $0.status = .running; $0.messages.append(.init(role: "user", text: text)); $0.unread = false }
        do { try await sendPrompt(taskID, text); return true }
        catch { fail(taskID, error); return false }
    }
    private func sendPrompt(_ id: UUID, _ text: String) async throws {
        invalidateArtifactReads(id)
        _ = try await client.request("prompt", ["taskId": id.uuidString, "text": text], timeout: 3600)
        mutate(id) { if $0.status == .running { $0.status = .completed }; $0.unread = true }
        persist()
    }
    func canReply(_ id: UUID) -> Bool {
        isStorageReady && acpPermissionReplies[id]?.isEmpty != false && !conversationControls.contains(id) && !nativeBackgroundStopping.contains(id) && !nativeRecovering.contains(id) && !nativeDetaching.contains(id) && liveTasks.contains(id) && state.tasks.first(where: { $0.id == id }).map {
            ($0.nativeState == nil || $0.nativeState?.connection == .connected) &&
            ($0.status == .completed || $0.status == .cancelled || ($0.nativeState != nil && $0.status == .failed)) && !($0.sessionID ?? "").isEmpty
        } == true
    }
    func isLive(_ id: UUID) -> Bool { liveTasks.contains(id) }
    func markRead(_ id: UUID?) {
        guard isStorageReady else { return }
        guard let id, state.tasks.contains(where: { $0.id == id && $0.unread }) else { return }; mutate(id) { $0.unread = false }
    }
    func respond(_ request: WorkbenchPermission, option: WorkbenchPermission.Option) async {
        guard isStorageReady else { return }
        if request.nativeBinding != nil { await respondNative(request, option: option); return }
        guard permissions.contains(where: { $0.id == request.id && $0.taskID == request.taskID }),
              acpPermissionReplies[request.taskID, default: []].insert(request.id).inserted else { return }
        defer {
            acpPermissionReplies[request.taskID]?.remove(request.id)
            if acpPermissionReplies[request.taskID]?.isEmpty == true { acpPermissionReplies.removeValue(forKey: request.taskID) }
        }
        permissions.removeAll { $0.id == request.id && $0.taskID == request.taskID }
        do {
            _ = try await client.request("permission", ["taskId": request.taskID.uuidString, "requestId": request.id, "optionId": option.id])
            mutate(request.taskID) { if $0.status == .awaitingPermission { $0.status = permissions.contains(where: { $0.taskID == request.taskID }) ? .awaitingPermission : .running }; $0.messages.append(.init(role: "system", text: "已回复确认：\(option.title)")) }
        } catch { fail(request.taskID, error) }
    }
    func cancel(_ id: UUID) async {
        guard isStorageReady else { return }
        if state.tasks.first(where: { $0.id == id })?.nativeState != nil { await cancelNative(id); return }
        guard conversationControls.insert(id).inserted else { return }
        defer { conversationControls.remove(id) }
        mutate(id) { $0.status = .cancelling }
        do { _ = try await client.request("cancel", ["taskId": id.uuidString]) }
        catch { fail(id, error) }
    }
    func stop(_ id: UUID) async {
        guard isStorageReady else { return }
        invalidateArtifactReads(id)
        if state.tasks.first(where: { $0.id == id })?.nativeState != nil { await detachNative(id); return }
        guard let stoppedTask = state.tasks.first(where: { $0.id == id }) else { return }
        let stoppedSession = stoppedTask.sessionID
        guard conversationControls.insert(id).inserted else { return }
        defer { conversationControls.remove(id) }
        do {
            let result = try await client.request("stop", ["taskId": id.uuidString])
            guard let current = state.tasks.first(where: { $0.id == id }), current.sessionID == stoppedSession else {
                error = "清理回执与当前会话不匹配，请重新核对；当前记录已保留。"; return
            }
            permissions.removeAll { $0.taskID == id }; modelApprovals.removeAll { $0.taskID == id }
            if result["stopped"] as? Bool == true {
                liveTasks.remove(id)
                applyScheduledRetention()
                mutate(id) {
                    if $0.status.active { $0.status = .cancelled }
                    $0.cleanupEvidence = .init(taskID: id, sessionID: $0.sessionID, confirmedAt: Date())
                    $0.messages.append(.init(role: "system", text: "会话已关闭。"))
                }
            } else {
                mutate(id) { $0.status = .unknown; $0.messages.append(.init(role: "system", text: "容器清理尚未确认，请检查连接并重试结束会话。")) }
            }
        } catch { self.error = error.localizedDescription }
    }
    func artifacts(_ id: UUID) async throws -> [[String: Any]] {
        try await listArtifacts(taskID: id).map { ["path": $0.path, "size": $0.size] }
    }
    func export(_ id: UUID, path: String) async throws -> Data {
        try await readArtifactBytes(taskID: id, path: path, expectedSize: nil)
    }
    func shutdown() {
        saveTask?.cancel(); draftSaveTask?.cancel(); persist()
        invalidateAllArtifactReads()
        hasShutdown = true; storageGeneration = UUID(); storageTask?.cancel()
        invalidateAllNativeBackgroundStatus(); nativeBackgroundVisibility.removeAll()
        client.shutdown()
    }

    var canManageRetention: Bool { isStorageReady && liveTasks.isEmpty && !isStarting }
    private static let managementTaskID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    func managementRecord(_ kind: String, fields: [String: Any]) throws {
        guard let auditStore, isStorageReady else { throw WorkbenchFailure("安全存储不可用。") }
        var record = fields
        record["eventId"] = UUID().uuidString; record["taskId"] = Self.managementTaskID.uuidString
        record["kind"] = kind; record["timestamp"] = ISO8601DateFormatter().string(from: Date())
        try auditStore.append(record: record); auditRevision += 1
    }
    func auditInventory() throws -> AgentAuditInventory {
        guard let auditStore else { throw WorkbenchFailure("审计存储不可用。") }
        return try auditStore.inventory()
    }
    func setAuditRetention(days: Int?) throws {
        guard canManageRetention, days == nil || [7, 30, 90].contains(days!) else { throw WorkbenchFailure("请先结束所有会话，再修改保留策略。") }
        try managementRecord("policy.retention", fields: ["phase": "requested", "days": days.map { $0 as Any } ?? NSNull()])
        var next = state; next.auditRetentionDays = days
        try store.save(next); state = next
        storageNotice = "保留策略已保存；下次启动或结束全部会话时清理到期日志。"
    }
    func retentionPreview(before cutoff: Date) throws -> AgentAuditRetentionPreview {
        guard canManageRetention, let auditStore else { throw WorkbenchFailure("请先结束全部会话，再预览清理。") }
        return try auditStore.retentionPreview(before: cutoff)
    }
    func pruneAudit(before cutoff: Date, expectedHead: String) throws {
        guard canManageRetention, let auditStore,
              cutoff <= Date().addingTimeInterval(-7 * 86400) else { throw WorkbenchFailure("清理范围不符合当前保留策略。") }
        let removed = try auditStore.prune(before: cutoff, expectedHead: expectedHead)
        auditRevision += 1; storageNotice = "已清理 \(removed) 条到期日志；保留检查点已保存。" + (auditError == nil ? "" : "请重启应用以重新建立受控调用服务。")
    }
    func applyScheduledRetention() {
        guard canManageRetention, let days = state.auditRetentionDays, [7, 30, 90].contains(days) else { return }
        do {
            let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
            let preview = try retentionPreview(before: cutoff)
            if preview.removableCount > 0 { try pruneAudit(before: cutoff, expectedHead: preview.head) }
        } catch { storageNotice = "到期清理未完成：" + error.localizedDescription }
    }
    func exportAudit(taskID: UUID?, includeContents: Bool, to destination: URL) throws {
        guard let auditStore, isStorageReady else { throw WorkbenchFailure("安全审计不可用，禁止导出。") }
        let internalRoot = store.root.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
        let output = destination.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.appendingPathComponent(destination.lastPathComponent).path.lowercased()
        guard destination.isFileURL, output != internalRoot, !output.hasPrefix(internalRoot + "/") else {
            throw WorkbenchFailure("导出必须保存在应用数据目录之外，避免覆盖对话或破坏审计日志。")
        }
        let exportID = UUID().uuidString
        try managementRecord("audit.export", fields: ["phase": "requested", "exportId": exportID, "includesContents": includeContents, "scope": taskID?.uuidString ?? "all"])
        let data = try auditStore.exportData(taskID: taskID, includeContents: includeContents)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        do { try AgentAuditStore.writePrivate(data, to: destination) }
        catch {
            try? managementRecord("audit.export", fields: ["phase": "failed", "exportId": exportID])
            throw WorkbenchFailure("导出未确认成功，请检查所选位置；未自动重试。")
        }
        do { try managementRecord("audit.export", fields: ["phase": "completed", "exportId": exportID, "sha256": digest, "bytes": data.count, "includesContents": includeContents]) }
        catch { throw WorkbenchFailure("文件已保存，但导出完成审计未确认，请保留文件并核查日志。") }
        storageNotice = "已保存明文 JSON 导出（\(data.count) 字节）；请妥善保管，不会自动上传。"
    }

    func auditRecords(taskID: UUID) -> [[String: Any]] {
        do {
            guard let auditStore else { throw WorkbenchFailure("审计存储不可用。") }
            return try auditStore.records(taskID: taskID)
        } catch { auditError = "审计记录无法读取或验证，受控调用已阻止。"; return [] }
    }

    func respondModel(_ request: WorkbenchModelApproval, allow: Bool) async {
        guard isStorageReady else { return }
        guard modelApprovals.contains(where: { $0.id == request.id && $0.requestHash == request.requestHash }),
              liveTasks.contains(request.taskID), !decidingCalls.contains(request.id), auditError == nil else { return }
        decidingCalls.insert(request.id)
        defer { decidingCalls.remove(request.id) }
        do {
            _ = try await client.request("model_permission", ["taskId": request.taskID.uuidString, "callId": request.callID.uuidString, "requestHash": request.requestHash, "allow": allow])
            modelApprovals.removeAll { $0.id == request.id }
        } catch { self.error = "授权结果未确认，请检查调用记录；不会自动重发。" }
    }

    private func receiveAudit(_ event: [String: Any]) {
        guard let data = event["data"] as? [String: Any], let receipt = data["receiptId"] as? String, UUID(uuidString: receipt) != nil else { return }
        var accepted = false
        do {
            guard auditError == nil, let auditStore,
                  let outer = event["taskId"] as? String, let taskID = UUID(uuidString: outer),
                  state.tasks.contains(where: { $0.id == taskID }),
                  let record = data["record"] as? [String: Any],
                  let inner = record["taskId"] as? String, UUID(uuidString: inner) == taskID,
                  let eventID = record["eventId"] as? String, UUID(uuidString: eventID) != nil,
                  record["kind"] is String else { throw WorkbenchFailure("审计事件无效。") }
            try auditStore.append(record: record)
            accepted = true; auditRevision += 1
            if let kind = record["kind"] as? String, ["model.decision", "model.completed", "model.failed"].contains(kind),
               let call = record["callId"] as? String, let callID = UUID(uuidString: call) {
                modelApprovals.removeAll { $0.id == callID }
            }
        } catch { auditError = "审计持久化失败，后续受控调用已阻止。原记录未覆盖。" }
        let decision = accepted
        Task { [weak self] in
            guard let self else { return }
            do { _ = try await self.client.request("audit_ack", ["receiptId": receipt, "accepted": decision]) }
            catch { self.auditError = "审计回执未确认，调用状态未知；不会自动重发。" }
        }
    }

    private func receive(_ event: [String: Any]) {
        guard isStorageReady else { return }
        if event["event"] as? String == "native" { receiveNative(event); return }
        if event["event"] as? String == "audit" { receiveAudit(event); return }
        guard let value = event["taskId"] as? String, let id = UUID(uuidString: value), liveTasks.contains(id),
              let data = event["data"] as? [String: Any] else { return }
        switch event["event"] as? String {
        case "modelApproval":
            guard let call = data["callId"] as? String, let callID = UUID(uuidString: call),
                  let hash = data["requestHash"] as? String,
                  let record = auditRecords(taskID: id).last(where: { ($0["callId"] as? String).flatMap(UUID.init(uuidString:)) == callID && $0["kind"] as? String == "model.request" }),
                  record["requestHash"] as? String == hash,
                  let destination = record["destination"] as? String, let model = record["model"] as? String,
                  auditError == nil else { return }
            modelApprovals.removeAll { $0.id == callID }
            modelApprovals.append(.init(taskID: id, callID: callID, requestHash: hash, destination: destination, model: model))
            mutate(id) { $0.archivedAt = nil }
        case "permission":
            guard let requestID = data["requestId"] as? String else { return }
            let options = (data["options"] as? [[String: Any]] ?? []).compactMap { item -> WorkbenchPermission.Option? in
                guard let optionID = item["optionId"] as? String else { return nil }
                return .init(id: optionID, title: item["name"] as? String ?? optionID, kind: item["kind"] as? String ?? "")
            }
            let title = (data["toolCall"] as? [String: Any])?["title"] as? String ?? "Agent 请求授权"
            permissions.removeAll { $0.id == requestID && $0.taskID == id }
            let detail = (try? JSONSerialization.data(withJSONObject: data["toolCall"] as? [String: Any] ?? [:], options: [.prettyPrinted, .sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            permissions.append(.init(id: requestID, taskID: id, title: title, detail: detail, options: options))
            mutate(id) { $0.status = .awaitingPermission }
        case "permissionExpired":
            if let requestID = data["requestId"] as? String, permissions.contains(where: { $0.id == requestID && $0.taskID == id }) {
                permissions.removeAll { $0.id == requestID && $0.taskID == id }
                mutate(id) { if $0.status == .awaitingPermission { $0.status = permissions.contains(where: { $0.taskID == id }) ? .awaitingPermission : .running }
                    $0.messages.append(.init(role: "system", text: "授权请求已过期并取消。")) }
            }
        case "state":
            if let raw = data["status"] as? String, let status = WorkbenchTaskStatus(rawValue: raw) {
                mutate(id) { $0.status = status; if !status.active { $0.unread = true } }
                if !status.active { permissions.removeAll { $0.taskID == id }; modelApprovals.removeAll { $0.taskID == id } }
            }
        case "update":
            let kind = data["sessionUpdate"] as? String ?? ""
            if kind == "agent_message_chunk", let content = data["content"] as? [String: Any], let text = content["text"] as? String {
                mutate(id) { task in
                    if task.messages.last?.role == "assistant", let index = task.messages.indices.last {
                        task.messages[index].text = String((task.messages[index].text + text).prefix(500_000))
                    } else { task.messages.append(.init(role: "assistant", text: String(text.prefix(500_000)))) }
                }
            } else if kind == "tool_call" || kind == "tool_call_update" {
                let title = data["title"] as? String ?? "工具执行"
                let status = data["status"] as? String ?? ""
                mutate(id) { $0.messages.append(.init(role: "system", text: "\(title) · \(status)")) }
            }
        default: break
        }
    }
    func mutate(_ id: UUID, _ change: (inout WorkbenchTask) -> Void) {
        guard isStorageReady else { return }
        guard let index = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        let previousSessionID = state.tasks[index].sessionID
        change(&state.tasks[index])
        state.tasks[index].normalizeConversationMetadata(previousSessionID: previousSessionID, isLive: liveTasks.contains(id), pending: pendingConversationTaskIDs.contains(id))
        // Session output is bounded by the runtime; preserve the full accepted event history.
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500)); guard !Task.isCancelled else { return }; self?.persist()
        }
    }
    func fail(_ id: UUID, _ failure: Error) {
        let cleaned = (failure as? WorkbenchFailure)?.taskRetained == false
        if cleaned { liveTasks.remove(id) }
        mutate(id) {
            $0.status = cleaned ? .failed : .unknown
            if cleaned, $0.nativeState == nil { $0.cleanupEvidence = .init(taskID: id, sessionID: $0.sessionID, confirmedAt: Date()) }
            $0.messages.append(.init(role: "system", text: failure.localizedDescription)); $0.unread = true
        }
        permissions.removeAll { $0.taskID == id }; modelApprovals.removeAll { $0.taskID == id }; persist()
    }
    func persist() {
        guard isStorageReady else { return }
        do {
            try store.save(state)
            draftsDirty = false; draftSaveNotice = nil
            draftSaveTask?.cancel(); draftSaveTask = nil
        } catch {
            self.error = "Agent 记录保存失败，请检查存储目录。"
            if draftsDirty { draftSaveNotice = "草稿尚未保存，仅保留于本次运行。请重试保存后再退出。" + Self.storageFailureDescription(error) }
        }
    }
}
