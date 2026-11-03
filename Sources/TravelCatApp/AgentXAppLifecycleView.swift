import AppKit
import SwiftUI
import AgentXAppSDK

/// Queue-only management UI. Actual file changes occur at the verified next-start safety point.
@MainActor
struct AgentXAppLifecycleView: View {
    let apps: [AgentXApplication]
    let coordinator: AgentXOfflineAppLifecycle
    var migrationPending: () -> Bool = { false }
    @State private var selectedID = ""
    @State private var pending: String?
    @State private var message: String?
    @State private var manifest: AppManifest?
    @State private var rollbackReceipt: AppUpgradeReceipt?
    @State private var version = ""
    @State private var schema = ""
    @State private var runtime = "native"
    @State private var modules = ""
    @State private var showRegistration = false

    private var selectedApp: AgentXApplication? { apps.first { $0.id == selectedID } }
    private var blocked: Bool { pending != nil || migrationPending() }
    var body: some View {
        AgentXCard {
            Text("独立应用与数据版本").font(.headline)
            Text("应用操作将在正常退出并重新启动后执行。导入代码包不会运行包内代码；数据 schema 改变需宿主另行提供可信迁移。")
                .font(.caption).foregroundStyle(AgentXTheme.muted)
            if migrationPending() {
                Text("根目录迁移已排队；请先完成或取消迁移，再登记应用操作。")
                    .foregroundStyle(.orange)
            }
            Picker("应用", selection: $selectedID) {
                ForEach(apps) { app in Text(app.name).tag(app.id) }
            }.disabled(pending != nil)
            if let manifest {
                Text("版本 \(manifest.version) · 数据 schema \(manifest.dataSchemaVersion) · 宿主 API \(manifest.hostAPIMajor)")
                    .font(.caption).textSelection(.enabled)
            } else if selectedApp != nil {
                Text("尚未登记独立版本基线。代码包导出与升级需先填写该应用的实际版本和数据 schema。")
                    .font(.caption).foregroundStyle(AgentXTheme.muted)
                Button("登记版本基线…") { showRegistration = true }.disabled(blocked)
            }
            HStack {
                Button("导入代码包…") { choosePackage(forUpgrade: false) }
                Button("升级此应用…") { choosePackage(forUpgrade: true) }.disabled(manifest == nil)
                Button("回滚上次升级") {
                    if let rollbackReceipt { enqueue(.rollback(rollbackReceipt)) }
                }.disabled(rollbackReceipt == nil)
            }.disabled(blocked)
            HStack {
                Button("导出代码包…") { chooseDestination(fullBackup: false) }.disabled(manifest == nil)
                Button("导出完整状态备份…") { chooseDestination(fullBackup: true) }.disabled(selectedApp == nil)
            }.disabled(blocked)
            Text("代码包仅含版本声明和 payload；完整状态备份包含此应用的用户数据，请保存到可信位置。")
                .font(.caption).foregroundStyle(AgentXTheme.muted)
            if let pending {
                HStack {
                    Text("等待下次启动：\(pending)")
                    Spacer()
                    Button("取消待执行操作") {
                        do { try coordinator.cancel(); message = "已取消，应用文件未改变。"; refresh() }
                        catch { message = error.localizedDescription }
                    }
                }
            }
            if let message { Text(message).font(.caption).textSelection(.enabled) }
        }
        .onAppear { if selectedID.isEmpty { selectedID = apps.first?.id ?? "" }; refresh() }
        .onChange(of: selectedID) { _, _ in refresh() }
        .sheet(isPresented: $showRegistration) { registration }
    }

    private var registration: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("登记 \(selectedApp?.name ?? "应用") 的实际版本").font(.headline)
            Text("这是版本基线声明，不会生成可执行模块。数据 schema 必须与当前应用数据一致。")
                .font(.caption).foregroundStyle(.secondary)
            TextField("应用版本，例如 2.3.0", text: $version)
            TextField("当前数据 schema（正整数）", text: $schema)
            TextField("运行框架", text: $runtime)
            TextField("模块名称（逗号分隔，可留空）", text: $modules)
            HStack {
                Button("取消") { showRegistration = false }
                Spacer()
                Button("登记下次启动执行") {
                    guard let app = selectedApp, let schemaNumber = Int(schema), schemaNumber > 0 else { return }
                    let baseline = AppManifest(id: app.id, name: app.name, version: version.trimmingCharacters(in: .whitespacesAndNewlines),
                        dataSchemaVersion: schemaNumber, hostAPIMajor: 1, kind: app.kind.rawValue,
                        runtime: runtime.trimmingCharacters(in: .whitespacesAndNewlines),
                        modules: modules.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
                    enqueue(.register(appID: app.id, manifest: baseline))
                    if pending != nil { showRegistration = false }
                }
                .disabled(version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (Int(schema) ?? 0) <= 0 || runtime.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || blocked)
            }
        }.padding(24).frame(width: 490)
    }

    private func choosePackage(forUpgrade: Bool) {
        let panel = NSOpenPanel()
        panel.title = forUpgrade ? "选择应用更新代码包目录" : "选择应用代码包目录"
        panel.prompt = "登记操作"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        enqueue(forUpgrade ? .upgrade(appID: selectedID, source: url.path) : .importPackage(source: url.path))
    }
    private func chooseDestination(fullBackup: Bool) {
        guard let app = selectedApp else { return }
        let panel = NSSavePanel()
        panel.title = fullBackup ? "导出完整应用状态备份" : "导出应用代码包"
        panel.prompt = "登记导出"
        panel.nameFieldStringValue = "\(app.id)-\(fullBackup ? "full-state-backup" : "code-package")-\(UUID().uuidString.prefix(8))"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        enqueue(fullBackup ? .backupApplication(appID: app.id, destination: url.path) : .exportPackage(appID: app.id, destination: url.path))
    }
    private func enqueue(_ operation: AgentXOfflineAppLifecycle.Operation) {
        guard !migrationPending() else { message = "请先完成或取消根目录迁移。"; return }
        do {
            try coordinator.request(operation)
            message = "已登记。请正常退出 AgentX Manager，再重新启动；当前应用文件尚未改变。"
            refresh(preserveMessage: true)
        } catch { message = error.localizedDescription }
    }
    private func refresh(preserveMessage: Bool = false) {
        do {
            pending = try coordinator.pendingTitle()
            if !preserveMessage, let result = try coordinator.latestResult() { message = result.message }
            if !selectedID.isEmpty {
                let host = try AgentXAppLifecycleHost(root: coordinator.root, hostAPIMajor: 1, writersHaveStopped: { false })
                manifest = try host.inspectApplication(appID: selectedID)
                let receipt = try coordinator.latestRollbackReceipt(appID: selectedID)
                rollbackReceipt = receipt?.installedManifest == manifest ? receipt : nil
            }
        } catch { message = error.localizedDescription; rollbackReceipt = nil }
    }
}
