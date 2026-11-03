import Foundation
import Combine

@MainActor
final class AgentXController: ObservableObject {
    typealias Responder = @MainActor (AgentXProvider, String, String?, [AgentXMessage]) async throws -> String
    @Published private(set) var state = AgentXState()
    @Published var page: AgentXPage = .overview
    @Published var selectedAppID = "blackcat"
    @Published var selectedInstanceID = ""
    @Published var errorMessage: String?
    @Published private(set) var isLoaded = false
    @Published var drafts: [String: String] = [:]
    @Published var singleMode = false
    let hostStorage: AgentXHostStorage?
    let repository: AgentXRepository
    private let credentials: any TravelServiceCredentialStoring
    private let catalog: AgentXProviderCatalog
    private var profileResolver: AgentXCredentialProfiles?
    private var resolvedProfiles: [AgentXCredentialProfile] = []
    private let respond: Responder
    private var tasks: [String: Task<Void, Never>] = [:]
    private let runAudit: AgentXRunAudit
    private var runAuditTickets: [String: AgentXRunAudit.Ticket] = [:]
    var didChange: (() -> Void)?

    init(repository: AgentXRepository, credentials: any TravelServiceCredentialStoring, respond: Responder? = nil, catalog: AgentXProviderCatalog = .init(), hostStorage: AgentXHostStorage? = nil) {
        self.hostStorage = hostStorage
        self.repository = repository
        self.runAudit = AgentXRunAudit(root: repository.root, credentials: credentials)
        self.credentials = credentials
        self.catalog = catalog
        let client = AgentXChatClient(catalog: catalog)
        self.respond = respond ?? { provider, model, secret, messages in
            try await client.respond(provider: provider, model: model, secret: secret, messages: messages)
        }
        do {
            state = try repository.load()
            for index in state.runs.indices where !state.runs[index].status.terminal {
                state.runs[index].status = .failed
                state.runs[index].failure = "上次运行被中断，请检查结果后重新发送。"
                state.runs[index].endedAt = Date()
                state.runs[index].isRead = false
            }
            try repository.save(state)
            isLoaded = true
            if let app = state.singleAppID { selectedAppID = app; singleMode = true; page = .chat }
        } catch { errorMessage = error.localizedDescription }
    }

    var currentApp: AgentXApplication? { state.apps.first { $0.id == selectedAppID } }
    var currentInstances: [AgentXInstance] { state.instances.filter { $0.appID == selectedAppID } }
    var currentInstance: AgentXInstance? { currentInstances.first { $0.id == selectedInstanceID } ?? currentInstances.first }

