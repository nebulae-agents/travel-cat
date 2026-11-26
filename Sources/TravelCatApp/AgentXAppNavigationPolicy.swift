import Foundation

enum AgentXShellOverlay: String, Identifiable { case switcher, search; var id: Self { self } }

struct AgentXModule: Identifiable, Equatable {
    let id: String
    let title: String
    let page: AgentXPage
    let available: Bool
}

enum AgentXAppNavigationPolicy {
    /// Platform sheets outlive current-app selection changes caused by disable/uninstall.
    static func contentScope(page: AgentXPage, appID: String) -> String {
        page.isPlatform ? "platform" : "application:" + appID
    }
    static func initialSwitcherSelection(in apps: [AgentXApplication], currentID: String) -> String? {
        apps.first(where: { $0.id == currentID })?.id ?? apps.first?.id
    }
    static func modules(for app: AgentXApplication) -> [AgentXModule] {
        let defaults = app.kind == .blackcat ? ["chat", "history", "inbox"] : ["chat", "runs", "members", "artifacts"]
        return (app.declaredModules.isEmpty ? defaults : app.declaredModules).map { module($0) }
    }
    static func module(_ id: String) -> AgentXModule {
        let title: String; let page: AgentXPage; var available = true
        switch id {
        case "chat": title = "对话"; page = .chat
        case "history": title = "历史"; page = .runs
        case "runs": title = "运行"; page = .runs
        case "inbox": title = "收件箱"; page = .inbox
        case "members": title = "成员"; page = .members
        case "artifacts": title = "制品"; page = .appFiles
        case "settings": title = "应用设置"; page = .appSettings
        case "stage": title = "舞台"; page = .module
        case "world-state": title = "世界资料"; page = .module
        case "npc-memory": title = "人物记忆"; page = .module
        case "director-intervention": title = "导演干预"; page = .module
        default: title = id; page = .module; available = false
        }
        return .init(id: id, title: title, page: page, available: available)
    }
    static func pending(app: AgentXApplication?, unread: Int, travel: Bool, workbench: Int) -> Int {
        guard let app else { return 0 }
        return unread + (app.kind == .blackcat && travel ? 1 : 0) + (app.kind == .workbench ? workbench : 0)
    }
    static func stopAction(enabled: Bool, state: AgentXApplicationStopState?) -> (title: String, enabled: Bool, targetEnabled: Bool) {
        switch state {
        case .stopping: return ("正在停止…", false, false)
        case .unverified: return ("重试停止", true, false)
        default: return (enabled ? "停用" : "启用", true, !enabled)
        }
    }
}

struct AgentXAppSearchResult: Identifiable, Equatable {
    enum Target: Equatable { case module(String), member(String), run(String) }
    let appID: String
    let title: String
    let detail: String
    let target: Target
    var id: String { "\(appID):\(target)" }
}

extension AgentXPage {
    var isPlatform: Bool { [.platformOverview, .apps, .providers, .definitions, .instances, .backups, .governance, .settings].contains(self) }
}

