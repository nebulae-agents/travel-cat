import AppKit
import SwiftUI

@MainActor
struct NativeAgentSetupView: View {
    @ObservedObject var model: AgentWorkbenchModel
    @Environment(\.dismiss) private var dismiss
    @State var instance: WorkbenchInstance
    let didSave: (UUID) -> Void
    @State private var checkedConfiguration: NativeRuntimeConfiguration?
    @State private var error: String?
    @State private var working = false
    @State private var connectionCheckFailed = false
    @State private var step = 0
    @State private var advanced = false

    static func newInstance() -> WorkbenchInstance {
        var instance = WorkbenchInstance(name: "本机 Codex", image: "", command: [])
        instance.symbol = "terminal"
        instance.native = .init(executable: detectedExecutable(), workspace: "", model: "")
        return instance
    }

    private static func detectedExecutable() -> String {
        let environmentPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let paths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] + environmentPaths
        let candidates = paths.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0).appendingPathComponent("codex").path }
            + ["/Applications/Codex.app/Contents/Resources/codex"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? ""
    }

    private var configuration: NativeRuntimeConfiguration {
        instance.native ?? .init(executable: "", workspace: "", model: "")
    }
    private var sameConnection: Bool {
        checkedConfiguration?.executable == configuration.executable && checkedConfiguration?.workspace == configuration.workspace
    }
    private var connection: NativeConnectionInfo? { sameConnection && !connectionCheckFailed ? model.nativeConnections[instance.id] : nil }
    private var busy: Bool { working || model.nativeBusy.contains(instance.id) }
    private var ready: Bool {
        guard let connection, connection.authenticated,
              connection.models.contains(where: { $0.model == configuration.model }),
              !instance.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return (try? configuration.validate()) != nil
    }
    private var hasHistory: Bool { model.state.tasks.contains { $0.instanceID == instance.id } }
    private var isSavedInstance: Bool { model.state.instances.contains { $0.id == instance.id } }
    private var configurationLocked: Bool {
        busy || hasHistory || isSavedInstance || checkedConfiguration != nil || model.nativeLoginIDs[instance.id] != nil
    }
    private var configurationNotice: String {
        if hasHistory || isSavedInstance { return "此实例的程序与目录保持固定。需要更换时请新建实例。" }
        if checkedConfiguration != nil { return "连接已建立，程序与目录保持固定。需要更换时，请取消此表单后重新添加实例。" }
        return "请选择用于本实例的目录，不能选择整个个人目录或磁盘根目录。"
    }
    private func field(_ keyPath: WritableKeyPath<NativeRuntimeConfiguration, String>) -> Binding<String> {
        Binding(get: { configuration[keyPath: keyPath] }, set: { value in
            var next = configuration; next[keyPath: keyPath] = value; instance.native = next
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isSavedInstance ? instance.name : "添加本机 Codex").font(.title3.weight(.semibold))
            Text("本机 Codex · 官方 ChatGPT 账号").font(.caption).foregroundStyle(WorkbenchTheme.muted)
            if !isSavedInstance {
                HStack(spacing: 10) {
                    ForEach(Array(["基本配置", "连接与登录", "模型与确认"].enumerated()), id: \.offset) { index, title in
                        Text("\(index + 1)  \(title)").font(.caption).foregroundStyle(step == index ? WorkbenchTheme.accent : WorkbenchTheme.muted)
                        if index < 2 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(WorkbenchTheme.line) }
                    }
                }.padding(.vertical, 3)
            }
            Form {
                if isSavedInstance || step == 0 {
                    Section("常用配置") {
                        TextField("名称", text: $instance.name)
                        if configurationLocked {
                            LabeledContent("工作目录") { Text(URL(fileURLWithPath: configuration.workspace).lastPathComponent).textSelection(.enabled) }
                            Text(configurationNotice).font(.caption).foregroundStyle(WorkbenchTheme.muted)
                        } else {
                            HStack {
                                Text(configuration.workspace.isEmpty ? "请选择工作目录" : URL(fileURLWithPath: configuration.workspace).lastPathComponent)
                                    .font(.callout).lineLimit(1).truncationMode(.middle)
                                Spacer(); Button("选择工作目录…") { chooseWorkspace() }
                            }
                            Text("只授权所选工作目录，不能选择整个个人目录或磁盘根目录。").font(.caption).foregroundStyle(WorkbenchTheme.muted)
                        }
                    }
                }
                if isSavedInstance || step == 1 {
                    Section("连接与账号") {
                        HStack {
                            Label(connection.map { $0.authenticated ? "官方账号已登录" : "尚未登录" } ?? "等待检查连接", systemImage: connection?.authenticated == true ? "checkmark.circle" : "person.crop.circle")
                            Spacer()
                            Button(busy ? "检查中…" : "检查连接") { connect() }.disabled(busy)
                            if busy { ProgressView().controlSize(.small) }
                        }
                        if let info = connection {
                            if !info.authenticated {
                                Button("使用 ChatGPT 官方登录") { login() }.disabled(busy || model.nativeLoginIDs[instance.id] != nil)
                            }
                            if let notice = info.notice { Text(verbatim: notice).font(.caption).foregroundStyle(WorkbenchTheme.muted) }
                            if model.nativeLoginIDs[instance.id] != nil {
                                Text("在浏览器完成登录后，再检查连接。").font(.caption).foregroundStyle(WorkbenchTheme.muted)
                                Button("取消本次登录") { Task { await model.cancelNativeLogin(instanceID: instance.id) } }.disabled(busy)
                            }
                        } else { Text("检查程序、官方账号状态和可用模型。").font(.caption).foregroundStyle(WorkbenchTheme.muted) }
                    }
                }
                if isSavedInstance || step == 2 {
                    Section("默认模型") {
                        if let info = connection, !info.models.isEmpty {
                            Picker("可用模型", selection: field(\.model)) {
                                Text("请选择模型").tag("")
                                ForEach(info.models) { choice in Text(choice.name + (choice.isDefault ? "（默认）" : "")).tag(choice.model) }
                            }.disabled(busy)
                        } else { Text("检查连接并登录后，选择官方返回的模型。").font(.caption).foregroundStyle(WorkbenchTheme.muted) }
                        if !isSavedInstance {
                            Text("发送任务会将所选目录中的任务上下文提交给官方账号模型，工具操作仍按规则审批。").font(.caption).foregroundStyle(WorkbenchTheme.muted)
                        }
                    }
                }
                Section {
                    DisclosureGroup("高级与诊断", isExpanded: $advanced) {
                        if configurationLocked {
                            Text(verbatim: "程序：\(configuration.executable)").font(.caption.monospaced()).textSelection(.enabled)
                        } else {
                            HStack { TextField("Codex 可执行文件", text: field(\.executable)); Button("选择程序…") { chooseExecutable() } }
                        }
                        if !configuration.workspace.isEmpty { Text(verbatim: "工作目录：\(configuration.workspace)").font(.caption).textSelection(.enabled) }
                        if let info = connection {
                            Text(verbatim: info.version).font(.caption).textSelection(.enabled)
                            Text("已确认能力：" + info.capabilities.filter { $0.value }.map(\.key).sorted().joined(separator: "、")).font(.caption).textSelection(.enabled)
                        }
                        Text("不会读取或复制现有 CLI 登录凭据。工作台加密自身记录，Codex 独立管理登录和会话；关闭窗口或断开连接不会自动停止任务。").font(.caption).foregroundStyle(WorkbenchTheme.muted)
                        Text("任务上下文提交由官方账号处理，不经过 Docker 模型网关。").font(.caption).foregroundStyle(WorkbenchTheme.muted)
                    }
                }
            }.formStyle(.grouped).scrollContentBackground(.hidden)
            if let error { Text(verbatim: error).font(.caption).foregroundStyle(CottageTheme.terracotta).textSelection(.enabled) }
            HStack {
                Button("取消") {
                    Task { if model.nativeLoginIDs[instance.id] != nil { await model.cancelNativeLogin(instanceID: instance.id) }; dismiss() }
                }.disabled(busy).keyboardShortcut(.cancelAction)
                Spacer()
                if !isSavedInstance && step > 0 { Button("上一步") { step -= 1 }.disabled(busy) }
                if !isSavedInstance && step < 2 {
                    Button("下一步") { step += 1 }.buttonStyle(.borderedProminent)
                        .disabled(busy || (step == 0 ? instance.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (try? configuration.validate(requireModel: false)) == nil : connection?.authenticated != true))
                } else {
                    Button(isSavedInstance ? "保存更改" : "保存 Agent") { save() }.buttonStyle(.borderedProminent).disabled(busy || !ready)
                }
            }
        }.padding(22).frame(width: min(700, (NSScreen.main?.visibleFrame.width ?? 900) - 100), height: min(600, (NSScreen.main?.visibleFrame.height ?? 800) - 100))
        .workbenchSurface()
        .interactiveDismissDisabled(busy || model.nativeLoginIDs[instance.id] != nil)
        .onAppear { if isSavedInstance, model.nativeConnections[instance.id] != nil { checkedConfiguration = configuration } }
        .onChange(of: model.nativeConnections[instance.id]) { _, _ in selectAvailableModel() }
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.title = "选择 Codex 可执行文件"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        instance.native?.executable = url.path
    }
    private func chooseWorkspace() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = true; panel.title = "选择独立工作目录"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        instance.native?.workspace = url.resolvingSymlinksInPath().path
    }
    private func connect() {
        error = nil; working = true
        Task {
            defer { working = false }
            do {
                try configuration.validate(requireModel: false)
                _ = try await model.connectNative(instance: instance)
                checkedConfiguration = configuration
                connectionCheckFailed = false
                selectAvailableModel()
            } catch { connectionCheckFailed = true; self.error = error.localizedDescription }
        }
    }
    private func login() {
        error = nil; working = true
        Task {
            defer { working = false }
            do {
                let url = try await model.loginNative(instance: instance)
                guard NSWorkspace.shared.open(url) else {
                    await model.cancelNativeLogin(instanceID: instance.id)
                    throw WorkbenchFailure("无法打开官方登录页面，请检查默认浏览器后重试。")
                }
            } catch { self.error = error.localizedDescription }
        }
    }
    private func selectAvailableModel() {
        guard let info = connection, !info.models.contains(where: { $0.model == configuration.model }) else { return }
        instance.native?.model = (info.models.first { $0.isDefault } ?? info.models.first)?.model ?? ""
    }
    private func save() {
        guard ready else { return }
        guard !working else { return }
        working = true
        Task {
            defer { working = false }
            do {
                try await model.saveInstance(instance: instance, newKey: "")
                didSave(instance.id); dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