    private func commit(_ next: AgentXState) throws {
        guard isLoaded else { throw AgentXError.unavailable }
        try repository.save(next)
        state = next
        didChange?()
    }
    private func required(_ text: String, label: String) throws -> String {
        let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw AgentXError.invalid("请填写\(label)。") }
        return result
    }

    func addProvider(name: String, address: String, models: String, secret: String,
                     serviceProtocol: AgentXServiceProtocol = .openAICompatible, credentialProfile: String? = nil,
                     modelSelection: AgentXModelSelection? = nil) throws {
        let provider = AgentXProvider(id: UUID().uuidString.lowercased(), name: try required(name, label: "服务名称"),
            baseURL: try required(address, label: "API 地址"),
            models: Array(NSOrderedSet(array: models.components(separatedBy: CharacterSet(charactersIn: ",，\n")).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })) as? [String] ?? [], serviceProtocol: serviceProtocol,
            credentialProfile: credentialProfile?.isEmpty == false ? credentialProfile : nil, modelSelection: modelSelection)
        var next = state
        next.providers.append(provider)
        guard isLoaded else { throw AgentXError.unavailable }
        try repository.validate(next)
        if !secret.isEmpty { try credentials.save(secret, id: provider.credentialID) }
        do { try commit(next) }
        catch { if !secret.isEmpty { try? credentials.save(nil, id: provider.credentialID) }; throw error }
    }
    func setProviderEnabled(_ id: String, enabled: Bool) throws {
        var next = state
        guard let index = next.providers.firstIndex(where: { $0.id == id }) else { return }
        next.providers[index].enabled = enabled
        try commit(next)
    }
    func updateProvider(id: String, name: String, address: String, models: String, secret: String,
                        serviceProtocol: AgentXServiceProtocol? = nil, credentialProfile: String? = nil,
                        modelSelection: AgentXModelSelection? = nil) throws {
        guard isLoaded else { throw AgentXError.unavailable }
        var next = state
        guard let index = next.providers.firstIndex(where: { $0.id == id }) else { throw AgentXError.invalid("模型服务不存在。") }
        next.providers[index].name = try required(name, label: "服务名称")
        next.providers[index].baseURL = try required(address, label: "API 地址")
        next.providers[index].models = Array(NSOrderedSet(array: models.components(separatedBy: CharacterSet(charactersIn: ",，\n")).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })) as? [String] ?? []
        if let serviceProtocol { next.providers[index].serviceProtocol = serviceProtocol }
        if let credentialProfile { next.providers[index].credentialProfile = credentialProfile.isEmpty ? nil : credentialProfile }
        if let modelSelection { next.providers[index].modelSelection = modelSelection }
        else if let previous = next.providers[index].modelSelection {
            let ids = next.providers[index].models
            next.providers[index].modelSelection = .init(models: ids.map { id in previous.models.first { $0.id == id } ?? .init(id: id, enabled: true) }, defaults: previous.defaults.filter { ids.contains($0.value) })
        }
        try repository.validate(next)
        let key = next.providers[index].credentialID
        let previous = secret.isEmpty ? nil : try credentials.read(id: key)
        if !secret.isEmpty { try credentials.save(secret, id: key) }
        do { try commit(next) }
        catch { if !secret.isEmpty { try? credentials.save(previous, id: key) }; throw error }
    }
    func addCredentialProfile(name: String, secrets: [String]) throws {
        guard isLoaded else { throw AgentXError.unavailable }
        let name = try required(name, label: "凭据配置名称")
        guard !(state.credentialProfiles ?? []).contains(where: { $0.name.lowercased() == name.lowercased() }),
              !secrets.isEmpty, secrets.allSatisfy({ !$0.isEmpty && !$0.contains(where: { $0.isNewline || $0 == "\0" }) }) else {
            throw AgentXCredentialProfileError.invalidProfile
        }
        let references = secrets.map { _ in "agentx.profile.\(UUID().uuidString.lowercased())" }
        var next = state
        next.credentialProfiles = (next.credentialProfiles ?? []) + [.init(name: name, keyReferences: references)]
        try repository.validate(next)
        var written: [String] = []
        do {
            for (reference, secret) in zip(references, secrets) {
                try credentials.save(secret, id: reference)
                written.append(reference)
            }
            try commit(next)
        } catch {
            for reference in written { try? credentials.save(nil, id: reference) }
            throw error
        }
    }

    private func secret(for provider: AgentXProvider) throws -> String? {
        if let profile = provider.credentialProfile { return try profileSecret(profile) }
        return try credentials.read(id: provider.credentialID)
    }
    private func profileSecret(_ name: String) throws -> String {
        let profiles = state.credentialProfiles ?? []
        if profileResolver == nil || resolvedProfiles != profiles {
            profileResolver = .init(profiles: profiles, store: credentials)
            resolvedProfiles = profiles
        }
        guard let profileResolver else { throw AgentXCredentialProfileError.invalidProfile }
        return try profileResolver.nextSecret(profile: name)
    }

    /// Discovery is explicit and returns a draft; it does not silently replace saved models.
    func discoverModels(address: String, serviceProtocol: AgentXServiceProtocol, secret: String,
                        providerID: String? = nil, credentialProfile: String? = nil) async throws -> [AgentXCatalogModel] {
        guard isLoaded else { throw AgentXError.unavailable }
        let key: String?
        if let credentialProfile, !credentialProfile.isEmpty { key = try profileSecret(credentialProfile) }
        else if !secret.isEmpty { key = secret }
        else if let providerID, let provider = state.providers.first(where: { $0.id == providerID }) {
            key = try credentials.read(id: provider.credentialID)
        } else { key = nil }
        return try await catalog.fetchModels(baseURL: address, protocol: serviceProtocol, secret: key)
    }

    func addDefinition(name: String, prompt: String) throws {
        var next = state
        next.definitions.append(.init(id: UUID().uuidString.lowercased(), name: try required(name, label: "定义名称"), prompt: try required(prompt, label: "系统提示词")))
        try commit(next)
    }
    @discardableResult
    func addDefinitionDraft(name: String, document: AgentXDefinitionDocument) throws -> String {
        try document.validate()
        var next = state
        let id = UUID().uuidString.lowercased()
        next.definitions.append(.init(id: id, name: try required(name, label: "定义名称"), prompt: "", draft: document, revisions: []))
        try commit(next)
        return id
    }
    func saveDefinitionDraft(id: String, name: String, document: AgentXDefinitionDocument) throws {
        try document.validate()
        var next = state
        guard let index = next.definitions.firstIndex(where: { $0.id == id }) else { throw AgentXDefinitionError.invalidDocument }
        // Preserve the legacy published prompt before introducing a separate draft.
        if next.definitions[index].revisions == nil {
            let published = try next.definitions[index].publishedDocument()
            next.definitions[index].revisions = [.init(number: 1, document: published, publishedAt: nil)]
            next.definitions[index].publishedRevision = 1
        }
        next.definitions[index].name = try required(name, label: "定义名称")
        next.definitions[index].draft = document
        try commit(next)
    }
    func publishDefinition(id: String) throws {
        var next = state
        guard let index = next.definitions.firstIndex(where: { $0.id == id }), let draft = next.definitions[index].draft else { throw AgentXDefinitionError.invalidDocument }
        let prompt = try draft.executionPrompt()
        var revisions = next.definitions[index].revisions ?? []
        let number = (revisions.map(\.number).max() ?? 0) + 1
        revisions.append(.init(number: number, document: draft, publishedAt: Date()))
        next.definitions[index].revisions = revisions
        next.definitions[index].publishedRevision = number
        next.definitions[index].prompt = prompt
        try commit(next)
    }
    func restoreDefinitionDraft(id: String, revision: Int) throws {
        guard let definition = state.definitions.first(where: { $0.id == id }) else { throw AgentXDefinitionError.invalidDocument }
        let document = try definition.publishedDocument(revision: revision)
        try saveDefinitionDraft(id: id, name: definition.name, document: document)
    }
    func ensureWorkbenchApp() throws {
        guard !state.apps.contains(where: { $0.id == "workbench" }) else { return }
        var next = state
        next.apps.append(.init(id: "workbench", name: "Agent 工作台", kind: .workbench))
        try commit(next)
    }
    func addApp(name: String) throws {
        var next = state
        let app = AgentXApplication(id: UUID().uuidString.lowercased(), name: try required(name, label: "应用名称"), kind: .chat)
        next.apps.append(app)
        try commit(next)
        selectedAppID = app.id
    }
    func addInstance(name: String, appID: String, definitionID: String, providerID: String, model: String,
                     definitionRevision: Int? = nil, variables: [String: String]? = nil, credentialProfile: String? = nil) throws {
        var next = state
        guard state.providers.contains(where: { $0.id == providerID && $0.enabled && $0.enabledModels.contains(model) }) else { throw AgentXCatalogError.invalidSelection }
        guard let definition = state.definitions.first(where: { $0.id == definitionID }) else { throw AgentXDefinitionError.unpublished }
        _ = try definition.publishedDocument(revision: definitionRevision)
        let instance = AgentXInstance(id: UUID().uuidString.lowercased(), name: try required(name, label: "实例名称"), appID: appID, definitionID: definitionID, providerID: providerID, model: model,
            definitionRevision: definitionRevision, variables: variables, credentialProfile: credentialProfile?.isEmpty == false ? credentialProfile : nil)
        next.instances.append(instance)
        try commit(next)
        selectedInstanceID = instance.id
        selectedAppID = appID
    }
    func updateInstance(id: String, name: String, appID: String, definitionID: String, providerID: String, model: String,
                        definitionRevision: Int? = nil, variables: [String: String]? = nil, credentialProfile: String? = nil) throws {
        guard !state.runs.contains(where: { $0.instanceID == id && !$0.status.terminal }) else { throw AgentXDefinitionError.runningInstance }
        var next = state
        guard let index = next.instances.firstIndex(where: { $0.id == id }), next.instances[index].appID == appID else { throw AgentXError.invalid("实例只能保留在原应用中。") }
        guard let definition = state.definitions.first(where: { $0.id == definitionID }),
              state.providers.contains(where: { $0.id == providerID && $0.enabled && $0.enabledModels.contains(model) }) else { throw AgentXCatalogError.invalidSelection }
        _ = try definition.publishedDocument(revision: definitionRevision)
        next.instances[index] = .init(id: id, name: try required(name, label: "实例名称"), appID: appID, definitionID: definitionID,
            providerID: providerID, model: model, definitionRevision: definitionRevision, variables: variables,
            credentialProfile: credentialProfile?.isEmpty == false ? credentialProfile : nil)
        try commit(next)
    }
    func setBlackCatEnabled(_ enabled: Bool) throws {
        var next = state
        next.blackCatEnabled = enabled
        try commit(next)
    }
    func setSingleApp(_ id: String?) throws {
        var next = state
        next.singleAppID = id
        try commit(next)
        singleMode = id != nil
        if let id { selectedAppID = id; page = .chat }
    }
    func markAllRead() throws {
        var next = state
        for index in next.runs.indices where next.runs[index].status.terminal { next.runs[index].isRead = true }
        try commit(next)
    }
    func markRead(_ id: String) throws {
        var next = state
        guard let index = next.runs.firstIndex(where: { $0.id == id }), next.runs[index].status.terminal else { return }
        next.runs[index].isRead = true
        try commit(next)
    }
    func openApp(_ id: String) { selectedAppID = id; selectedInstanceID = ""; page = .chat }
    func openFromDock(travelPending: Bool = false) {
        if state.unreadCount > 0 || travelPending { page = .inbox }
        else if currentApp != nil { page = .chat }
        else { page = .overview }
    }

    func send(_ prompt: String, instanceID: String) {
        do {
            let text = try required(prompt, label: "消息")
            guard text.utf8.count <= 100_000 else { throw AgentXError.invalid("消息过长，请控制在 100 KB 以内。") }
            guard let instance = state.instances.first(where: { $0.id == instanceID }),
                  let provider = state.providers.first(where: { $0.id == instance.providerID && $0.enabled }),
                  let definition = state.definitions.first(where: { $0.id == instance.definitionID }) else { throw AgentXError.invalid("请先为实例配置已启用的模型服务和定义。") }
            guard state.apps.first(where: { $0.id == instance.appID })?.canRunHostText == true else { throw AgentXError.invalid("此应用运行框架未接入宿主文本执行器，未发送请求。") }
            guard !state.runs.contains(where: { $0.instanceID == instanceID && !$0.status.terminal }) else { throw AgentXError.invalid("此实例仍在运行，请等待或取消。") }
            guard provider.enabledModels.contains(instance.model) else { throw AgentXCatalogError.invalidSelection }
            let secret = try instance.credentialProfile.map { try profileSecret($0) } ?? self.secret(for: provider)
            let document = try definition.publishedDocument(revision: instance.definitionRevision)
            var systemPrompt = try document.executionPrompt()
            for (key, value) in (instance.variables ?? [:]).sorted(by: { $0.key < $1.key }) { systemPrompt = systemPrompt.replacingOccurrences(of: "{{" + key + "}}", with: value) }
            var messages = [AgentXMessage(role: "system", content: systemPrompt)]
            for run in state.runs.filter({ $0.instanceID == instanceID && $0.status == .completed }).suffix(20) {
                messages.append(.init(role: "user", content: run.prompt))
                messages.append(.init(role: "assistant", content: run.response))
            }
            messages.append(.init(role: "user", content: text))
            let run = AgentXRun(id: UUID().uuidString.lowercased(), appID: instance.appID, instanceID: instanceID, prompt: text, status: .running)
            var next = state
            next.runs.append(run)
            let ticket: AgentXRunAudit.Ticket
            do { ticket = try runAudit.begin(run: run, providerID: provider.id, model: instance.model, requestBytes: messages.reduce(0) { $0 + $1.content.utf8.count }) }
            catch { throw AgentXError.invalid("审计记录无法安全保存，未发送模型请求。") }
            do { try commit(next) }
            catch { try? runAudit.finish(ticket, status: .failed, responseBytes: 0); throw error }
            runAuditTickets[run.id] = ticket
            drafts[instanceID] = ""
            tasks[run.id] = Task { [weak self, respond] in
                do {
                    try Task.checkCancellation()
                    let answer = try await respond(provider, instance.model, secret, messages)
                    try Task.checkCancellation()
                    self?.finish(run.id, status: .completed, response: answer)
                } catch {
                    let cancelled = Task.isCancelled || error is CancellationError
                    let safeMessage = (error as? OpenAICompatibleTravelError)?.localizedDescription ?? (error as? AgentXCatalogError)?.localizedDescription ?? "模型请求失败，请检查服务配置和网络。"
                    self?.finish(run.id, status: cancelled ? .cancelled : .failed, failure: cancelled ? nil : safeMessage)
                }
                self?.tasks[run.id] = nil
            }
        } catch { errorMessage = error.localizedDescription }
    }
    private func finish(_ id: String, status: AgentXRunStatus, response: String = "", failure: String? = nil) {
        guard let index = state.runs.firstIndex(where: { $0.id == id }) else { return }
        var next = state
        next.runs[index].status = status
        next.runs[index].response = response
        next.runs[index].failure = failure
        next.runs[index].endedAt = Date()
        if let ticket = runAuditTickets.removeValue(forKey: id) {
            do { try runAudit.finish(ticket, status: status, responseBytes: response.utf8.count) }
            catch { next.runs[index].auditFailure = "运行结果已保留，但结束审计未能落盘；审计链不完整。" }
        } else { next.runs[index].auditFailure = "缺少运行开始审计凭据；未确认完整审计。" }
        if let warning = next.runs[index].auditFailure { errorMessage = warning }
        do { try commit(next) }
        catch {
            // Keep the response available in memory even if disk becomes unavailable.
            state = next
            errorMessage = "运行已结束，但记录保存失败。请保留窗口并复制结果。"
            didChange?()
        }
    }
    func cancel(_ id: String) {
        guard let task = tasks[id] else { return }
        task.cancel()
        var next = state
        if let index = next.runs.firstIndex(where: { $0.id == id }) {
            next.runs[index].status = .cancelling
            if let ticket = runAuditTickets[id] {
                do { try runAudit.cancelRequested(ticket) }
                catch {
                    next.runs[index].auditFailure = "取消已请求，但取消审计未能落盘。"
                    errorMessage = next.runs[index].auditFailure
                }
            }
        }
        do { try commit(next) } catch { errorMessage = error.localizedDescription }
    }
    func cancelAll() { for id in Array(tasks.keys) { cancel(id) } }
    func waitForRuns() async { for task in Array(tasks.values) { await task.value } }
}