@MainActor
extension AgentXController {
    var usesUsageAssistant: Bool { currentApp != nil && !page.isPlatform && appArea == .frontend }
    func displayedCharacterMemory(instanceID: String) -> String? {
        guard let instance = currentInstances.first(where: { $0.id == instanceID }),
              let definition = state.definitions.first(where: { $0.id == instance.definitionID }),
              let document = try? definition.publishedDocument(revision: instance.definitionRevision),
              let profile = try? AgentXCharacterProfile.load(from: document) else { return nil }
        return profile.text(for: .memory)
    }
    var usesDeclarativeFrontend: Bool {
        currentApp.map { AgentXFrontendStore(root: repository.root, appID: $0.id).exists } ?? false
    }
    var currentModules: [AgentXModule] {
        guard let app = currentApp else { return [] }
        return AgentXAppNavigationPolicy.modules(for: app).map { module in
            usesDeclarativeFrontend ? .init(id: module.id, title: module.title, page: .chat, available: true) : module
        }
    }
    var currentModuleID: String {
        guard let app = currentApp else { return "" }
        let selected = frontendSession(appID: app.id).selectedModule
        return currentModules.contains(where: { $0.id == selected }) ? selected : (currentModules.first?.id ?? "")
    }
    func openBackstage() {
        guard currentApp != nil else { page = .apps; return }
        appArea = .backstage
        navigate(to: backstagePages[selectedAppID] ?? .members)
    }
    func openFrontend() {
        if !page.isPlatform, appArea == .backstage { backstagePages[selectedAppID] = page }

        guard currentApp != nil else { page = .apps; return }
        restoreFrontendLocation()
    }
    private func restoreFrontendLocation() {
        guard let app = currentApp else { page = .apps; return }
        if let saved = frontendLocations[app.id], saved.moduleID == nil {
            appArea = .frontend; appAreas[app.id] = .frontend; page = saved.page
            return
        }
        selectModule(currentModuleID)
    }
    func navigate(to destination: AgentXPage) {
        if destination.isPlatform {
            if !page.isPlatform, !selectedAppID.isEmpty { appReturnPages[selectedAppID] = page }
            assistantPresented = false
        } else {
            guard currentApp != nil else { page = .apps; return }
            appArea = [.overview, .chat, .inbox].contains(destination) ? .frontend : .backstage
            if appArea == .backstage { backstagePages[selectedAppID] = destination }
            else { frontendLocations[selectedAppID] = .init(area: .frontend, page: destination, moduleID: nil) }
            appAreas[selectedAppID] = appArea
        }
        page = destination
    }
    func validateRestoredApplicationLocation() {
        guard let app = currentApp else { page = .apps; return }
        guard appArea == .frontend else { return }
        if frontendLocations[app.id] != nil || appReturnPages[app.id] == nil {
            restoreFrontendLocation()
        }
    }
    func returnToApplication() {
        guard currentApp != nil else { page = .apps; return }
        if let saved = appReturnPages[selectedAppID] { page = saved; appArea = appAreas[selectedAppID] ?? .frontend; validateRestoredApplicationLocation() } else { openFrontend() }
    }
    func selectModule(_ id: String) {
        guard let app = currentApp, let module = currentModules.first(where: { $0.id == id }) else { return }
        frontendSession(appID: app.id).selectedModule = id
        frontendLocations[app.id] = .init(area: .frontend, page: module.page, moduleID: id)
        appArea = .frontend
        appAreas[app.id] = .frontend
        page = module.page
    }
    func applicationSearch(_ query: String) -> [AgentXAppSearchResult] {
        guard let app = currentApp else { return [] }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var results = currentModules.map { AgentXAppSearchResult(appID: app.id, title: $0.title, detail: "模块 · \($0.id)", target: .module($0.id)) }
        results += currentInstances.map { .init(appID: app.id, title: $0.name, detail: "成员 · \($0.model)", target: .member($0.id)) }
        results += currentRuns.reversed().map { .init(appID: app.id, title: $0.prompt, detail: "运行 · \($0.status.label)", target: .run($0.id)) }
        return results.filter { needle.isEmpty || ($0.title + " " + $0.detail).localizedCaseInsensitiveContains(needle) }
    }
    @discardableResult func openSearchResult(_ result: AgentXAppSearchResult) -> Bool {
        guard result.appID == currentApp?.id, applicationSearch("").contains(where: { $0.id == result.id }) else { return false }
        switch result.target {
        case .module(let id): selectModule(id)
        case .member(let id): selectedInstanceID = id; navigate(to: .members)
        case .run(let id):
            guard let run = currentRuns.first(where: { $0.id == id }) else { return false }
            selectedInstanceID = run.instanceID
            navigate(to: .runs)
        }
        shellOverlay = nil
        return true
    }
    func selectApplicationShortcut(_ index: Int) {
        guard enabledApps.indices.contains(index) else { return }
        if selectApplication(enabledApps[index].id) {
            if page.isPlatform { returnToApplication() }
            shellOverlay = nil
        }
    }
}
