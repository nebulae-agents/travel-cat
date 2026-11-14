import AppKit
import SwiftUI

@MainActor
struct AgentXExperienceFrontView: View {
    @ObservedObject var controller: AgentXController
    @Environment(\.undoManager) private var undoManager
    private var configuration: AgentXAppExperience { controller.currentApp?.experience?.published?.configuration ?? .init() }
    private var instance: AgentXInstance? { controller.currentInstance.map(controller.effectiveInstance) }
    private var latest: AgentXRun? { controller.state.runs.last { $0.appID == controller.selectedAppID && $0.instanceID == instance?.id && $0.purpose == nil } }
    private var input: Binding<String> {
        Binding(get: { controller.drafts[instance?.id ?? ""] ?? "" }, set: { controller.drafts[instance?.id ?? ""] = $0 })
    }
    private var choices: [String] { Array(configuration.choices.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.prefix(3)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ZStack(alignment: .topLeading) {
                GeometryReader { geometry in
                    if let url = Bundle.module.url(forResource: configuration.sceneTheme.rawValue, withExtension: "jpg", subdirectory: "AgentXScenes"), let art = NSImage(contentsOf: url) {
                        Image(nsImage: art).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped().accessibilityHidden(true)
                    }
                }
                LinearGradient(colors: [.black.opacity(0.12), .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Label(controller.currentApp?.experience?.published.map { "已发布 v\($0.number)" } ?? "尚未发布", systemImage: "checkmark.seal")
                        Spacer()
                        Label(latest?.displayedStatus ?? "等待你的行动", systemImage: "bubble.left")
                    }.font(.caption).padding(10).background(.black.opacity(0.45), in: Capsule())
                    Text(configuration.title.isEmpty ? controller.currentApp?.name ?? "场景" : configuration.title).font(.system(size: 30, weight: .semibold, design: .serif))
                    if !configuration.intro.isEmpty { Text(configuration.intro).font(.callout).lineLimit(5).textSelection(.enabled) }
                    Spacer(minLength: 80)
                    HStack(alignment: .bottom, spacing: 18) {
                        VStack(alignment: .leading, spacing: 12) {
                            Label(instance?.name ?? "当前场景", systemImage: "person.crop.circle.fill").font(.headline)
                            if let run = latest {
                                AgentXRunConfigurationLabel(run: run)
                                Text(run.response.isEmpty ? (run.failure ?? (run.status.terminal ? (run.status == .cancelled ? "已取消回应" : "运行结束，没有文本结果。") : "正在回应…")) : run.response).font(.system(.body, design: .serif)).textSelection(.enabled)
                                if !run.status.terminal { Button("取消本次回应") { controller.cancel(run.id) }.disabled(run.status == .cancelling) }
                            } else {
                                Text("选择一个行动，或写下你想说的话。").font(.system(.body, design: .serif))
                            }
                        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 14))
                        if !choices.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("接下来").font(.headline)
                                ForEach(Array(choices.enumerated()), id: \.offset) { _, choice in
                                    Button { choose(choice) } label: {
                                        HStack { Text(choice).multilineTextAlignment(.leading); Spacer(); Image(systemName: "arrow.down.left") }.padding(10).frame(minHeight: 44)
                                    }.buttonStyle(.plain).background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8)).disabled(instance == nil)
                                }
                                Text("选择后可修改，再发送。").font(.caption)
                            }.padding(16).frame(width: 230).background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 14))
                        }
                    }
                }.foregroundStyle(.white).padding(24)
            }.frame(minHeight: 440).clipShape(RoundedRectangle(cornerRadius: 18))
            if let instance {
                let reviewNotice = controller.pilotReviewNotice(for: instance.id)
                AgentXCard {
                    Picker("以谁的身份参与", selection: Binding(get: { instance.id }, set: { controller.selectedInstanceID = $0 })) {
                        ForEach(controller.currentInstances) { Text($0.name).tag($0.id) }
                    }
                    if let original = controller.currentInstance {
                        AgentXModelPicker(controller: controller, instance: original)
                        AgentXConfigurationSummaryView(controller: controller, instance: original)
                    }
                    TextEditor(text: input).frame(minHeight: 76, maxHeight: 130).scrollContentBackground(.hidden).accessibilityLabel("场景行动或对白")
                    HStack {
                        Button("撤回输入", systemImage: "arrow.uturn.backward") { undoManager?.undo() }
                            .disabled(undoManager?.canUndo != true).help("撤销刚才的输入编辑；不删除已发生的对话。")
                        Spacer()
                        Text(instance.model).font(.caption).foregroundStyle(AgentXTheme.muted)
                        Button("发送", systemImage: "arrow.up") { controller.send(input.wrappedValue, instanceID: instance.id) }
                            .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                            .disabled(input.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controller.isInstanceBusy(instance.id) || reviewNotice != nil)
                    }
                    if let reviewNotice { Text(reviewNotice).font(.caption).foregroundStyle(.orange) }
                    else if controller.isInstanceBusy(instance.id) { Text("该成员正在运行，完成或取消后可继续。").font(.caption).foregroundStyle(AgentXTheme.muted) }
                }
            } else {
                AgentXCard {
                    Text("场景已发布，添加成员后即可开始对话。")
                    Button("配置应用成员") { controller.navigate(to: .members) }
                }
            }
        }
    }
    private func choose(_ text: String) {
        guard let id = instance?.id else { return }
        let previous = controller.drafts[id] ?? ""
        undoManager?.registerUndo(withTarget: controller) { target in target.drafts[id] = previous }
        undoManager?.setActionName("选择行动")
        controller.drafts[id] = text
    }
}
