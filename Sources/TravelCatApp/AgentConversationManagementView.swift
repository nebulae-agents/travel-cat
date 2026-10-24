import SwiftUI

@MainActor
struct AgentConversationManagementMenu: View {
    @ObservedObject var model: AgentWorkbenchModel
    @ObservedObject var presentation: AgentWorkbenchPresentation
    let task: WorkbenchTask
    @State private var showingRename = false
    private var archived: Bool { WorkbenchConversationPresentation.isArchived(task, pendingTaskIDs: model.pendingConversationTaskIDs) }
    var body: some View {
        Menu {
            Button("重命名…") { showingRename = true }
            Button(task.pinnedAt == nil ? "置顶对话" : "取消置顶") {
                perform { try model.setConversationPinned(task.id, pinned: task.pinnedAt == nil) }
            }
            Divider()
            if archived {
                Button("恢复到对话列表") {
                    perform { try model.setConversationArchived(task.id, archived: false); presentation.scope = .active }
                }
            } else {
                let reason = model.archiveBlockReason(task.id)
                Button("归档对话") {
                    perform { try model.setConversationArchived(task.id, archived: true); presentation.scope = .archived }
                }.disabled(reason != nil)
                if let reason { Text(reason) }
            }
        } label: { Image(systemName: "archivebox").frame(width: 20, height: 24) }
        .menuStyle(.borderlessButton).fixedSize().help("管理对话").accessibilityLabel("管理对话")
        .sheet(isPresented: $showingRename) { AgentConversationRenameView(model: model, task: task) }
    }
    private func perform(_ operation: () throws -> Void) {
        do { try operation() } catch { model.error = error.localizedDescription }
    }
}

@MainActor
private struct AgentConversationRenameView: View {
    @ObservedObject var model: AgentWorkbenchModel
    let task: WorkbenchTask
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var failure: String?
    init(model: AgentWorkbenchModel, task: WorkbenchTask) {
        self.model = model; self.task = task
        _title = State(initialValue: task.customTitle ?? "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("重命名对话").font(.headline)
            TextField("自定义名称（留空恢复原始标题）", text: $title).textFieldStyle(.roundedBorder)
                .onSubmit { save(title) }.accessibilityLabel("对话名称")
            Text("最多 160 个字符，单行文字。原始标题、问题和回复会完整保留。")
                .font(.caption).foregroundStyle(WorkbenchTheme.muted)
            if let failure { Text(failure).font(.callout).foregroundStyle(CottageTheme.terracotta).textSelection(.enabled) }
            HStack {
                Button("恢复原始标题") { save(nil) }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { save(title) }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 460).workbenchSurface()
    }
    private func save(_ value: String?) {
        do { try model.renameConversation(task.id, title: value); dismiss() }
        catch { failure = error.localizedDescription }
    }
}
