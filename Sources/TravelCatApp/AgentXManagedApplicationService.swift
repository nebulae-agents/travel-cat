import Foundation

/// The management UI receives this service, never an unchecked package lifecycle.
/// Package writes and snapshot reload are one synchronous MainActor operation.
@MainActor
final class AgentXManagedApplicationService {
    private let controller: AgentXController
    private let lifecycle: AgentXApplicationLifecycle
    init(controller: AgentXController, requireIdle: @escaping (String) throws -> Void = { _ in throw AgentXError.unavailable }) {
        self.controller = controller
        lifecycle = AgentXApplicationLifecycle(repository: controller.repository, requireIdle: requireIdle)
    }
    func previewTemplate(_ template: AgentXLocalAppPackage.Template, appID: String, providerID: String, model: String) throws -> AgentXLocalAppPreview {
        try lifecycle.previewTemplate(template, appID: appID, providerID: providerID, model: model)
    }
    func preview(zip: URL, appIDOverride: String? = nil) throws -> AgentXLocalAppPreview {
        try lifecycle.preview(zip: zip, appIDOverride: appIDOverride)
    }
    func preview(directory: URL, appIDOverride: String? = nil) throws -> AgentXLocalAppPreview {
        try lifecycle.preview(directory: directory, appIDOverride: appIDOverride)
    }
    func editedPreview(_ preview: AgentXLocalAppPreview, name: String, memberNames: [String: String], memberModels: [String: AgentXConversationModel]) throws -> AgentXLocalAppPreview {
        try lifecycle.editedPreview(preview, name: name, memberNames: memberNames, memberModels: memberModels)
    }
    func install(_ preview: AgentXLocalAppPreview) throws {
        try lifecycle.install(preview)
        try controller.reloadApplications()
    }
    func exportApplication(_ id: String, to destination: URL) throws {
        try lifecycle.exportApplication(id, to: destination)
    }
    func uninstall(_ id: String) throws -> AgentXApplicationBackup {
        let receipt = try lifecycle.uninstall(id)
        try controller.reloadApplications()
        return receipt
    }
    func backups() async throws -> AgentXApplicationBackupCatalog {
        let reader = AgentXApplicationBackupReader(root: controller.repository.root)
        return try await reader.load()
    }
    func restore(_ receipt: AgentXApplicationBackup) throws {
        try lifecycle.restore(receipt)
        try controller.reloadApplications()
    }
}
