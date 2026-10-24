import SwiftUI

@MainActor
struct AgentWorkbenchView: View {
    @ObservedObject var model: AgentWorkbenchModel
    @StateObject private var presentation = AgentWorkbenchPresentation()
    @State private var showingSettings = false
    @State private var focusRequest = UUID()
    private struct TaskSheet: Identifiable { enum Kind { case artifacts, audit }; let id: UUID; let kind: Kind }
    @State private var taskSheet: TaskSheet?
    private var selectedTask: WorkbenchTask? { model.state.tasks.first { $0.id == model.selectedTaskID } }
    private var selectedInstance: WorkbenchInstance? { model.state.instances.first { $0.id == model.preferredInstanceID } }
    private var visibleTasks: [WorkbenchTask] {
        WorkbenchConversationPresentation.tasks(model.state.tasks, instanceID: presentation.filterInstanceID,
            query: presentation.query, scope: presentation.scope, pendingTaskIDs: model.pendingConversationTaskIDs)
    }
    private var newTarget: WorkbenchDraftTarget { .new(model.preferredInstanceID) }
    private var newDraft: Binding<WorkbenchSubmissionDraft> {
        let target = newTarget
        return Binding(get: { model.draft(for: target) }, set: { value in model.updateDraft(target) { $0 = value } })
    }
    private var modelConsent: Binding<Bool> {
        Binding(get: { model.preferredInstanceID.flatMap { presentation.modelConsent[$0] } ?? false }, set: { if let id = model.preferredInstanceID { presentation.modelConsent[id] = $0 } })
    }

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 200, idealWidth: 224, maxWidth: 280)
            VStack(spacing: 0) {
                if let notice = model.draftSaveNotice {
                    HStack {
                        Label(notice, systemImage: "exclamationmark.triangle")
                        Spacer()
                        Button("重试保存") { model.retryDraftSave() }
                    }.font(.system(size: 12)).padding(12).background(WorkbenchTheme.warning)
                }
                if let error = model.auditError {
                    Label(error, systemImage: "exclamationmark.shield").font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).padding(12).foregroundStyle(CottageTheme.terracotta).background(WorkbenchTheme.warning)
                }
                if let task = selectedTask {
                    AgentConversationView(model: model, presentation: presentation, task: task,
                        artifacts: { taskSheet = .init(id: task.id, kind: .artifacts) }, audit: { taskSheet = .init(id: task.id, kind: .audit) },
                        handoff: { handoff(task, to: $0) }, settings: { showingSettings = true }).id(task.id)
                } else { newConversation }
            }.frame(minWidth: 450, maxWidth: .infinity, maxHeight: .infinity)
        }
        .disabled(!model.isStorageReady)
        .accessibilityHidden(!model.isStorageReady)
        .overlay { if !model.isStorageReady { storageRecovery } }
        .frame(minWidth: 760, minHeight: 600).workbenchSurface()
        .background(WorkbenchReadReceipt(taskID: showingSettings || taskSheet != nil ? nil : model.selectedTaskID,
            unread: selectedTask?.unread ?? false, acknowledge: { model.markRead($0) }).frame(width: 0, height: 0))
        .onAppear {
            if model.preferredInstanceID == nil, let first = model.state.instances.first { model.openInstance(first.id) }
            revealSelection()
        }
        .onChange(of: model.selectedTaskID) { _, _ in revealSelection() }
        .onChange(of: model.conversationNavigationRevision) { _, _ in revealSelection() }
        .onChange(of: selectedTask?.archivedAt) { _, _ in revealSelection() }
        .sheet(isPresented: $showingSettings) { AgentWorkbenchSettingsView(model: model, didCreate: { id in model.preferredInstanceID = id; model.selectedTaskID = nil; focusRequest = UUID() }) }
        .sheet(item: $taskSheet) { sheet in
            switch sheet.kind {
            case .artifacts: AgentArtifactsView(model: model, taskID: sheet.id)
            case .audit: AgentCallInspector(model: model, taskID: sheet.id)
            }
        }
        .alert("Agent 工作台", isPresented: Binding(get: { model.isStorageReady && model.error != nil && !showingSettings && taskSheet == nil }, set: { if !$0 { model.error = nil } })) {
            Button("知道了") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
    private var storageRecovery: some View {
        VStack(spacing: 18) {
            if model.storageStatus == .loading {
                ProgressView().controlSize(.large)
                Text("正在安全加载 Agent 数据").font(.title3.weight(.semibold))
                Text("如果系统显示钥匙串提示，请解锁并允许 Travel Cat 访问。等待期间可以继续使用桌面小猫。").font(.callout).foregroundStyle(WorkbenchTheme.muted)
            } else {
                Image(systemName: "lock.shield").font(.system(size: 32)).foregroundStyle(CottageTheme.terracotta)
                Text("安全存储尚未就绪").font(.title3.weight(.semibold))
                Text(model.storageStatus.message ?? "请完成钥匙串授权后重试。").font(.callout).foregroundStyle(WorkbenchTheme.muted).textSelection(.enabled)
                Button("重试") { model.retryStorage() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                Text("原有对话、审计记录和密钥会保留。").font(.caption).foregroundStyle(WorkbenchTheme.muted)
            }
        }.multilineTextAlignment(.center).padding(36).frame(maxWidth: .infinity, maxHeight: .infinity).background(WorkbenchTheme.canvas)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: "cat").foregroundStyle(WorkbenchTheme.accent).frame(width: 28, height: 28).background(WorkbenchTheme.selection, in: RoundedRectangle(cornerRadius: 9))
                Text("Travel Cat").font(.system(size: 14, weight: .semibold)); Spacer()
            }.padding(.horizontal, 8).padding(.top, 6)
            Button { openNewConversation() } label: { Label("新对话", systemImage: "plus").font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5) }
                .buttonStyle(.borderedProminent).keyboardShortcut("n", modifiers: .command)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("对话").font(.system(size: 12)).foregroundStyle(WorkbenchTheme.muted)
                    Spacer()
                    let count = model.permissions.count + model.modelApprovals.count
                    if count > 0 { Button("\(count) 待确认") { openPending() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(CottageTheme.terracotta) }
                }
                TextField("搜索标题和消息", text: Binding(get: { presentation.query }, set: { presentation.updateQuery($0) }))
                    .textFieldStyle(.roundedBorder).accessibilityLabel("搜索标题和消息")
                if let error = presentation.queryError { Text(error).font(.caption).foregroundStyle(CottageTheme.terracotta) }
                Picker("对话范围", selection: $presentation.scope) {
                    ForEach(WorkbenchConversationScope.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
                Picker("按 Agent 筛选", selection: $presentation.filterInstanceID) {
                    Text("全部 Agent").tag(Optional<UUID>.none)
                    ForEach(model.state.instances) { Text($0.name).tag(Optional($0.id)) }
                }.labelsHidden().controlSize(.small)
            }.padding(.horizontal, 5).padding(.top, 4)
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(visibleTasks) { task in
                        Button {
                            model.selectedTaskID = task.id
                            model.preferredInstanceID = task.instanceID
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(WorkbenchConversationPresentation.shortTitle(task.displayTitle)).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                    Spacer(minLength: 2)
                                    if task.pinnedAt != nil { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(WorkbenchTheme.accent).accessibilityLabel("已置顶") }
                                    if task.unread { Circle().fill(CottageTheme.terracotta).frame(width: 5, height: 5) }
                                }
                                Text("\(instanceName(task.instanceID)) · \(task.status.title)").font(.system(size: 12)).foregroundStyle(WorkbenchTheme.muted).lineLimit(1)
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(model.selectedTaskID == task.id ? WorkbenchTheme.selection : .clear, in: RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
                        }.buttonStyle(.plain).help(task.displayTitle)
                    }
                    if visibleTasks.isEmpty { Text(presentation.query.isEmpty ? (presentation.scope == .archived ? "暂无已归档对话。" : "对话会保留在这里。") : "没有匹配的对话。").font(.system(size: 12)).foregroundStyle(WorkbenchTheme.muted).padding(.top, 12) }
                }
            }
            Divider()
            Button { showingSettings = true } label: { Label("设置", systemImage: "gearshape").font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).padding(7) }
                .buttonStyle(.plain).foregroundStyle(WorkbenchTheme.muted).keyboardShortcut(",", modifiers: [.command, .shift])
        }.padding(12).background(WorkbenchTheme.sidebar)
    }
    private var newConversation: some View {
        VStack(spacing: 0) {
            HStack { Text("新对话").font(.system(size: 14, weight: .semibold)); Spacer() }.padding(24)
            Divider()
            VStack(spacing: 14) {
                Image(systemName: "cat").font(.system(size: 27)).foregroundStyle(WorkbenchTheme.accent).frame(width: 54, height: 54).background(WorkbenchTheme.sidebar, in: RoundedRectangle(cornerRadius: 17))
                Text("从一个想法开始").font(.system(size: 21, weight: .medium))
                Text(model.state.instances.isEmpty ? "先添加一个 Agent，再一起完成任务。" : "选择 Agent，说说你想完成的事。").font(.system(size: 13)).foregroundStyle(WorkbenchTheme.muted)
                if model.state.instances.isEmpty { Button("添加 Agent…") { showingSettings = true }.buttonStyle(.bordered) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 12) {
                if !model.state.instances.isEmpty {
                    Picker("使用 Agent", selection: $model.preferredInstanceID) {
                        Text("未选择 Agent · 独立草稿").tag(Optional<UUID>.none)
                        ForEach(model.state.instances) { Text($0.name).tag(Optional($0.id)) }
                    }.frame(maxWidth: 320).controlSize(.small)
                }
                let canSend = model.isStorageReady && !model.isStarting && !model.isDraftSubmitting(newTarget) && selectedInstance != nil && !newDraft.wrappedValue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                AgentComposerView(draft: newDraft, instance: selectedInstance,
                    parentTitle: model.state.tasks.first(where: { $0.id == newDraft.wrappedValue.parentTaskID })?.displayTitle,
                    removeParent: { model.removeDraftParent(newTarget) }, isNew: true, canSend: canSend, focusRequest: focusRequest,
                    hint: model.isDraftSubmitting(newTarget) ? "正在确认提交结果，草稿会保留到确认成功；新编辑的内容会独立保留。" : (model.isStarting ? "正在建立新对话，输入中的新内容会保留为草稿。" : nil), allowModelAccess: modelConsent, onFailure: { model.error = $0 }, send: start)
            }.padding(24).frame(maxWidth: 780)
        }.background(WorkbenchTheme.canvas)
    }
    private func revealSelection() {
        if let selectedTask { presentation.reveal(selectedTask, pendingTaskIDs: model.pendingConversationTaskIDs) }
    }
    private func openNewConversation() {
        model.selectedTaskID = nil
        if model.preferredInstanceID == nil { model.preferredInstanceID = model.state.instances.first?.id }
        focusRequest = UUID()
    }
    private func openPending() {
        let ids = Set(model.permissions.map(\.taskID) + model.modelApprovals.map(\.taskID))
        if let task = model.state.tasks.first(where: { ids.contains($0.id) }) { model.openConversation(task.id) }
    }
    private func start() {
        guard let instance = selectedInstance, !model.isStarting else { return }
        let target = newTarget, submitted = model.draft(for: newTarget)
        guard !submitted.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let native = instance.native != nil
        let policy = native || modelConsent.wrappedValue ? "task" : "review"
        Task {
            await model.startDraft(target: target, instanceID: instance.id, modelPolicy: policy) {
                presentation.modelConsent[instance.id] = false
            }
        }
    }
    private func handoff(_ task: WorkbenchTask, to instance: WorkbenchInstance) {
        let text = "承接对话：\(task.title)\n\n上轮回复：\n" + (task.messages.last(where: { $0.role == "assistant" })?.text ?? "")
        model.updateDraft(.new(instance.id)) { draft in
            if !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { draft.text += "\n\n" + text } else { draft.text = text }
            draft.parentTaskID = task.id
        }
        model.preferredInstanceID = instance.id; model.selectedTaskID = nil; focusRequest = UUID()
    }
    private func instanceName(_ id: UUID) -> String { model.state.instances.first { $0.id == id }?.name ?? "已移除的 Agent" }
}
