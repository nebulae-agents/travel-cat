import Foundation
import Combine

enum AgentXAppCreationStep: Equatable {
    case source, identity, members, requirements, preview
    case installed(appID: String)
}

@MainActor
final class AgentXAppManagementModel: ObservableObject {
    enum Source { case template(AgentXLocalAppPackage.Template), directory(URL), zip(URL) }
    struct Dialog: Identifiable {
        enum Action { case install, uninstall(String), restore(AgentXApplicationBackup) }
        let id = UUID()
        let action: Action
    }
    let controller: AgentXController
    let service: AgentXManagedApplicationService?
    @Published private(set) var dialog: Dialog?
    @Published private(set) var source: Source?
    @Published var appID = "" { didSet { preview = nil; basePreview = nil; memberNames = [:]; memberModels = [:]; inspectedMembers = [] } }
    @Published var applicationName = "" { didSet { preview = nil } }
    @Published var memberNames: [String: String] = [:] { didSet { preview = nil } }
    @Published var memberModels: [String: AgentXConversationModel] = [:] { didSet { preview = nil } }
    @Published private(set) var inspectedMembers: [AgentXInstance] = []
    @Published var creationStep: AgentXAppCreationStep = .source
    @Published var repairingServices = false
    @Published var selection: AgentXConversationModel? { didSet { preview = nil; basePreview = nil; memberNames = [:]; memberModels = [:]; inspectedMembers = [] } }
    private var basePreview: AgentXLocalAppPreview?
    @Published private(set) var preview: AgentXLocalAppPreview?
    @Published private(set) var busy = false
    @Published private(set) var failure: String?
    @Published private(set) var notice: String?
    @Published private(set) var catalog = AgentXApplicationBackupCatalog()
    @Published private(set) var loadingBackups = false
    private var catalogTask: Task<Void, Never>?
    private var catalogGeneration = UUID()
    private var catalogLoaded = false
    private var reloadCatalogWhenFinished = false
    private let backupLoader: @MainActor () async throws -> AgentXApplicationBackupCatalog
    init(controller: AgentXController, service: AgentXManagedApplicationService?,
         backupLoader: (@MainActor () async throws -> AgentXApplicationBackupCatalog)? = nil) {
        self.controller = controller; self.service = service
        self.backupLoader = backupLoader ?? {
            guard let service else { throw AgentXError.unavailable }
            return try await service.backups()
        }
    }
    func close() {
        guard !busy else { return }
        dialog = nil; source = nil; preview = nil; basePreview = nil; failure = nil; repairingServices = false
    }
    private func begin(_ action: Dialog.Action) {
        guard !busy else { return }
        close(); appID = ""; applicationName = ""; selection = nil; notice = nil; creationStep = .source
        dialog = .init(action: action)
    }
    func beginTemplate(_ template: AgentXLocalAppPackage.Template) {
        guard !busy else { return }; begin(.install); source = .template(template); applicationName = template.title
    }
    func beginImport(_ url: URL, directory: Bool) {
        guard !busy else { return }; begin(.install); source = directory ? .directory(url) : .zip(url)
    }
    private func availableService() throws -> AgentXManagedApplicationService {
        guard let service else { throw AgentXError.invalid("应用管理服务未接入，当前无法安装、导出、卸载或恢复。请重新打开完整应用。") }
        return service
    }
    func preparePreview() {
        guard !busy, case .install = dialog?.action else { return }
        preview = nil; failure = nil
        do {
            let service = try availableService()
            if basePreview == nil {
            switch source {
            case .template(let template):
                guard let selection else { throw AgentXError.invalid("请先从模型目录选择已启用的文本模型；没有可用模型时请到模型服务中配置。") }
                preview = try service.previewTemplate(template, appID: appID, providerID: selection.providerID, model: selection.model)
            case .directory(let url): preview = try service.preview(directory: url, appIDOverride: appID.isEmpty ? nil : appID)
            case .zip(let url): preview = try service.preview(zip: url, appIDOverride: appID.isEmpty ? nil : appID)
            case nil: throw AgentXError.invalid("请先选择本地模板或配置包。")
            }
            basePreview = preview
            }
            if let base = basePreview {
                inspectedMembers = base.instances
                preview = try service.editedPreview(base, name: applicationName, memberNames: memberNames, memberModels: memberModels)
            }
        } catch { preview = nil; failure = error.localizedDescription }
    }
    func install() {
        guard !busy, case .install = dialog?.action else { return }
        do {
            guard let preview, preview.canInstall else { throw AgentXError.invalid("请先完成预览并解决全部缺失依赖，再确认安装。") }
            try availableService().install(preview)
            creationStep = .installed(appID: preview.application.id); notice = "已安装，默认停用；启用后可进入前台，安装不会启动任务。"
        } catch { failure = error.localizedDescription; self.preview = nil }
    }
    func beginServiceRepair() { preview = nil; repairingServices = true }
    func endServiceRepair() { repairingServices = false; preview = nil }
    func advanceCreation() {
        switch creationStep {
        case .source: creationStep = .identity
        case .identity: creationStep = .members
        case .members:
            preparePreview()
            if preview != nil { creationStep = .requirements }
        case .requirements:
            preparePreview()
            if preview?.canInstall == true { creationStep = .preview }
        case .preview, .installed: break
        }
    }
    func retreatCreation() {
        switch creationStep {
        case .identity: creationStep = .source
        case .members: creationStep = .identity
        case .requirements: creationStep = .members
        case .preview: creationStep = .requirements
        default: break
        }
    }
    func inspectImportedMembers() {
        if case .template = source { return }
        preparePreview()
    }
    func enableInstalledApplication() async {
        guard !busy, case .installed(let id) = creationStep else { return }
        busy = true; failure = nil
        do {
            try await controller.setApplicationEnabled(id, enabled: true)
            guard controller.selectApplication(id) else { throw AgentXError.invalid(controller.errorMessage ?? "无法进入应用。") }
            controller.openFrontend()
            busy = false; close()
        } catch { busy = false; failure = error.localizedDescription }
    }
    func requestUninstall(_ id: String) { begin(.uninstall(id)) }
    func confirmUninstall() async {
        guard !busy, case .uninstall(let id) = dialog?.action else { return }
        let token = dialog?.id
        busy = true; failure = nil
        cancelBackupRefresh()
        defer { invalidateAndRefreshBackups() }
        do {
            let service = try availableService()
            guard !["blackcat", "workbench"].contains(id) else { throw AgentXError.invalid("内建应用不可卸载。") }
            try await controller.setApplicationEnabled(id, enabled: false)
            // The synchronous service additionally checks the complete runtime barrier.
            _ = try service.uninstall(id)
            busy = false
            guard dialog?.id == token else { return }
            close(); notice = "已验证备份并卸载；审计记录保留，可在下方恢复。"
        } catch {
            busy = false
            if dialog?.id == token { failure = error.localizedDescription }
        }
    }
    func requestRestore(_ receipt: AgentXApplicationBackup) { begin(.restore(receipt)) }
    func confirmRestore() {
        guard !busy, case .restore(let receipt) = dialog?.action else { return }
        cancelBackupRefresh()
        defer { invalidateAndRefreshBackups() }
        do {
            try availableService().restore(receipt)
            close(); notice = "已恢复，应用保持停用。"
        } catch { failure = error.localizedDescription }
    }
    func export(_ id: String, to url: URL) {
        guard !busy else { return }
        do { try availableService().exportApplication(id, to: url); failure = nil; notice = "已导出脱敏配置目录：" + url.path }
        catch { failure = error.localizedDescription }
    }
    func loadBackupsIfNeeded() {
        guard !catalogLoaded else { return }
        if catalogTask?.isCancelled == true {
            reloadCatalogWhenFinished = true
            return
        }
        refreshBackups()
    }
    /// Cancelled work retains its slot until it exits, so rapid refreshes never overlap.
    func cancelBackupRefresh() {
        catalogGeneration = UUID(); catalogLoaded = false
        reloadCatalogWhenFinished = false
        catalogTask?.cancel()
    }
    private func invalidateAndRefreshBackups() {
        cancelBackupRefresh()
        reloadCatalogWhenFinished = true
        if catalogTask == nil { refreshBackups() }
    }
    @discardableResult
    func refreshBackups() -> Task<Void, Never>? {
        guard !busy, service != nil else { return nil }
        if let catalogTask { return catalogTask }
        reloadCatalogWhenFinished = false
        let generation = UUID(); catalogGeneration = generation
        let loader = backupLoader
        loadingBackups = true
        let task = Task { [weak self] in
            let result: Result<AgentXApplicationBackupCatalog, any Error>
            do { result = .success(try await loader()) }
            catch { result = .failure(error) }
            guard let self else { return }
            if self.catalogGeneration == generation, !Task.isCancelled {
                switch result {
                case .success(let catalog): self.catalog = catalog
                case .failure(let error): self.catalog = .init(warnings: [error.localizedDescription])
                }
                self.catalogLoaded = true
            }
            self.catalogTask = nil; self.loadingBackups = false
            if self.reloadCatalogWhenFinished { self.refreshBackups() }
        }
        catalogTask = task
        return task
    }
}
