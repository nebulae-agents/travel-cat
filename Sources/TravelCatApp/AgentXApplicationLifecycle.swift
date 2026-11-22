import Foundation
import Yams
import AgentXAppSDK
import Darwin

struct AgentXLocalAppPreview: Identifiable {
    let id = UUID()
    let application: AgentXApplication
    let sourceDigest: String
    let missingRequirements: [String]
    let includedContent = "包含提示词、应用设定和模型标识；不包含凭据、会话、运行记录或用户记忆。"
    var canInstall: Bool { missingRequirements.isEmpty }
    var instances: [AgentXInstance] { package.instances }
    var definitions: [AgentXDefinition] { package.definitions }
    var frontend: AppFrontendContract? { package.frontend }
    var sourceDescription: String { source?.path ?? application.manifestSource ?? "内建模板" }
    fileprivate let package: AgentXLocalAppPackage
    fileprivate let source: URL?
    fileprivate let isZIP: Bool
}
struct AgentXApplicationBackup: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let appID: String
    let backupURL: URL
    let digest: String
    var legacyDisabledProjection: Bool? = nil
}

struct AgentXApplicationBackupCatalog: Sendable {
    var receipts: [AgentXApplicationBackup] = []
    var warnings: [String] = []
}

/// All mutation calls are synchronous on MainActor. The host must inject a barrier that
/// verifies its complete in-memory snapshot is idle and that this target's external runtime
/// has positively stopped. Never derive the barrier from a view checkbox or manifest claim.
@MainActor
final class AgentXApplicationLifecycle {
    let repository: AgentXRepository
    private let requireIdle: (String) throws -> Void
    private let mutationCheckpoint: (String) throws -> Void
    private let fm = FileManager.default
    init(repository: AgentXRepository, requireIdle: @escaping (String) throws -> Void,
         mutationCheckpoint: @escaping (String) throws -> Void = { _ in }) {
        self.repository = repository; self.requireIdle = requireIdle; self.mutationCheckpoint = mutationCheckpoint
    }
    func previewTemplate(_ template: AgentXLocalAppPackage.Template, appID: String, providerID: String, model: String) throws -> AgentXLocalAppPreview {
        let files = try AgentXLocalAppPackage.template(template, appID: appID, providerID: providerID, model: model).files()
        return try preview(files: files, source: nil, isZIP: false, digest: AgentXPackageFiles.digest(files), override: nil)
    }
    func preview(zip: URL, appIDOverride: String? = nil) throws -> AgentXLocalAppPreview {
        let bytes = try AgentXLocalAppZIP.read(zip)
        return try preview(files: AgentXLocalAppZIP.files(bytes), source: zip, isZIP: true, digest: AgentXPackageFiles.digest(bytes), override: appIDOverride)
    }
    func preview(directory: URL, appIDOverride: String? = nil) throws -> AgentXLocalAppPreview {
        let files = try AgentXPackageFiles.snapshot(directory)
        return try preview(files: files, source: directory, isZIP: false, digest: AgentXPackageFiles.digest(files), override: appIDOverride)
    }
    private func preview(files: [String: Data], source: URL?, isZIP: Bool, digest: String, override: String?) throws -> AgentXLocalAppPreview {
        let original = try AgentXLocalAppPackage.parse(files)
        let package = try original.remapped(to: override ?? original.application.id)
        try package.application.validateManifest()
        let state = try repository.load()
        var missing = package.missingRequirements(in: state)
        if state.apps.contains(where: { $0.id == package.application.id }) { missing.append("应用 ID 已存在，请指定新的 ID。") }
        return .init(application: package.application, sourceDigest: digest, missingRequirements: missing, package: package, source: source, isZIP: isZIP)
    }
    func editedPreview(_ original: AgentXLocalAppPreview, name: String, memberNames: [String: String], memberModels: [String: AgentXConversationModel]) throws -> AgentXLocalAppPreview {
        if let source = original.source {
            let digest = original.isZIP ? AgentXPackageFiles.digest(try AgentXLocalAppZIP.read(source)) : AgentXPackageFiles.digest(try AgentXPackageFiles.snapshot(source))
            guard digest == original.sourceDigest else { throw AgentXError.invalid("来源已更改，请取消后重新导入，避免将成员编辑应用到不同配置。") }
        }
        var package = original.package
        if !name.isEmpty { package.application.name = name }
        for i in package.instances.indices {
            let id = package.instances[i].id
            if let name = memberNames[id] {
                guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AgentXError.invalid("成员名称不能为空。") }
                package.instances[i].name = name
            }
            if let choice = memberModels[id] {
                package.instances[i].providerID = choice.providerID
                package.instances[i].model = choice.model
                package.instances[i].credentialProfile = nil
                package.instances[i].conversationModel = nil
                if var experience = package.application.experience {
                    if var draft = experience.draft { draft.memberOverrides.removeAll { $0.instanceID == id }; experience.draft = draft }
                    for j in experience.revisions.indices { experience.revisions[j].configuration.memberOverrides.removeAll { $0.instanceID == id } }
                    package.application.experience = experience
                }
            }
        }
        try package.application.validateManifest()
        let state = try repository.load()
        var missing = package.missingRequirements(in: state)
        if state.apps.contains(where: { $0.id == package.application.id }) { missing.append("应用 ID 已存在，请指定新的 ID。") }
        return .init(application: package.application, sourceDigest: original.sourceDigest, missingRequirements: missing, package: package, source: original.source, isZIP: original.isZIP)
    }
    func install(_ preview: AgentXLocalAppPreview) throws {
        let id = preview.application.id
        try AgentXPilot.requireDesktopOwnership(id, at: repository.root)
        try requireIdle(id)
        if let source = preview.source {
            let digest = preview.isZIP ? AgentXPackageFiles.digest(try AgentXLocalAppZIP.read(source)) : AgentXPackageFiles.digest(try AgentXPackageFiles.snapshot(source))
            guard digest == preview.sourceDigest else { throw AgentXError.invalid("来源已更改，请重新预览并确认。") }
        }
        var state = try repository.load()
        let package = preview.package
        guard package.missingRequirements(in: state).isEmpty else { throw AgentXError.invalid("请先配置并启用所需服务与模型，或移除不支持的能力。") }
        guard !state.apps.contains(where: { $0.id == id }),
              Set(state.instances.map(\.id)).isDisjoint(with: package.instances.map(\.id)),
              Set(state.definitions.map(\.id)).isDisjoint(with: package.definitions.map(\.id)) else { throw AgentXError.invalid("应用、实例或定义 ID 已存在，未覆盖任何文件。") }
        state.apps.append(package.application); state.instances += package.instances; state.definitions += package.definitions
        try repository.validate(state)
        var appFiles = try package.files()
        appFiles = appFiles.filter { !$0.key.hasPrefix("definitions/") }
        var additions = ["apps/" + id: appFiles]
        for definition in package.definitions {
            additions["manager/templates/assistant/" + definition.id] = ["definition.yaml": Data(try YAMLEncoder().encode(definition).utf8), "agent.md": Data(definition.prompt.utf8)]
        }
        let initialDirectories = ["state", "artifacts", "shared", "runs", "memory"] + package.instances.flatMap { instance in
            ["config", "memory", "workspace", "logs"].map { "instances/\(instance.id)/" + $0 }
        }
        try publish(additions: additions, removing: nil, state: state, directories: ["apps/" + id: initialDirectories])
    }
    func exportApplication(_ appID: String, to destination: URL) throws {
        let state = try repository.load()
        guard var app = state.apps.first(where: { $0.id == appID }), app.kind == .chat else { throw AgentXError.invalid("只能导出内建文本对话配置。") }
        let members = state.instances.filter { $0.appID == appID }
        for member in members {
            guard let pinned = member.definitionRevision else { continue }
            guard let definition = state.definitions.first(where: { $0.id == member.definitionID }),
                  try definition.publishedDocument(revision: pinned).executionPrompt() == definition.publishedDocument().executionPrompt() else {
                throw AgentXError.invalid("实例「\(member.name)」固定了不同的定义版本；导出会改变提示词，已停止。请先审阅实例定义版本。")
            }
        }
        app.enabled = false
        // Export only the active configuration, not draft/revision histories or shared memory.
        if var experience = app.experience?.published?.configuration ?? app.experience?.draft {
            experience.sharedMemory = ""
            app.experience = .init(draft: experience, revisions: [.init(number: 1, configuration: experience, publishedAt: Date(timeIntervalSince1970: 0))], publishedRevision: 1)
        } else { app.experience = nil }
        if let workflow = app.workflow?.published?.definition ?? app.workflow?.draft {
            app.workflow = .init(draft: workflow, revisions: [.init(number: 1, definition: workflow, publishedAt: Date(timeIntervalSince1970: 0))], publishedRevision: 1)
        } else { app.workflow = nil }
        let instances = members.map { instance in
            AgentXInstance(id: instance.id, name: instance.name, appID: appID, definitionID: instance.definitionID, providerID: instance.providerID, model: instance.model)
        }
        let definitions = try Set(instances.map(\.definitionID)).sorted().map { id -> AgentXDefinition in
            guard let definition = state.definitions.first(where: { $0.id == id }) else { throw AgentXError.corrupt }
            let effectivePrompt = try definition.publishedDocument().executionPrompt()
            // A flattened body may itself begin with YAML fences. An empty outer header
            // makes the next parse remove only our wrapper, not the user's literal body.
            let portablePrompt = "---\n---\n" + effectivePrompt
            guard try AgentXDefinitionDocument(source: portablePrompt).executionPrompt() == effectivePrompt else { throw AgentXError.corrupt }
            return .init(id: id, name: definition.name, prompt: portablePrompt)
        }
        app.manifest = app.manifest?.filter { ["author", "source", "requires", "permissions", "ui"].contains($0.key) }
        var package = AgentXLocalAppPackage(application: app, instances: instances, definitions: definitions)
        let frontendPath = "apps/\(appID)/payload/frontend.json"
        let frontendURL = try AgentXPackageFiles.safeURL(frontendPath, root: repository.root)
        if fm.fileExists(atPath: frontendURL.path) {
            let manifestURL = try AgentXPackageFiles.safeURL("apps/\(appID)/manifest.json", root: repository.root)
            let pair = try AgentXLocalAppPackage.frontend(in: ["payload/frontend.json": AgentXLocalAppZIP.read(frontendURL), "manifest.json": AgentXLocalAppZIP.read(manifestURL)], application: app)
            package.frontend = pair?.0; package.frontendVersion = pair?.1 ?? "1"
        }
        let files = try package.files()
        _ = try AgentXLocalAppPackage.parse(files)
        guard !fm.fileExists(atPath: destination.path) else { throw AgentXError.invalid("导出目标已存在，未覆盖。") }
        let rootPath = repository.root.resolvingSymlinksInPath().standardizedFileURL.path
        let destinationPath = destination.resolvingSymlinksInPath().standardizedFileURL.path
        guard destination.isFileURL, destinationPath != rootPath, !destinationPath.hasPrefix(rootPath + "/") else { throw AgentXError.invalid("请将可移植配置包导出到应用根目录之外。") }
        let parent = destination.deletingLastPathComponent()
        _ = try AgentXPackageFiles.safeURL(destination.lastPathComponent, root: parent)
        let stage = parent.appendingPathComponent(".agentx-export-" + UUID().uuidString)
        defer { try? fm.removeItem(at: stage) }
        try AgentXPackageFiles.write(files, to: stage)
        try fm.moveItem(at: stage, to: destination)
    }
    func uninstall(_ appID: String) throws -> AgentXApplicationBackup {
        try AgentXPackageFiles.validateID(appID)
        guard !["blackcat", "workbench"].contains(appID) else { throw AgentXError.invalid("内建应用不可卸载。") }
        try AgentXPilot.requireDesktopOwnership(appID, at: repository.root)
        try requireIdle(appID)
        var state = try repository.load()
        guard let app = state.apps.first(where: { $0.id == appID }), !app.enabled,
              !state.runs.contains(where: { $0.appID == appID && !$0.status.terminal }) else { throw AgentXError.invalid("请先停用应用并确认运行已结束。") }
        let path = "apps/" + appID, url = try AgentXPackageFiles.safeURL(path, root: repository.root)
        let snapshot = try AgentXPackageFiles.fullSnapshot(url)
        guard let manifestBytes = snapshot.files["app.yaml"],
              let rawManifest = try Yams.load(yaml: String(decoding: manifestBytes, as: UTF8.self), .default, repository.yamlConstructor) as? [String: Any] else { throw AgentXError.corrupt }
        let legacyDisabledProjection = rawManifest["enabled"] == nil
        let savedManifest = try YAMLDecoder().decode(AgentXApplication.self, from: String(decoding: manifestBytes, as: UTF8.self))
        guard savedManifest.id == appID, !savedManifest.enabled || legacyDisabledProjection else { throw AgentXError.invalid("应用启用状态在备份前发生变化，未卸载。") }
        let backupID = UUID().uuidString.lowercased()
        let backup = try AgentXPackageFiles.safeURL("backups/local-app-" + backupID, root: repository.root)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.copyItem(at: url, to: backup.appendingPathComponent("app"))
        let digest = snapshot.digest
        guard try AgentXPackageFiles.fullSnapshot(backup.appendingPathComponent("app")).digest == digest else { throw AgentXError.corrupt }
        let receipt = AgentXApplicationBackup(id: backupID, appID: appID, backupURL: backup, digest: digest, legacyDisabledProjection: legacyDisabledProjection ? true : nil)
        try JSONEncoder().encode(receipt).write(to: backup.appendingPathComponent("receipt.json"), options: .atomic)
        try mutationCheckpoint("backupVerified")
        guard try AgentXPackageFiles.fullSnapshot(url).digest == digest else { throw AgentXError.invalid("应用数据在备份期间发生变化，未卸载。") }
        state.apps.removeAll { $0.id == appID }; state.instances.removeAll { $0.appID == appID }; state.runs.removeAll { $0.appID == appID }
        if state.currentAppID == appID { state.currentAppID = state.apps.first(where: \.enabled)?.id }
        if state.singleAppID == appID { state.singleAppID = nil }
        try publish(additions: [:], removing: path, state: state)
        return receipt
    }
    func backups() throws -> AgentXApplicationBackupCatalog {
        try AgentXApplicationBackupReader(root: repository.root).read()
    }
    func restore(_ receipt: AgentXApplicationBackup) throws {
        try AgentXPackageFiles.validateID(receipt.appID)
        guard !["blackcat", "workbench"].contains(receipt.appID), UUID(uuidString: receipt.id) != nil else { throw AgentXError.unsafePath }
        try AgentXPilot.requireDesktopOwnership(receipt.appID, at: repository.root)
        try requireIdle(receipt.appID)
        let expected = try AgentXPackageFiles.safeURL("backups/local-app-" + receipt.id, root: repository.root)
        guard expected.standardizedFileURL.path == receipt.backupURL.standardizedFileURL.path,
              try JSONDecoder().decode(AgentXApplicationBackup.self, from: AgentXLocalAppZIP.read(AgentXPackageFiles.safeURL("backups/local-app-" + receipt.id + "/receipt.json", root: repository.root))) == receipt else { throw AgentXError.unsafePath }
        let snapshot = try AgentXPackageFiles.fullSnapshot(expected.appendingPathComponent("app"))
        let files = snapshot.files
        guard snapshot.digest == receipt.digest, let manifest = files["app.yaml"] else { throw AgentXError.corrupt }
        var app = try YAMLDecoder().decode(AgentXApplication.self, from: String(decoding: manifest, as: UTF8.self))
        if receipt.legacyDisabledProjection == true {
            guard let raw = try Yams.load(yaml: String(decoding: manifest, as: UTF8.self), .default, repository.yamlConstructor) as? [String: Any], raw["enabled"] == nil else { throw AgentXError.corrupt }
            // Preserve the legacy app.yaml bytes; the restored root projection remains disabled.
            app.enabled = false
        }
        guard app.id == receipt.appID, !app.enabled else { throw AgentXError.corrupt }
        var state = try repository.load()
        guard !state.apps.contains(where: { $0.id == app.id }) else { throw AgentXError.invalid("应用已存在，不能覆盖恢复。") }
        state.apps.append(app)
        for (path, bytes) in files where path.hasPrefix("instances/") && path.hasSuffix("/config/agent.yaml") {
            state.instances.append(try YAMLDecoder().decode(AgentXInstance.self, from: String(decoding: bytes, as: UTF8.self)))
        }
        for (path, bytes) in files where path.hasPrefix("runs/") && path.hasSuffix(".json") { state.runs.append(try JSONDecoder().decode(AgentXRun.self, from: bytes)) }
        try repository.validate(state)
        try publish(additions: ["apps/" + app.id: files], removing: nil, state: state, directories: ["apps/" + app.id: snapshot.directories])
    }
    private func publish(additions: [String: [String: Data]], removing: String?, state: AgentXState, directories: [String: [String]] = [:]) throws {
        let root = repository.root
        let settingsURL = try AgentXPackageFiles.safeURL("agentx.yaml", root: root)
        let before = try Data(contentsOf: settingsURL)
        guard var settings = try Yams.load(yaml: String(decoding: before, as: UTF8.self), .default, repository.yamlConstructor) as? [String: Any] else { throw AgentXError.corrupt }
        settings["apps_enabled"] = state.apps.filter(\.enabled).map(\.id)
        settings["current_app"] = state.currentAppID
        settings["single_app"] = state.singleAppID
        settings["mode"] = state.singleAppID == nil ? "full" : "single"
        let after = Data(try Yams.dump(object: settings, sortKeys: true).utf8)
        let stageName = ".agentx-local-" + UUID().uuidString.lowercased()
        let stage = try AgentXPackageFiles.safeURL(stageName, root: root)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var journalWritten = false
        defer { if !journalWritten { try? fm.removeItem(at: stage) } }
        for (index, path) in additions.keys.sorted().enumerated() {
            let target = try AgentXPackageFiles.safeURL(path, root: root)
            guard !fm.fileExists(atPath: target.path) else { throw AgentXError.invalid("目标已存在，未覆盖。") }
            let stagedRoot = stage.appendingPathComponent("new-\(index)")
            try AgentXPackageFiles.write(additions[path]!, to: stagedRoot)
            for directory in directories[path] ?? [] {
                try fm.createDirectory(at: AgentXPackageFiles.safeURL(directory, root: stagedRoot), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
        }
        let journal = try AgentXLocalAppTransaction.prepare(root: root, stage: stageName, additions: additions.keys.sorted(), removing: removing, settings: before, expectedSettings: after)
        let journalURL = try AgentXPackageFiles.safeURL(AgentXLocalAppTransaction.filename, root: root)
        try journal.write(root: root)
        journalWritten = true
        do {
            if let removing { try fm.moveItem(at: AgentXPackageFiles.safeURL(removing, root: root), to: stage.appendingPathComponent("removed")) }
            for (index, path) in additions.keys.sorted().enumerated() {
                let target = try AgentXPackageFiles.safeURL(path, root: root)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: stage.appendingPathComponent("new-\(index)"), to: target)
            }
            try mutationCheckpoint("publishedBeforeSettings")
            try after.write(to: settingsURL, options: .atomic)
            try fm.removeItem(at: journalURL) // commit point: recovery rolls back until this removal
            try? fm.removeItem(at: stage)
        } catch { try AgentXLocalAppTransaction.recover(root: root); throw error }
    }
}

