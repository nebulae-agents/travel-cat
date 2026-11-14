import SwiftUI
import AppKit

private struct AgentXWorkflowEditSession: Codable {
    var definition: AgentXWorkflowDefinition
    var expected: AgentXWorkflowDefinition?
}

@MainActor
struct AgentXWorkflowStudioView: View {
    @ObservedObject var controller: AgentXController
    @State private var editingAppID = ""
    @State private var draft = AgentXWorkflowDefinition(name: "", steps: [])
    @State private var expected: AgentXWorkflowDefinition?
    @State private var notice: String?
    private var prompt: String { controller.studioInputs["workflow:" + editingAppID] ?? "" }
    private var promptBinding: Binding<String> { Binding(get: { prompt }, set: { controller.studioInputs["workflow:" + editingAppID] = $0 }) }
    @State private var saveTask: Task<Void, Never>?
    @State private var confirmPublish = false
    @State private var restoring = false

    private var app: AgentXApplication? { controller.state.apps.first { $0.id == editingAppID } }
    private var members: [AgentXInstance] { controller.state.instances.filter { $0.appID == editingAppID } }
    private var published: AgentXWorkflowRevision? { app?.workflow?.published }
    private var latestRun: AgentXRun? {
        controller.state.runs.filter { $0.appID == editingAppID && $0.purpose == .workflow }.max { $0.startedAt < $1.startedAt }
    }
    private var busy: Bool { published?.definition.steps.contains { controller.isInstanceBusy($0.instanceID) } ?? false }
    private var isDirty: Bool { draft != (expected ?? .init(name: "", steps: [])) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("工作流").font(.title2.bold())
                        Text("按顺序执行文本步骤，前一步输出传给下一步；失败即停止。无工具执行。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(published.map { "已发布 v\($0.number)" } ?? "尚未发布").font(.caption)
                }
                if app?.canRunHostText != true {
                    Label("此应用不支持宿主文本执行，工作流暂不可运行。", systemImage: "info.circle").foregroundStyle(.orange)
                }
                editor
                if let notice {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(notice).foregroundStyle(.orange)
                        if isDirty {
                            Text("未保存内容保留在当前会话中，请重试保存；退出应用前请复制备份。")
                                .font(.caption)
                            HStack {
                                Button("重试保存") { _ = save() }
                                Button("复制草稿") { copyDraft() }
                            }
                        }
                    }
                }
                Divider()
                execution
                if let run = latestRun { result(run) }
            }.padding(24)
        }
        .onAppear { restore(controller.selectedAppID) }
        .onChange(of: controller.selectedAppID) { _, id in
            _ = save(); restore(id)
        }
        .onChange(of: draft) { _, _ in scheduleSave() }
        .onDisappear { saveTask?.cancel(); _ = save() }
        .confirmationDialog("发布当前工作流？", isPresented: $confirmPublish, titleVisibility: .visible) {
            Button("发布新版本") {
                guard save() else { return }
                do { try controller.publishWorkflow(appID: editingAppID); notice = nil }
                catch { notice = error.localizedDescription }
            }
        } message: { Text("之后的新运行使用此版本；进行中的运行保留原版本。") }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("草稿").font(.headline)
                Text(isDirty ? "未保存" : "已保存").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("发布…") { confirmPublish = true }.disabled(draft.steps.isEmpty || app?.canRunHostText != true)
            }
            TextField("工作流名称", text: $draft.name).textFieldStyle(.roundedBorder)
            if draft.steps.isEmpty { Text("添加步骤并选择本应用成员，开始编排。 ").foregroundStyle(.secondary) }
            ForEach(draft.steps) { step in stepEditor(step.id) }
            Button { draft.steps.append(.init(name: "步骤 \(draft.steps.count + 1)", instanceID: "", instruction: "")) } label: {
                Label("添加步骤（\(draft.steps.count)/12）", systemImage: "plus")
            }.disabled(draft.steps.count >= AgentXWorkflowDefinition.maximumSteps)
        }
    }

    private func stepEditor(_ id: String) -> some View {
        let index = draft.steps.firstIndex { $0.id == id } ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(index + 1)").font(.headline).foregroundStyle(.secondary)
                TextField("步骤名称", text: stepField(id, \.name)).textFieldStyle(.roundedBorder)
                Button { move(id, by: -1) } label: { Image(systemName: "arrow.up") }.disabled(index == 0).help("上移步骤")
                Button { move(id, by: 1) } label: { Image(systemName: "arrow.down") }.disabled(index >= draft.steps.count - 1).help("下移步骤")
                Button { draft.steps.removeAll { $0.id == id } } label: { Image(systemName: "trash") }.help("删除步骤")
            }
            Picker("执行成员", selection: stepField(id, \.instanceID)) {
                Text("请选择本应用成员").tag("")
                ForEach(members) { member in Text(member.name).tag(member.id) }
            }
            Text("步骤指令").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: stepField(id, \.instruction)).font(.body).frame(minHeight: 76)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.25)))
                .accessibilityLabel("步骤 \(index + 1) 指令")
        }.padding(12).background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private var execution: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("运行已发布版本").font(.headline)
            if let published {
                Text("v\(published.number) · \(published.definition.name) · \(published.definition.steps.count) 个步骤").foregroundStyle(.secondary)
            } else { Text("先发布工作流，再输入任务开始运行。").foregroundStyle(.secondary) }
            TextField("本次任务输入", text: promptBinding, axis: .vertical).lineLimit(2...5).textFieldStyle(.roundedBorder)
            HStack {
                Button("开始运行") { controller.startWorkflow(prompt, appID: editingAppID) }
                    .disabled(published == nil || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy || app?.canRunHostText != true)
                if busy { Text("流程成员正在运行，请等待完成。").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private func result(_ run: AgentXRun) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("最近运行 · v\(run.workflowRevision ?? 0)").font(.headline)
                Text(run.status.label).font(.caption)
                Spacer()
                if !run.status.terminal { Button("取消运行") { controller.cancel(run.id) }.disabled(run.status == .cancelling) }
            }
            if let failure = run.failure { Text(failure).foregroundStyle(.orange).textSelection(.enabled) }
            ForEach(run.workflowSteps ?? []) { step in
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(step.name) · \(step.status.label)").font(.subheadline.bold())
                    AgentXConfigurationDetails(configuration: step.effectiveConfiguration, title: "步骤运行配置")
                    if !step.output.isEmpty { Text(step.output).textSelection(.enabled) }
                    if let failure = step.failure { Text(failure).foregroundStyle(.orange).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func stepField(_ id: String, _ keyPath: WritableKeyPath<AgentXWorkflowStep, String>) -> Binding<String> {
        Binding(get: { draft.steps.first { $0.id == id }?[keyPath: keyPath] ?? "" }, set: { value in
            guard let index = draft.steps.firstIndex(where: { $0.id == id }) else { return }
            draft.steps[index][keyPath: keyPath] = value
        })
    }
    private func move(_ id: String, by offset: Int) {
        guard let index = draft.steps.firstIndex(where: { $0.id == id }), draft.steps.indices.contains(index + offset) else { return }
        draft.steps.swapAt(index, index + offset)
    }
    private func restore(_ appID: String) {
        saveTask?.cancel(); restoring = true; editingAppID = appID; notice = nil
        if let data = controller.workflowEditorDrafts[appID], let cached = try? JSONDecoder().decode(AgentXWorkflowEditSession.self, from: data) {
            draft = cached.definition; expected = cached.expected
            notice = "已恢复尚未保存的草稿。"
        } else {
            expected = controller.state.apps.first { $0.id == appID }?.workflow?.draft
            draft = expected ?? .init(name: "", steps: [])
        }
        restoring = false
    }
    private func scheduleSave() {
        guard !restoring, !editingAppID.isEmpty else { return }
        cache(); saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            _ = save()
        }
    }
    private func cache() {
        guard isDirty else { controller.workflowEditorDrafts.removeValue(forKey: editingAppID); return }
        controller.workflowEditorDrafts[editingAppID] = try? JSONEncoder().encode(AgentXWorkflowEditSession(definition: draft, expected: expected))
    }
    @discardableResult private func save() -> Bool {
        saveTask?.cancel()
        guard !editingAppID.isEmpty, isDirty else { return true }
        cache()
        do {
            try controller.saveWorkflowDraft(appID: editingAppID, definition: draft, expectedDraft: expected)
            expected = draft; controller.workflowEditorDrafts.removeValue(forKey: editingAppID); notice = nil
            return true
        } catch { notice = error.localizedDescription; return false }
    }
    private func copyDraft() {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(draft), let text = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
}
