import SwiftUI

@MainActor
struct AgentXAssistantPanel: View {
    @ObservedObject var controller: AgentXController
    let isFront: Bool
    private var instance: AgentXInstance? { controller.currentInstance.map(controller.effectiveInstance) }
    private var input: Binding<String> {
        Binding(get: {
            isFront ? controller.usageAssistantInputs[controller.selectedAppID] ?? "" : controller.configurationInstructions[instance?.id ?? ""] ?? ""
        }, set: { value in
            if isFront { controller.usageAssistantInputs[controller.selectedAppID] = value }
            else { controller.configurationInstructions[instance?.id ?? ""] = value }
        })
    }
    private var unavailable: String? {
        if !controller.isLoaded { return "应用数据尚未加载完成。" }
        if controller.currentApp?.canRunHostText != true { return "此应用使用专用工作台，请进入后台查看可用能力。" }
        guard let instance else { return "先在后台添加成员，并连接模型服务，即可使用助手。" }
        if controller.isInstanceBusy(instance.id) { return "此成员正在运行，请等待完成或取消当前请求。" }
        return nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(isFront ? "使用助手" : "配置助手", systemImage: "sparkles").font(.title3.bold())
            Text(isFront ? "询问怎么使用当前应用，或让助手解释下一步。" : "描述角色职责、语气或人物设定的调整；建议需审阅后保存与发布。")
                .foregroundStyle(AgentXTheme.muted)
            if let instance {
                Picker("助手成员", selection: Binding(get: { instance.id }, set: { controller.selectedInstanceID = $0 })) {
                    ForEach(controller.currentInstances) { Text($0.name).tag($0.id) }
                }
                Text("使用 \(instance.model)").font(.caption).foregroundStyle(AgentXTheme.muted)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(controller.state.runs.filter { $0.appID == controller.selectedAppID && $0.purpose == (isFront ? .usageAssistant : .configuration) }) { run in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(run.prompt).fontWeight(.medium)
                            Text(run.status.label).font(.caption).foregroundStyle(AgentXTheme.muted)
                            if !run.response.isEmpty { Text(run.response).textSelection(.enabled) }
                            if let failure = run.failure { Text(failure).foregroundStyle(.red) }
                            if !run.status.terminal {
                                Button("取消请求") { controller.cancel(run.id) }.disabled(run.status == .cancelling)
                            }
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(AgentXTheme.background, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }.frame(maxHeight: 250)
            TextEditor(text: input).frame(height: 84).scrollContentBackground(.hidden)
                .padding(8).background(AgentXTheme.background, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel(isFront ? "向使用助手提问" : "向配置助手描述调整")
            if let unavailable { Text(unavailable).font(.caption).foregroundStyle(AgentXTheme.muted) }
            HStack {
                Button(isFront ? "打开后台" : "审阅配置建议") {
                    controller.assistantPresented = false
                    controller.navigate(to: .configuration)
                }
                Spacer()
                Button(isFront ? "发送" : "生成建议", systemImage: "arrow.up") {
                    guard let instance else { return }
                    if isFront { controller.sendUsageRequest(input.wrappedValue, instanceID: instance.id) }
                    else {
                        controller.sendConfigurationRequest(input.wrappedValue, instanceID: instance.id)
                        controller.assistantPresented = false
                        controller.navigate(to: .configuration)
                    }
                }.buttonStyle(.borderedProminent)
                    .disabled(unavailable != nil || input.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20)
    }
}
