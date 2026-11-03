import Foundation
import SwiftUI
import AgentXAppSDK
import Darwin

struct AgentXFrontendStore {
    let root: URL
    let appID: String
    var exists: Bool {
        let path = root.appendingPathComponent("apps/\(appID)/payload/frontend.json").path
        return FileManager.default.fileExists(atPath: path) || (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }
    private func broker() throws -> AppFileAccess {
        try AppFileAccess(root: root, appID: appID, grants: [
            .init(appID: appID, relativePath: "apps/\(appID)/manifest.json", access: .read),
            .init(appID: appID, relativePath: "apps/\(appID)/payload", access: .read),
            .init(appID: appID, relativePath: "apps/\(appID)/state", access: .readWrite)])
    }
    func load() throws -> (AppFrontendContract, [String: [String: String]]) {
        let access = try broker()
        let manifest = try JSONDecoder().decode(AppManifest.self, from: access.read(relativePath: "apps/\(appID)/manifest.json", maximumBytes: 64 * 1024))
        try manifest.validate(hostAPIMajor: 1)
        guard manifest.id == appID, manifest.kind == "chat", manifest.runtime == "host-text" else { throw AppSDKError.incompatibleHost }
        let contract = try JSONDecoder().decode(AppFrontendContract.self, from: access.read(relativePath: "apps/\(appID)/payload/frontend.json", maximumBytes: 256 * 1024))
        try contract.validate()
        guard Set(manifest.modules) == Set(contract.modules.map(\.id)) else { throw AppSDKError.invalidManifest }
        let values: [String: [String: String]]
        do { values = try JSONDecoder().decode([String: [String: String]].self, from: access.read(relativePath: "apps/\(appID)/state/frontend-values.json", maximumBytes: 2_000_000)) }
        catch AppSDKError.system(ENOENT) { values = [:] }
        return (contract, values)
    }
    func save(_ values: [String: [String: String]]) throws {
        let data = try JSONEncoder().encode(values)
        guard data.count <= 2_000_000 else { throw AppSDKError.invalidManifest }
        try broker().write(data, relativePath: "apps/\(appID)/state/frontend-values.json")
    }
}

@MainActor
struct AgentXFrontendView: View {
    @ObservedObject var controller: AgentXController
    let appID: String
    @State private var contract: AppFrontendContract?
    @State private var values: [String: [String: String]] = [:]
    @State private var selectedModule = ""
    @State private var notice: String?
    @State private var ready = false
    private var store: AgentXFrontendStore { .init(root: controller.repository.root, appID: appID) }
    private var module: AppFrontendContract.Module? { contract?.modules.first { $0.id == selectedModule } }
    private var prompt: String? { try? contract?.prompt(moduleID: selectedModule, values: values[selectedModule] ?? [:]) }
    private func field(_ id: String) -> Binding<String> {
        Binding(get: { values[selectedModule]?[id] ?? "" }, set: { values[selectedModule, default: [:]][id] = $0 })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let contract {
                Text(contract.title).font(.title2.bold())
                Picker("前台模块", selection: $selectedModule) {
                    ForEach(contract.modules, id: \.id) { Text($0.title).tag($0.id) }
                }.pickerStyle(.segmented)
                if let module {
                    ForEach(module.fields, id: \.id) { item in
                        VStack(alignment: .leading) {
                            Text(item.label).font(.headline)
                            if item.multiline { TextEditor(text: field(item.id)).frame(minHeight: 100) }
                            else { TextField(item.label, text: field(item.id)).textFieldStyle(.roundedBorder) }
                        }
                    }
                    Picker("执行实例", selection: $controller.selectedInstanceID) {
                        Text("请选择本应用实例").tag("")
                        ForEach(controller.currentInstances) { Text($0.name).tag($0.id) }
                    }
                    HStack {
                        Button("保存输入") { save() }.disabled(!ready)
                        Button(module.submit.title) {
                            guard let prompt else { return }
                            guard save() else { return }
                            controller.send(prompt, instanceID: controller.selectedInstanceID)
                        }.buttonStyle(.borderedProminent)
                            .disabled(!ready || prompt == nil || !controller.currentInstances.contains { $0.id == controller.selectedInstanceID }
                                      || controller.state.runs.contains { $0.instanceID == controller.selectedInstanceID && !$0.status.terminal })
                    }
                    if let prompt { DisclosureGroup("发送内容预览") { Text(prompt).textSelection(.enabled) } }
                    if let run = controller.state.runs.last(where: { $0.appID == appID && $0.instanceID == controller.selectedInstanceID }) {
                        Text(run.status.label).font(.caption)
                        Text(run.response.isEmpty ? (run.failure ?? "等待结果…") : run.response).textSelection(.enabled)
                        if !run.status.terminal { Button("取消运行") { controller.cancel(run.id) } }
                    }
                }
            }
            if let notice { Text(notice).font(.caption).textSelection(.enabled) }
        }.onAppear(perform: load)
            .onChange(of: appID) { _, _ in load() }
    }
    private func load() {
        ready = false; contract = nil; values = [:]
        do {
            let loaded = try store.load()
            contract = loaded.0; values = loaded.1; selectedModule = loaded.0.modules[0].id
            ready = true; notice = nil
        } catch { notice = "应用前台未能加载，未执行任何应用代码或覆盖输入：\(error.localizedDescription)" }
    }
    @discardableResult private func save() -> Bool {
        do { try store.save(values); notice = "输入已保存在本应用内。"; return true }
        catch { notice = "保存失败：\(error.localizedDescription)"; return false }
    }
}
