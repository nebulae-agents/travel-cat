import SwiftUI

@MainActor
struct AgentXModelPicker: View {
    @ObservedObject var controller: AgentXController
    let instance: AgentXInstance
    private var effective: AgentXInstance { controller.effectiveInstance(instance) }
    private var current: AgentXConversationModel { .init(providerID: effective.providerID, model: effective.model) }
    @State private var browsing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button { browsing = true } label: {
                HStack {
                    Image(systemName: "square.grid.2x2")
                    Text("下次请求模型：\(effective.model)").lineLimit(1)
                    Image(systemName: "chevron.down")
                }
            }.accessibilityLabel("下次请求模型")
            Text(controller.isInstanceBusy(instance.id) ? "停止当前请求后可切换模型。" : "切换后保留对话历史，下一次请求生效。")
                .font(.caption).foregroundStyle(AgentXTheme.muted)
        }.sheet(isPresented: $browsing) {
            VStack(alignment: .leading, spacing: 14) {
                HStack { Text("选择下次请求模型").font(.title2.bold()); Spacer(); Button("完成") { browsing = false }.keyboardShortcut(.cancelAction) }
                AgentXModelBrowser(providers: controller.state.providers, selected: current,
                    busy: controller.isInstanceBusy(instance.id), choose: { entry in
                        try controller.selectConversationModel(instanceID: instance.id, providerID: entry.providerID, model: entry.model.id)
                        browsing = false
                    }, favorite: { entry in
                        try controller.setModelFavorite(providerID: entry.providerID, modelID: entry.model.id, favorite: !entry.model.favorite)
                    })
            }.padding(20).frame(width: 740, height: 680)
                .background(AgentXTheme.background).preferredColorScheme(.dark)
        }
    }
}

struct AgentXCatalogModelDetails: View {
    let model: AgentXCatalogModel
    private func price(_ key: String) -> String {
        guard let raw = model.pricing?[key], let value = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")), value >= 0 else { return "未提供" }
        return "$" + NSDecimalNumber(decimal: value * 1_000_000).stringValue
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let name = model.name, name != model.id { Text(name).font(.caption) }
            HStack {
                if let length = model.contextLength { Text("上下文 \(length.formatted())") }
                if let modalities = model.inputModalities { Text("输入：" + modalities.joined(separator: "/")) }
                if let modalities = model.outputModalities { Text("输出：" + modalities.joined(separator: "/")) }
            }
            if model.pricing != nil { Text("每百万 token：输入 \(price("prompt")) · 输出 \(price("completion"))（美元基础价）") }
            if model.hasTieredPricing { Text("含阶梯或条件计费，实际费用以服务账单为准。") }
            if !model.available { Text("当前目录已不可用").foregroundStyle(.orange) }
            else if !model.supportsTextOutput { Text("不支持文本输出，不能用于当前对话。").foregroundStyle(.orange) }
        }.font(.caption2).foregroundStyle(AgentXTheme.muted)
    }
}
