import SwiftUI
import AppKit

@MainActor
struct AgentWorkbenchSettingsView: View {
    @ObservedObject var model: AgentWorkbenchModel
    let didCreate: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var page: Page = .agents
    @State private var nativeEditing: WorkbenchInstance?
    @State private var editing: WorkbenchInstance?
    @State private var quickCreate = false
    @State private var pythonPath = ""
    @State private var host = ""
    @State private var context = ""
    @State private var advancedEnvironment = false
    @State private var storageTaskID: UUID?
    @State private var removing: WorkbenchInstance?

    private enum Page: String, CaseIterable, Identifiable {
        case agents = "Agent", environment = "运行环境", storage = "数据与审计"
        var id: Self { self }
        var symbol: String { switch self { case .agents: "person.crop.square"; case .environment: "terminal"; case .storage: "externaldrive.badge.checkmark" } }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("设置").font(.headline)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("关闭设置，返回对话").accessibilityLabel("关闭设置")
                    .keyboardShortcut(.cancelAction)
            }.padding(.horizontal, 20).padding(.vertical, 15)
            Divider()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("AGENT 工作台").font(.caption2).foregroundStyle(WorkbenchTheme.muted).padding(.bottom, 8)
                    ForEach(Page.allCases) { item in
                        Button { page = item } label: {
                            Label(item.rawValue, systemImage: item.symbol).font(.system(size: 13))
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 9)
                                .background(page == item ? WorkbenchTheme.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain)
                    }
                    Spacer()
                }.padding(14).frame(width: 165).background(WorkbenchTheme.sidebar)
                Divider()
                Group {
                    switch page {
                    case .agents: agents
                    case .environment: environment
                    case .storage: AgentAuditStorageView(model: model, selectedTaskID: storageTaskID, embedded: true)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            if let error = model.error {
                HStack { Text(error).font(.caption).textSelection(.enabled); Spacer(); Button("知道了") { model.error = nil } }
                    .padding(12).foregroundStyle(CottageTheme.terracotta).background(WorkbenchTheme.warning)
            }
            Divider()
            HStack { Text("关闭设置不会停止当前任务。").font(.caption).foregroundStyle(WorkbenchTheme.muted); Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
                .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: min(780, (NSScreen.main?.visibleFrame.width ?? 1000) - 80), height: min(600, (NSScreen.main?.visibleFrame.height ?? 800) - 100))
        .workbenchSurface()
        .onAppear { pythonPath = model.state.pythonPath; storageTaskID = model.selectedTaskID }
        .sheet(item: $nativeEditing) { instance in
            let adding = !model.state.instances.contains(where: { $0.id == instance.id })
            NativeAgentSetupView(model: model, instance: instance) { id in
                if adding { didCreate(id); dismiss() }
            }
        }
        .sheet(item: $editing) { instance in
            let adding = !model.state.instances.contains(where: { $0.id == instance.id })
            AgentInstanceEditor(instance: instance) { next, key in
                try await model.saveInstance(instance: next, newKey: key)
                if adding { didCreate(next.id); dismiss() }
            }
        }
        .sheet(isPresented: $quickCreate) {
            AgentQuickCreateView(model: model, openManual: {
                DispatchQueue.main.async { editing = WorkbenchInstance(name: "", image: "", command: ["codex-acp"]) }
            }, didSave: { id in didCreate(id); dismiss() })
        }
        .alert("删除这个 Agent？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("取消", role: .cancel) { removing = nil }
            Button("删除 Agent", role: .destructive) { if let item = removing { Task { await model.removeInstance(instanceID: item.id) } }; removing = nil }.disabled(model.savingInstance)
        } message: { Text("已有任务和运行中的会话仍会受到原有保护规则限制。") }
    }

    private var agents: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Agent").font(.title3.weight(.semibold)); Spacer()
                    Menu("添加 Agent") {
                        Button("本机 Codex · 官方账号") { nativeEditing = NativeAgentSetupView.newInstance() }
                        Button("ACP · Docker") { quickCreate = true }
                        Button("高级手动配置…") { editing = WorkbenchInstance(name: "", image: "", command: ["codex-acp"]) }
                    }
                }
                Text("选择一个 Agent 管理名称、工作目录、模型与连接。").font(.caption).foregroundStyle(WorkbenchTheme.muted)
                if model.state.instances.isEmpty {
                    ContentUnavailableView("还没有 Agent", systemImage: "person.crop.square", description: Text("添加本机 Codex，或连接受管 ACP 容器。"))
                }
                ForEach(model.state.instances) { instance in
                    HStack(spacing: 12) {
                        Button { edit(instance) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: instance.symbol).foregroundStyle(WorkbenchTheme.accent).frame(width: 32, height: 32).background(WorkbenchTheme.sidebar, in: RoundedRectangle(cornerRadius: 9))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(instance.name).font(.system(size: 13, weight: .medium))
                                    Text(instance.native != nil ? "本机 Codex · 官方账号" : (instance.host.isEmpty ? "ACP 容器 · 本机" : "ACP 容器 · \(instance.host)"))
                                        .font(.caption).foregroundStyle(WorkbenchTheme.muted)
                                }
                                Spacer()
                                if instance.native != nil, let connection = model.nativeConnections[instance.id] {
                                    Text(connection.authenticated ? "已登录" : "未登录").font(.caption).foregroundStyle(WorkbenchTheme.muted)
                                }
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(WorkbenchTheme.muted)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Menu {
                            Button("编辑配置…") { edit(instance) }
                            Button("删除 Agent…", role: .destructive) { removing = instance }
                        } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 22)
                    }.padding(13).workbenchPanel()
                }
                Text("已有会话使用固定的 Agent 配置；更换工作目录时新建一个 Agent。").font(.caption).foregroundStyle(WorkbenchTheme.muted)
            }.padding(24)
        }
    }
    private func edit(_ instance: WorkbenchInstance) { if instance.native != nil { nativeEditing = instance } else { editing = instance } }

    private var environment: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("运行环境").font(.title3.weight(.semibold))
                Text("程序路径与远程连接集中在这里，日常对话无需展开。").font(.caption).foregroundStyle(WorkbenchTheme.muted)
                LabeledContent("Python") { Text(URL(fileURLWithPath: model.state.pythonPath).lastPathComponent).textSelection(.enabled) }
                DisclosureGroup("路径与远程连接", isExpanded: $advancedEnvironment) {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Python 3.11+ 绝对路径", text: $pythonPath)
                        Button("保存 Python 路径") { model.setPythonPath(pythonPath) }
                        Divider()
                        TextField("SSH 别名（留空检查本机）", text: $host)
                        TextField("Docker context（留空用默认）", text: $context)
                        Button(model.discovering ? "检查中…" : "检查 Docker 环境与镜像") { Task { await model.discover(host: host, context: context) } }.disabled(model.discovering)
                    }.padding(.top, 12)
                }
                if !model.discovery.isEmpty {
                    Text(model.discovery).font(.caption).textSelection(.enabled)
                }
                if !model.availableImages.isEmpty {
                    DisclosureGroup("发现的镜像 · \(model.availableImages.count)") {
                        Text(model.availableImages.joined(separator: "\n")).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    }
                }
                Text("检查使用已有 SSH 配置；不会自动安装工具或拉取镜像。").font(.caption).foregroundStyle(WorkbenchTheme.muted)
            }.textFieldStyle(.roundedBorder).padding(24)
        }
    }
}
