import Foundation
import OSLog

struct AgentWorkbenchCredentialStores: Sendable {
    let content: any AsyncTravelServiceCredentialStoring
    let audit: any AsyncTravelServiceCredentialStoring
    let models: any AsyncTravelServiceCredentialStoring
    static func system() -> Self {
        .init(content: AsyncKeychainTravelServiceCredentialStore(service: "com.nebulae.travelcat.agent-content"),
              audit: AsyncKeychainTravelServiceCredentialStore(service: "com.nebulae.travelcat.agent-audit"),
              models: AsyncKeychainTravelServiceCredentialStore(service: "com.nebulae.travelcat.agent-models"))
    }
}

enum AgentWorkbenchStorageStatus: Equatable {
    case loading, ready, blocked(String)
    var message: String? { if case let .blocked(message) = self { return message }; return nil }
}

@MainActor
extension AgentWorkbenchModel {
    func requireStorageReady() throws {
        guard isStorageReady else { throw WorkbenchFailure("安全存储尚未就绪，请完成钥匙串授权后重试。") }
    }

    /// The task is owned by the model, so closing a view cannot create a second opener.
    func loadStorage() async {
        guard let credentialStores, storageTask == nil, !hasShutdown, !isStorageReady else { return }
        let generation = UUID()
        storageGeneration = generation
        loadFailed = true; storageStatus = .loading
        error = nil; auditError = nil
        let task = Task { [weak self] in
            guard let self else { return }
            await self.openStorage(credentialStores, generation: generation)
        }
        storageTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if storageGeneration == generation { storageTask = nil }
    }

    func retryStorage() {
        guard storageTask == nil, !hasShutdown else { return }
        Task { [weak self] in await self?.loadStorage() }
    }

    private func checkStorageAttempt(_ generation: UUID) throws {
        try Task.checkCancellation()
        guard !hasShutdown, storageGeneration == generation else { throw CancellationError() }
    }

    private func openStorage(_ credentials: AgentWorkbenchCredentialStores, generation: UUID) async {
        var contentOpened = false
        do {
            let opened = try await WorkbenchStore.encrypted(root: store.root, credentials: credentials.content)
            try checkStorageAttempt(generation)
            let snapshot = try opened.load()
            // Keep recovered content visible in memory even if audit authorization is denied.
            store = opened; state = snapshot; contentOpened = true
            let audit = try await AgentAuditStore.open(root: store.root.appendingPathComponent("audit-v1"), credentials: credentials.audit)
            try checkStorageAttempt(generation)
            auditStore = audit
            loadFailed = false; storageStatus = .ready
            error = nil; auditError = nil
            if preferredInstanceID == nil, let first = state.instances.first { openInstance(first.id) }
            applyScheduledRetention()
        } catch {
            guard !hasShutdown, storageGeneration == generation else { return }
            loadFailed = true
            let reason = error is CancellationError ? "安全存储加载已取消，请点击重试。" : Self.storageFailureDescription(error)
            let message = (contentOpened ? "审计存储无法打开，受控调用已阻止。\n" : "Agent 数据读取失败，原文件未覆盖。\n") + reason
            storageStatus = .blocked(message)
            if contentOpened { auditError = message }
            Logger(subsystem: "com.nebulae.travelcat", category: "AgentStorage").error("Storage bootstrap failed: \(reason, privacy: .public)")
        }
    }

    func readModelCredential(id: String) async throws -> String? {
        try requireStorageReady()
        if let credentialStores { return try await credentialStores.models.read(id: id) }
        guard let synchronousCredentials else { throw WorkbenchFailure("模型凭据不可用。") }
        return try synchronousCredentials.read(id: id)
    }

    private func writeModelCredential(_ value: String?, id: String) async throws {
        try Task.checkCancellation()
        try requireStorageReady()
        if let credentialStores { try await credentialStores.models.save(value, id: id) }
        else if let synchronousCredentials { try synchronousCredentials.save(value, id: id) }
        else { throw WorkbenchFailure("模型凭据不可用。") }
        try Task.checkCancellation()
        try requireStorageReady()
    }

    func snapshotSaving(_ instance: WorkbenchInstance) throws -> WorkbenchSnapshot {
        try requireStorageReady()
        if let previous = state.instances.first(where: { $0.id == instance.id }), let native = previous.native {
            guard instance.native?.executable == native.executable, instance.native?.workspace == native.workspace else {
                throw WorkbenchFailure("已保存的原生实例须保留程序和目录，以便恢复原会话；请新建实例。")
            }
        }
        try instance.validate(); if instance.native == nil { try instance.provider.validate() }
        var next = state
        if let index = next.instances.firstIndex(where: { $0.id == instance.id }) { next.instances[index] = instance }
        else { next.instances.append(instance) }
        return next
    }

    func saveInstance(instance: WorkbenchInstance, newKey: String) async throws {
        try requireStorageReady()
        guard !savingInstance else { throw WorkbenchFailure("正在保存 Agent，请稍候。") }
        savingInstance = true; defer { savingInstance = false }
        _ = try snapshotSaving(instance)
        if instance.native == nil && !newKey.isEmpty { try await writeModelCredential(newKey, id: instance.provider.credentialID) }
        try Task.checkCancellation()
        // Use current state after authorization, preserving events received while it was pending.
        let next = try snapshotSaving(instance)
        try store.save(next); state = next
    }

    func removeInstance(instanceID: UUID) async {
        do {
            try requireStorageReady()
            guard !savingInstance else { throw WorkbenchFailure("正在保存 Agent，请稍候。") }
            savingInstance = true; defer { savingInstance = false }
            guard let instance = state.instances.first(where: { $0.id == instanceID }) else { return }
            guard !state.tasks.contains(where: { $0.instanceID == instanceID && liveTasks.contains($0.id) }) else { throw WorkbenchFailure("请先结束该实例的会话。") }
            guard draft(for: .new(instanceID)).isEmpty else { throw WorkbenchFailure("该 Agent 还有未发送草稿，请先保留或清空草稿再删除。") }
            guard instance.native == nil || !state.tasks.contains(where: { $0.instanceID == instanceID }) else {
                throw WorkbenchFailure("此原生实例仍有会话记录，需保留配置以便恢复和控制后台任务。")
            }
            var next = state; next.instances.removeAll { $0.id == instanceID }
            try store.save(next); state = next
            if !state.instances.contains(where: { $0.id == preferredInstanceID }) {
                if let remaining = state.instances.first { openInstance(remaining.id) }
                else { preferredInstanceID = nil; selectedTaskID = nil }
            }
            if instance.native == nil { try await writeModelCredential(nil, id: instance.provider.credentialID) }
        } catch { self.error = error.localizedDescription }
    }
}