/// Repository.load calls recovery before enumerating apps, so a process interruption never
/// exposes a half-installed app or resurrects the controller's stale pre-mutation snapshot.
struct AgentXLocalAppTransaction: Codable {
    static let filename = ".agentx-local-operation.json"
    var formatVersion = 1
    let stage: String
    let additions: [String]
    let removing: String?
    let settings: Data
    var rootPath = ""
    var expectedSettingsDigest = ""
    var ownership: [String: DirectoryIdentity] = [:]

    struct DirectoryIdentity: Codable, Equatable {
        let device: Int32
        let inode: UInt64
        let digest: String
        static func capture(_ url: URL) throws -> Self {
            let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard descriptor >= 0 else { throw AgentXError.unsafePath }
            defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw AgentXError.unsafePath }
            return .init(device: info.st_dev, inode: info.st_ino, digest: try AgentXPackageFiles.fullSnapshot(url).digest)
        }
        func matches(_ url: URL) throws -> Bool { try Self.capture(url) == self }
    }
    static func canonicalRoot(_ root: URL) -> String { root.resolvingSymlinksInPath().standardizedFileURL.path }
    static func prepare(root: URL, stage: String, additions: [String], removing: String?, settings: Data, expectedSettings: Data) throws -> Self {
        guard settings.count <= 1024 * 1024 else { throw AgentXError.corrupt }
        var journal = Self(stage: stage, additions: additions, removing: removing, settings: settings)
        journal.rootPath = canonicalRoot(root)
        journal.expectedSettingsDigest = AgentXPackageFiles.digest(expectedSettings)
        for (index, path) in additions.enumerated() {
            journal.ownership[path] = try .capture(AgentXPackageFiles.safeURL(stage + "/new-\(index)", root: root))
        }
        if let removing { journal.ownership[removing] = try .capture(AgentXPackageFiles.safeURL(removing, root: root)) }
        return journal
    }
    func write(root: URL) throws {
        let bytes = try JSONEncoder().encode(self)
        // The independently stored stage record proves this is a prepared local operation,
        // not a legacy or stray file whose missing new-N paths imply deletion authority.
        try bytes.write(to: AgentXPackageFiles.safeURL(stage + "/transaction.json", root: root), options: .atomic)
        try bytes.write(to: AgentXPackageFiles.safeURL(Self.filename, root: root), options: .atomic)
    }
    static func recover(root: URL) throws {
        let fm = FileManager.default, journalURL = try AgentXPackageFiles.safeURL(filename, root: root)
        guard fm.fileExists(atPath: journalURL.path) else { return }
        let bytes = try AgentXLocalAppZIP.read(journalURL)
        let journal = try JSONDecoder().decode(Self.self, from: bytes)
        guard journal.formatVersion == 1, journal.rootPath == canonicalRoot(root), journal.settings.count <= 1024 * 1024,
              journal.additions.count <= 33, Set(journal.additions).count == journal.additions.count,
              journal.stage.hasPrefix(".agentx-local-"), UUID(uuidString: String(journal.stage.dropFirst(".agentx-local-".count))) != nil else { throw AgentXError.unsafePath }
        func validateTarget(_ path: String, removal: Bool = false) throws {
            try AgentXPackageFiles.validatePath(path)
            let parts = path.split(separator: "/").map(String.init)
            if parts.count == 2 && parts[0] == "apps" {
                try AgentXPackageFiles.validateID(parts[1]); guard !["blackcat", "workbench"].contains(parts[1]) else { throw AgentXError.unsafePath }
            } else if !removal && parts.count == 4 && parts.prefix(3) == ["manager", "templates", "assistant"] { try AgentXPackageFiles.validateID(parts[3]) }
            else { throw AgentXError.unsafePath }
            _ = try AgentXPackageFiles.safeURL(path, root: root)
        }
        for path in journal.additions { try validateTarget(path) }
        if let removing = journal.removing {
            try validateTarget(removing, removal: true)
            guard !journal.additions.contains(removing) else { throw AgentXError.corrupt }
        }
        let targets = Set(journal.additions + (journal.removing.map { [$0] } ?? []))
        if let pilot = try AgentXPilot.configured(at: root), !targets.isDisjoint(with: pilot.appIDs.map { "apps/" + $0 }) {
            throw AgentXError.invalid("应用包恢复涉及试点目录，请先离线处理副本。")
        }
        guard Set(journal.ownership.keys) == targets else { throw AgentXError.corrupt }
        let stage = try AgentXPackageFiles.safeURL(journal.stage, root: root)
        var stageIsDirectory: ObjCBool = false
        guard fm.fileExists(atPath: stage.path, isDirectory: &stageIsDirectory), stageIsDirectory.boolValue,
              try AgentXLocalAppZIP.read(AgentXPackageFiles.safeURL(journal.stage + "/transaction.json", root: root)) == bytes else { throw AgentXError.corrupt }
        let settingsURL = try AgentXPackageFiles.safeURL("agentx.yaml", root: root)
        let currentSettings = try AgentXLocalAppZIP.read(settingsURL)
        guard currentSettings == journal.settings || AgentXPackageFiles.digest(currentSettings) == journal.expectedSettingsDigest else {
            throw AgentXError.invalid("恢复期间发现根设置被另行修改，未覆盖任何文件。")
        }
        var published: [URL] = []
        // Resolve and prove ownership of EVERY endpoint before the first deletion or move.
        for (index, path) in journal.additions.enumerated() {
            let target = try AgentXPackageFiles.safeURL(path, root: root)
            let staged = try AgentXPackageFiles.safeURL(journal.stage + "/new-\(index)", root: root)
            let targetExists = fm.fileExists(atPath: target.path), stagedExists = fm.fileExists(atPath: staged.path)
            guard !(targetExists && stagedExists), let identity = journal.ownership[path] else { throw AgentXError.corrupt }
            if stagedExists { guard try identity.matches(staged) else { throw AgentXError.corrupt } }
            if targetExists {
                guard try identity.matches(target) else { throw AgentXError.invalid("事务目标不属于本次安装，未删除。") }
                published.append(target)
            }
        }
        var restoration: (URL, URL)?
        if let removing = journal.removing {
            let target = try AgentXPackageFiles.safeURL(removing, root: root)
            let removed = try AgentXPackageFiles.safeURL(journal.stage + "/removed", root: root)
            let targetExists = fm.fileExists(atPath: target.path), removedExists = fm.fileExists(atPath: removed.path)
            guard targetExists != removedExists, let identity = journal.ownership[removing],
                  try identity.matches(removedExists ? removed : target) else { throw AgentXError.corrupt }
            if removedExists { restoration = (removed, target) }
        }
        for target in published { try fm.removeItem(at: target) }
        if let (removed, target) = restoration { try fm.moveItem(at: removed, to: target) }
        try journal.settings.write(to: settingsURL, options: .atomic)
        try fm.removeItem(at: journalURL)
        try? fm.removeItem(at: stage)
    }
}
