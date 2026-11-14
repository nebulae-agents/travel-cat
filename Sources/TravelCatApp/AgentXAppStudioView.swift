import AppKit
import SwiftUI

private struct AgentXExperienceEditSession: Codable {
    var configuration: AgentXAppExperience
    var expected: AgentXAppExperience?
    var baseline: AgentXAppExperience
}

/// All application backstage sections use one draft and one optimistic save boundary.
@MainActor
struct AgentXAppStudioView: View {
    @ObservedObject var controller: AgentXController
    let section: AgentXPage
    @State private var editingAppID = ""
    @State private var draft = AgentXAppExperience()
    @State private var baseline = AgentXAppExperience()
    @State private var expected: AgentXAppExperience?
    @State private var saveTask: Task<Void, Never>?
    @State private var notice: String?
    @State private var publishAppID: String?
    @State private var confirmingPublish = false

    private var app: AgentXApplication? { controller.state.apps.first { $0.id == editingAppID } }
    private var isDirty: Bool { draft != baseline }
    private var members: [AgentXInstance] { controller.state.instances.filter { $0.appID == editingAppID } }
    private var providers: [AgentXProvider] { controller.state.providers.filter { $0.enabled && !$0.enabledModels.isEmpty } }
    private var unpublished: Bool { app?.experience?.published?.configuration != draft }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let app {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(section.title).font(.title2.bold())
                            Text(app.name + " · 应用后台").foregroundStyle(AgentXTheme.muted)
                        }
                        Spacer()
                        if section != .appFiles {
                            Button("发布到前台") {
                                publishAppID = editingAppID
                                confirmingPublish = true
                            }.buttonStyle(.borderedProminent).tint(AgentXTheme.accent)
                                .disabled(!controller.isLoaded || !unpublished || (expected == nil && !isDirty))
                        }
                    }
                    if !app.canRunHostText {
                        Label("此应用尚未接入当前文本执行器。可编辑配置，但发布不代表运行框架已支持。", systemImage: "info.circle")
                            .foregroundStyle(AgentXTheme.muted)
                    }
                    if section != .appFiles { revisionCard }
                    switch section {
                    case .sceneRules: sceneRules
                    case .appModels: modelSettings
                    case .appFiles: files
                    case .appSettings: presentation
                    default: EmptyView()
                    }
                } else {
                    Text("请先选择一个应用。").foregroundStyle(AgentXTheme.muted)
                }
            }.padding(24).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)
        }
        .onAppear { if editingAppID != controller.selectedAppID { restore(controller.selectedAppID) } }
        .onChange(of: controller.selectedAppID) { _, id in
            _ = save()
            confirmingPublish = false; publishAppID = nil
            restore(id)
        }
        .onDisappear { _ = save() }
        .confirmationDialog("发布应用配置？", isPresented: $confirmingPublish, titleVisibility: .visible) {
            Button("确认发布") { publish() }
            Button("取消", role: .cancel) { publishAppID = nil }
        } message: {
            Text("将当前应用的场景、共享记忆、成员模型和前台呈现一起发布。只影响后续运行，不打断正在进行的运行。")
        }
    }

    private var revisionCard: some View {
        AgentXCard {
            HStack {
                Label(app?.experience?.published.map { "前台已发布 v\($0.number)" } ?? "前台尚未发布", systemImage: "checkmark.seal")
                Spacer()
                Text(notice != nil && isDirty ? "草稿保存失败" : (isDirty ? "草稿待保存" : (expected == nil ? "尚无草稿" : "草稿已保存")))
                    .foregroundStyle(isDirty ? AgentXTheme.accent : AgentXTheme.muted)
            }
            Text(unpublished ? "当前编辑内容尚未发布。场景、模型与应用设置共享同一份草稿。" : "草稿与当前发布版本一致。")
                .font(.callout).foregroundStyle(AgentXTheme.muted)
            if let notice {
                Text(notice).foregroundStyle(.orange).textSelection(.enabled)
                HStack {
                    Button("重试保存") { _ = save() }
                    Button("复制草稿") { copyDraft() }
                }
            }
        }
    }

    private var sceneRules: some View {
        VStack(spacing: 18) {
            textCard("世界与开场", hint: "说明背景、参与者和初始情境。", text: field(\.intro))
            textCard("场景与规则", hint: "约定角色行为、互动边界和推进方式。", text: field(\.rules))
            textCard("应用级共享记忆", hint: "记录所有成员共享的事实与共识；发布后供后续运行使用。此处不会直接改写实例的记忆文件。", text: field(\.sharedMemory))
        }
    }

    private func textCard(_ title: String, hint: String, text: Binding<String>) -> some View {
        AgentXCard {
            Text(title).font(.headline)
            Text(hint).font(.callout).foregroundStyle(AgentXTheme.muted)
            TextEditor(text: text).font(.body).frame(minHeight: 125)
                .padding(8).background(AgentXTheme.background, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel(title)
        }
    }

    private var modelSettings: some View {
        VStack(spacing: 18) {
            AgentXCard {
                Text("成员模型覆盖").font(.headline)
                Text("默认继承实例绑定；覆盖仅属于当前应用的发布配置。选择器只提供已启用服务中的已启用模型。")
                    .foregroundStyle(AgentXTheme.muted)
                if members.isEmpty { Text("此应用还没有成员，请先添加 Agent 实例。").foregroundStyle(AgentXTheme.muted) }
                ForEach(members) { member in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(member.name).font(.headline)
                        Text("实例绑定：\(member.providerID) / \(member.model)").font(.caption).foregroundStyle(AgentXTheme.muted)
                        Picker("使用模型", selection: overrideSelection(member.id)) {
                            Text("继承实例绑定").tag("")
                            ForEach(providers) { provider in
                                ForEach(provider.enabledModels, id: \.self) { model in
                                    Text("\(provider.name) · \(model)").tag(selectionKey(provider.id, model))
                                }
                            }
                            if let value = draft.memberOverrides.first(where: { $0.instanceID == member.id }),
                               !providers.contains(where: { $0.id == value.providerID && $0.enabledModels.contains(value.model) }) {
                                Text("不可用：\(value.providerID) / \(value.model)")
                                    .tag(selectionKey(value.providerID, value.model))
                            }
                        }
                    }.padding(.vertical, 8)
                }
                if draft.memberOverrides.contains(where: { value in !members.contains { $0.id == value.instanceID } }) {
                    Text("草稿包含已移除成员的覆盖，请清理后发布。").foregroundStyle(.orange)
                    Button("清理已移除成员的覆盖") {
                        draft.memberOverrides.removeAll { value in !members.contains { $0.id == value.instanceID } }
                        changed()
                    }
                }
            }
            AgentXCard {
                Label("预算与限额尚未执行", systemImage: "info.circle").font(.headline)
                Text("当前页面不提供可强制执行的费用或调用上限。模型覆盖不会自动设置预算，也不改变平台模型服务配置。")
                    .foregroundStyle(AgentXTheme.muted)
            }
        }
    }

    private var presentation: some View {
        AgentXCard {
            Text("前台呈现").font(.headline)
            TextField("前台标题（留空使用应用名称）", text: field(\.title)).textFieldStyle(.roundedBorder)
            Picker("前台布局", selection: field(\.layout)) {
                Text(AgentXFrontLayout.conversation.title).tag(AgentXFrontLayout.conversation)
                Text(AgentXFrontLayout.scene.title).tag(AgentXFrontLayout.scene)
            }
            if draft.layout == .scene {
                Picker("场景主题", selection: field(\.sceneTheme)) {
                    Text(AgentXSceneTheme.tavern.title).tag(AgentXSceneTheme.tavern)
                    Text(AgentXSceneTheme.harbor.title).tag(AgentXSceneTheme.harbor)
                }
            }
            Divider()
            Text("前台快捷行动 · 最多 3 项").font(.headline)
            Text("留空的项不会显示；开放输入仍可使用。").font(.callout).foregroundStyle(AgentXTheme.muted)
            ForEach(0..<3, id: \.self) { index in
                TextField("行动 \(index + 1)", text: choice(index)).textFieldStyle(.roundedBorder)
            }
            Text("这里只修改当前应用的前台呈现。发布后用于后续运行。").font(.callout).foregroundStyle(AgentXTheme.muted)
        }
    }

    private var files: some View {
        AgentXCard {
            Text("应用目录 · 只读路径").font(.headline)
            Text("以下为当前应用的实际存储位置与目录约定。本页不创建、修改或清理文件；路径展示不代表制品已生成。")
                .foregroundStyle(AgentXTheme.muted)
            pathRow("应用配置", suffix: "app.yaml")
            pathRow("应用共享记忆", suffix: "memory")
            pathRow("成员实例", suffix: "instances")
            pathRow("前台状态", suffix: "state")
            pathRow("生成制品", suffix: "artifacts")
            pathRow("应用共享文件", suffix: "shared")
            pathRow("运行记录", suffix: "runs")
            Text("共享记忆编辑内容随应用配置保存与发布；此处不承诺记忆目录中的文件已被运行框架挂载。").font(.caption).foregroundStyle(AgentXTheme.muted)
        }
    }

    private func pathRow(_ title: String, suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.bold())
            Text(controller.repository.root.appendingPathComponent("apps").appendingPathComponent(editingAppID).appendingPathComponent(suffix).path)
                .font(.system(.caption, design: .monospaced)).foregroundStyle(AgentXTheme.muted).textSelection(.enabled)
        }
    }

    private func field<Value>(_ keyPath: WritableKeyPath<AgentXAppExperience, Value>) -> Binding<Value> {
        Binding(get: { draft[keyPath: keyPath] }, set: { draft[keyPath: keyPath] = $0; changed() })
    }
    private func choice(_ index: Int) -> Binding<String> {
        Binding(get: { draft.choices.indices.contains(index) ? draft.choices[index] : "" }, set: { value in
            while draft.choices.count <= index { draft.choices.append("") }
            draft.choices[index] = value
            changed()
        })
    }
    private func selectionKey(_ provider: String, _ model: String) -> String {
        // Length-prefix the provider to avoid collisions with arbitrary model identifiers.
        "\(provider.utf8.count):\(provider)\(model)"
    }
    private func overrideSelection(_ instanceID: String) -> Binding<String> {
        Binding(get: {
            guard let value = draft.memberOverrides.first(where: { $0.instanceID == instanceID }) else { return "" }
            return selectionKey(value.providerID, value.model)
        }, set: { key in
            if key.isEmpty {
                draft.memberOverrides.removeAll { $0.instanceID == instanceID }; changed(); return
            }
            for provider in providers {
                if let model = provider.enabledModels.first(where: { selectionKey(provider.id, $0) == key }) {
                    draft.memberOverrides.removeAll { $0.instanceID == instanceID }
                    draft.memberOverrides.append(.init(instanceID: instanceID, providerID: provider.id, model: model))
                    changed(); return
                }
            }
        })
    }
    private func restore(_ appID: String) {
        saveTask?.cancel(); editingAppID = appID; notice = nil
        if let data = controller.experienceEditorDrafts[appID],
           let session = try? JSONDecoder().decode(AgentXExperienceEditSession.self, from: data) {
            draft = session.configuration; expected = session.expected; baseline = session.baseline
            notice = "已恢复未保存草稿；请重试保存，或复制草稿后处理冲突。"
        } else {
            let configuration = controller.state.apps.first { $0.id == appID }?.experience
            expected = configuration?.draft
            draft = expected ?? configuration?.published?.configuration ?? AgentXAppExperience()
            baseline = draft
        }
    }
    private func changed() {
        cache(); saveTask?.cancel()
        let appID = editingAppID
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, editingAppID == appID else { return }
            _ = save()
        }
    }
    private func cache() {
        guard !editingAppID.isEmpty else { return }
        if isDirty {
            controller.experienceEditorDrafts[editingAppID] = try? JSONEncoder().encode(
                AgentXExperienceEditSession(configuration: draft, expected: expected, baseline: baseline))
        } else { controller.experienceEditorDrafts.removeValue(forKey: editingAppID) }
    }
    @discardableResult private func save() -> Bool {
        saveTask?.cancel()
        guard !editingAppID.isEmpty, isDirty else { return true }
        cache()
        do {
            try controller.saveExperienceDraft(appID: editingAppID, configuration: draft, expectedDraft: expected)
            expected = draft; baseline = draft; notice = nil
            controller.experienceEditorDrafts.removeValue(forKey: editingAppID)
            return true
        } catch { notice = error.localizedDescription; return false }
    }
    private func publish() {
        guard publishAppID == editingAppID, save() else { return }
        do {
            try controller.publishExperience(appID: editingAppID)
            notice = nil
        } catch { notice = error.localizedDescription }
        publishAppID = nil
    }
    private func copyDraft() {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let bytes = try? encoder.encode(draft), let text = String(data: bytes, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
}
