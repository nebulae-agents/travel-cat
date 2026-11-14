import SwiftUI

@MainActor
struct AgentXCharacterStudioView: View {
    @ObservedObject var controller: AgentXController
    @State private var instanceID = ""
    @State private var profile = AgentXCharacterProfile()
    @State private var baseDocument: AgentXDefinitionDocument?
    @State private var dirty = false
    @State private var message = ""
    @State private var saveStatus = ""
    @State private var autosaveTask: Task<Void, Never>?
    @State private var autosaveGeneration = UUID()
    private var preview: String { controller.studioInputs["character:" + instanceID] ?? "你看见一位陌生客人走进门，请说一句话。" }
    private var previewBinding: Binding<String> { Binding(get: { preview }, set: { controller.studioInputs["character:" + instanceID] = $0 }) }
    @State private var confirmingPublish = false
    @State private var loadedAppID = ""

    private struct EditorDraft: Codable {
        var instanceID: String
        var profile: AgentXCharacterProfile
        var baseDocument: AgentXDefinitionDocument?
    }
    private var generationDescription: Binding<String> {
        Binding(get: { controller.studioInputs["character-generator:" + instanceID] ?? "" },
                set: { controller.studioInputs["character-generator:" + instanceID] = $0 })
    }
    private var actionUnavailableReason: String? {
        guard let instance, instance.appID == loadedAppID, baseDocument != nil else { return "请先选择关联定义的人物实例。" }
        guard controller.state.apps.first(where: { $0.id == instance.appID })?.canRunHostText == true else { return "此应用的运行框架尚未接入，暂不能试说、生成或发布。" }
        if controller.isInstanceBusy(instance.id) { return "此实例正在运行，请等待完成或取消后再试。" }
        return nil
    }
    private var instance: AgentXInstance? { controller.state.instances.first { $0.id == instanceID }.map(controller.effectiveInstance) }
    private var definition: AgentXDefinition? { controller.state.definitions.first { $0.id == instance?.definitionID } }
    private var previewRuns: [AgentXRun] {
        controller.state.runs.filter { $0.instanceID == instanceID && $0.purpose == .characterPreview }.reversed()
    }
    private var activeRun: AgentXRun? { previewRuns.first { !$0.status.terminal } }
    private var publicationImpact: String {
        guard let definition else { return "尚未选择人物定义。" }
        return (try? controller.definitionPublicationImpact(id: definition.id).map(\.label).joined(separator: "\n")) ?? "无法解析发布影响；发布会被阻止。"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text("人物定制").font(.title2.bold())
                Text("十二维度人物卡 · 自动保存草稿，发布后用于后续对话").foregroundStyle(.secondary)
                ViewThatFits(in: .horizontal) {
                    HStack { characterPicker; saveActions }
                    VStack(alignment: .leading) { characterPicker; saveActions }
                }
            }
            if !message.isEmpty { Text(message).foregroundStyle(.orange).textSelection(.enabled) }
            if !saveStatus.isEmpty { Text(saveStatus).font(.caption).foregroundStyle(.secondary) }
            if let reason = actionUnavailableReason { Text(reason).font(.caption).foregroundStyle(.secondary) }
            if dirty {
                Text("修改待保存；离开页面或切换应用会保留本次编辑。保存失败时请保留窗口并重试。").font(.caption).foregroundStyle(.orange)
            }
            if baseDocument == nil {
                ContentUnavailableView("选择人物实例", systemImage: "person.crop.rectangle", description: Text("先在应用中创建实例，并关联一个定义。"))
            } else {
                GeometryReader { geometry in
                    ScrollView {
                        let layout = geometry.size.width >= 850
                            ? AnyLayout(HStackLayout(alignment: .top, spacing: 18))
                            : AnyLayout(VStackLayout(alignment: .leading, spacing: 18))
                        layout {
                            characterCards(availableWidth: geometry.size.width)
                            previewPanel.frame(maxWidth: geometry.size.width >= 850 ? 280 : .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
        .padding(20)
        .onAppear { restore() }
        .onChange(of: instanceID) { _, _ in if !dirty { load() } }
        .onChange(of: controller.selectedAppID) { _, _ in restore() }
        .onDisappear { _ = save(); cache() }
        .confirmationDialog("发布人物定义？", isPresented: $confirmingPublish) {
            Button("保存并发布") {
                guard actionUnavailableReason == nil, save(), let definition else { return }
                do { try controller.publishDefinition(id: definition.id); message = "已发布人物定义。" }
                catch { message = error.localizedDescription }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将发布当前草稿。\n" + publicationImpact)
        }
    }
    private func characterCards(availableWidth: CGFloat) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: min(260, max(180, availableWidth - 32))), alignment: .top)], alignment: .leading, spacing: 14) {
            ForEach(AgentXCharacterDimension.allCases) { dimension in
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text(dimensionLabel(dimension)).font(.headline); Spacer() }
                        TextEditor(text: Binding(get: { profile.text(for: dimension) }, set: { value in
                            do { try profile.setText(value, for: dimension); dirty = true; message = ""; cache(); scheduleAutosave() }
                            catch { message = error.localizedDescription }
                        })).font(.body).frame(minHeight: 110).accessibilityLabel(dimensionLabel(dimension))
                        if dimension == .background { Text("这里只编辑公开背景。结构化导演字段不会加入自动生成人物摘要；原始提示词中的内容不会自动脱敏。").font(.caption).foregroundStyle(.secondary) }
                        if [.model, .memory, .abilities].contains(dimension) {
                            Text("此处仅记录人物设定，暂不启用相关能力；实际模型仍使用实例设置。").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(4)
                }
            }
        }.frame(maxWidth: .infinity)
    }
    private var previewPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("从描述生成").font(.headline)
            TextEditor(text: generationDescription).frame(height: 90).accessibilityLabel("人物描述")
            Button("从描述生成") {
                guard actionUnavailableReason == nil, save() else { return }
                let description = generationDescription.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !description.isEmpty else { return }
                controller.selectedInstanceID = instanceID
                controller.configurationInstructions[instanceID] = description
                controller.selectedConfigurationRunID = nil
                controller.sendConfigurationRequest(description, instanceID: instanceID)
                controller.navigate(to: .configuration)
            }.disabled(actionUnavailableReason != nil || generationDescription.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Text("生成后进入配置台逐项审阅建议，不会自动应用或发布。").font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("试说一句").font(.headline)
            Text("使用草稿和当前模型真实生成一句话，不加入正式聊天记录。").font(.caption).foregroundStyle(.secondary)
            Text(instance.map { "实际模型：\($0.model)" } ?? "").font(.caption).textSelection(.enabled)
            TextEditor(text: previewBinding).frame(height: 90).accessibilityLabel("试说提示")
            HStack {
                Button("保存并试说") {
                    if actionUnavailableReason == nil, save() { controller.previewCharacter(preview, instanceID: instanceID) }
                }.disabled(preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || actionUnavailableReason != nil)
                if let run = activeRun { Button("取消") { controller.cancel(run.id) } }
            }
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(previewRuns.prefix(8))) { run in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(run.prompt).font(.caption).foregroundStyle(.secondary)
                            Text(run.response.isEmpty ? (run.failure ?? statusText(run.status)) : run.response).textSelection(.enabled)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                    }
                }
            Text("原有手写内容会保留；仅结构化导演字段被排除于自动生成的公开摘要。请自行检查原始提示词中的私密内容。").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var characterPicker: some View {
        Picker("人物实例", selection: $instanceID) {
            Text("选择实例").tag("")
            ForEach(controller.currentInstances) { Text($0.name).tag($0.id) }
        }.frame(maxWidth: 260).disabled(dirty)
    }
    private var saveActions: some View {
        HStack {
            Button("保存草稿") { _ = save() }.disabled(baseDocument == nil || !dirty)
            Button("发布人物") { confirmingPublish = true }.disabled(actionUnavailableReason != nil)
        }
    }
    private func dimensionLabel(_ dimension: AgentXCharacterDimension) -> String {
        switch dimension {
        case .identity: "① 身份与外貌"; case .personality: "② 性格"; case .traits: "③ 特质与习惯"
        case .background: "④ 背景与经历"; case .motivation: "⑤ 动机 · 目标 · 恐惧"; case .relations: "⑥ 关系"
        case .boundaries: "⑦ 价值观与底线"; case .abilities: "⑧ 能力与资源"; case .voice: "⑨ 表达方式"
        case .arc: "⑩ 成长弧光"; case .memory: "⑪ 记忆"; case .model: "⑫ 模型与限额"
        }
    }
    private func cancelAutosave() {
        autosaveTask?.cancel()
        autosaveTask = nil
        autosaveGeneration = UUID()
    }
    private func scheduleAutosave() {
        cancelAutosave()
        saveStatus = "等待自动保存…"
        let generation = autosaveGeneration
        let appID = loadedAppID
        let targetInstanceID = instanceID
        let definitionID = definition?.id
        autosaveTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard !Task.isCancelled, generation == autosaveGeneration,
                  appID == loadedAppID, appID == controller.selectedAppID,
                  targetInstanceID == instanceID, definitionID == definition?.id, dirty else { return }
            _ = save()
        }
    }
    private func statusText(_ status: AgentXRunStatus) -> String {
        switch status { case .running: "正在生成…"; case .cancelling: "正在取消…"; case .cancelled: "已取消"; case .failed: "生成失败"; case .completed: "运行结束（没有文本结果）" }
    }
    private func restore() {
        confirmingPublish = false
        cancelAutosave()
        _ = save()
        cache()
        message = ""; saveStatus = ""
        loadedAppID = controller.selectedAppID
        if let data = controller.characterEditorDrafts[loadedAppID], let draft = try? JSONDecoder().decode(EditorDraft.self, from: data) {
            dirty = true; instanceID = draft.instanceID; profile = draft.profile; baseDocument = draft.baseDocument
            scheduleAutosave()
        } else {
            dirty = false; instanceID = controller.currentInstance?.id ?? ""; load()
        }
    }
    private func load() {
        confirmingPublish = false
        cancelAutosave()
        message = ""; saveStatus = ""; baseDocument = nil
        guard let definition else { return }
        do {
            baseDocument = try definition.draft ?? definition.publishedDocument()
            profile = try controller.characterProfile(definitionID: definition.id)
            dirty = false
        } catch { message = error.localizedDescription }
    }
    private func cache() {
        guard dirty, !loadedAppID.isEmpty else { return }
        do { controller.characterEditorDrafts[loadedAppID] = try JSONEncoder().encode(EditorDraft(instanceID: instanceID, profile: profile, baseDocument: baseDocument)) }
        catch { message = error.localizedDescription }
    }
    @discardableResult private func save() -> Bool {
        cancelAutosave()
        guard instance?.appID == loadedAppID,
              let definition, let baseDocument else { return false }
        guard dirty else { return true }
        saveStatus = "正在保存草稿…"
        do {
            self.baseDocument = try controller.saveCharacterDraft(definitionID: definition.id, profile: profile, expectedDocument: baseDocument)
            dirty = false; controller.characterEditorDrafts.removeValue(forKey: loadedAppID); saveStatus = "草稿已保存；尚未发布。"; message = ""
            return true
        } catch { saveStatus = "保存失败，修改仍保留。请重试保存草稿。"; message = error.localizedDescription; cache(); return false }
    }
}
