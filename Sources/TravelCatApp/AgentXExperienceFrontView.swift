import SwiftUI

@MainActor
struct AgentXExperienceFrontView: View {
    @ObservedObject var controller: AgentXController
    @Environment(\.undoManager) private var undoManager
    @State private var selectedChoice: String?
    private var configuration: AgentXAppExperience { controller.currentApp?.experience?.published?.configuration ?? .init() }
    private var instance: AgentXInstance? { controller.currentInstance.map(controller.effectiveInstance) }
    private var latest: AgentXRun? { controller.state.runs.last { $0.appID == controller.selectedAppID && $0.instanceID == instance?.id && $0.purpose == nil } }
    private var input: Binding<String> {
        Binding(get: { controller.drafts[instance?.id ?? ""] ?? "" }, set: { controller.drafts[instance?.id ?? ""] = $0; selectedChoice = nil })
    }
    private var choices: [String] { Array(configuration.choices.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.prefix(3)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text(configuration.title.isEmpty ? controller.currentApp?.name ?? "场景" : configuration.title)
                .font(.caption).foregroundStyle(AgentXTheme.muted).lineLimit(1)
            if !configuration.intro.isEmpty {
                Text(configuration.intro).font(.system(size: 17, design: .serif)).lineSpacing(8).textSelection(.enabled)
            }
            if let run = latest {
                Text(run.response.isEmpty ? (run.failure ?? (run.status.terminal ? (run.status == .cancelled ? "已取消回应" : "运行结束，没有文本结果。") : "正在回应…")) : run.response)
                    .font(.system(size: 17, design: .serif)).lineSpacing(8).textSelection(.enabled)
            }
            if !choices.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("轮到你了").font(.caption).foregroundStyle(AgentXTheme.muted)
                    ForEach(Array(choices.enumerated()), id: \.offset) { _, choice in
                        Button { choose(choice) } label: {
                            Text(choice).multilineTextAlignment(.leading).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 4)
                        }.buttonStyle(.plain)
                            .background(selectedChoice == choice ? AgentXTheme.accent.opacity(0.14) : AgentXTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selectedChoice == choice ? AgentXTheme.accent : AgentXTheme.border))
                            .accessibilityAddTraits(selectedChoice == choice ? .isSelected : [])
                            .disabled(instance == nil)
                    }
                }
            }
            if let instance {
                let reviewNotice = controller.pilotReviewNotice(for: instance.id)
                HStack(spacing: 8) {
                    TextField("或者，写下你想说的话", text: input, axis: .vertical)
                        .lineLimit(1...5).textFieldStyle(.plain).frame(minHeight: 44).accessibilityLabel("场景行动或对白")
                    Button { controller.send(input.wrappedValue, instanceID: instance.id); selectedChoice = nil } label: {
                        Image(systemName: "arrow.up").frame(width: 44, height: 44)
                    }.buttonStyle(.borderedProminent).help("发送 ⌘Return").accessibilityLabel("发送")
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(input.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controller.isInstanceBusy(instance.id) || reviewNotice != nil)
                }.padding(6).padding(.leading, 10).background(AgentXTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(AgentXTheme.border))
                if let reviewNotice { Text(reviewNotice).font(.caption).foregroundStyle(.orange) }
            } else {
                Text("添加成员后即可开始对话。")
                Button("配置应用成员") { controller.navigate(to: .members) }.frame(minHeight: 44)
            }
            HStack(spacing: 20) {
                Text("⌘K 切换应用")
                Text("⌘Z 撤回上一步").help("撤销输入编辑；不删除已发生的对话。")
                Text("⌘, 设置")
            }.font(.caption).foregroundStyle(AgentXTheme.muted).frame(maxWidth: .infinity)
        }.frame(maxWidth: 680).frame(maxWidth: .infinity)
            .onChange(of: input.wrappedValue) { _, value in if selectedChoice != value { selectedChoice = nil } }
    }
    private func choose(_ text: String) {
        guard let id = instance?.id else { return }
        let previous = controller.drafts[id] ?? ""
        undoManager?.registerUndo(withTarget: controller) { target in target.drafts[id] = previous }
        undoManager?.setActionName("选择行动")
        controller.drafts[id] = text
        selectedChoice = text
    }
}
