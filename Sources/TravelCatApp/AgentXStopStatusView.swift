import AppKit
import SwiftUI

extension AgentXStopOperation {
    static func visibleFailure(_ failure: String?, operationID: UUID?, current: Self?) -> String? {
        guard let operationID, let current, current.id == operationID else { return failure }
        return current.status == .stopped && current.persistenceFailure == nil ? nil : failure
    }
    var pendingItemCount: Int { items.filter { $0.status != .confirmed }.count }
    var statusTitle: String {
        if persistenceFailure != nil { return "停止记录未保存 · 不可确认完成" }
        switch status {
        case .stopping: return "已禁止新任务 · 等待 \(pendingItemCount) 项停止"
        case .unverified: return "已禁止新任务 · \(pendingItemCount) 项停止未确认"
        case .stopped: return "已确认停止"
        }
    }
    /// Machine identifiers and fixed state values only; adapter errors may contain private data.
    var safeDiagnostic: String {
        (["operation=\(id.uuidString)", "app=\(appID)", "status=\(status.rawValue)",
          "saved=\(persistenceFailure == nil)"] + items.map { "item=\($0.id) kind=\($0.kind.rawValue) status=\($0.status.rawValue)" }).joined(separator: "\n")
    }
}

@MainActor
struct AgentXStopStatusButton: View {
    @ObservedObject var controller: AgentXController
    let appID: String
    var compactTitle: String? = nil
    @State private var showing = false
    var body: some View {
        Button { showing = true } label: {
            if let compactTitle { Text(compactTitle).font(.caption).frame(minHeight: 44) } else {
            TimelineView(.periodic(from: .now, by: 2)) { _ in
                let current = controller.currentRuntimeSnapshot(for: appID)
                VStack(alignment: .leading, spacing: 3) {
                    Text(current.hostTitle)
                    Text(current.localTitle).foregroundStyle(.secondary)
                    if let operation = controller.stopOperations[appID],
                       controller.state.apps.first(where: { $0.id == appID })?.enabled != true {
                        Text("最近停止：" + operation.statusTitle).foregroundStyle(.secondary)
                    }
                }.font(.caption).lineLimit(2)
            }
            }
        }.buttonStyle(.plain).help("任务与停止详情").accessibilityLabel("任务与停止详情")
            .sheet(isPresented: $showing) { AgentXStopStatusView(controller: controller, appID: appID) }
    }
}

@MainActor
struct AgentXStopStatusView: View {
    @ObservedObject var controller: AgentXController
    let appID: String
    @Environment(\.dismiss) private var dismiss
    @State private var checking = false
    @State private var failure: String?
    @State private var failureOperationID: UUID?
    private var operation: AgentXStopOperation? { controller.stopOperations[appID] }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("任务与停止详情 · \(controller.state.apps.first { $0.id == appID }?.name ?? appID)").font(.headline)
                Spacer(); Button("关闭") { dismiss() }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    TimelineView(.periodic(from: .now, by: 2)) { _ in
                        let current = controller.currentRuntimeSnapshot(for: appID)
                        GroupBox("当前运行状态 · 本机观测") {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(current.hostTitle)
                                Text(current.localTitle)
                                Text("外部运行器探测见下方独立结果").foregroundStyle(.secondary)
                                Text("本机采样时间：\(current.sampledAt.formatted(date: .omitted, time: .standard)) · 每 2 秒刷新")
                                    .font(.caption)
                                Text(current.coverage).font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    AgentXExternalProbeView(observer: controller.externalObserver, controller: controller, appID: appID)
                    Divider()
                    Text("最近一次停止记录").font(.headline)
                    Text("以下是当时的操作结果，不代表现在的运行状态；重新启用也不等于外部引擎在线。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let operation {
                        Text("记录状态：" + operation.statusTitle).font(.subheadline)
                        Text("操作：\(operation.id.uuidString)\n应用：\(appID)\n开始：\(operation.startedAt.formatted())\n更新：\(operation.updatedAt.formatted())")
                            .font(.caption).textSelection(.enabled)
                        if let warning = operation.persistenceFailure { Text(warning).foregroundStyle(.orange) }
                        ForEach(operation.items) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(item.kind == .task ? "宿主任务" : "运行器") · \(item.id)").font(.subheadline)
                                Text(item.status == .confirmed ? "已确认停止" : item.status == .waiting ? "正在等待停止确认" : "停止未确认")
                                    .foregroundStyle(item.status == .confirmed ? Color.secondary : Color.orange)
                                if let time = item.observedAt { Text("确认/检查时间：\(time.formatted())").font(.caption) }
                                if item.status != .confirmed, let detail = item.detail { Text(detail).font(.caption).textSelection(.enabled) }
                                if item.status != .confirmed { Text("不会将取消请求或等待超时当作已经退出。").font(.caption) }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        }
                    } else { Text("没有停止操作记录。") }
                    ForEach(controller.state.runs.filter { $0.appID == appID && !$0.status.terminal }) { run in
                        HStack { Text((run.revision == nil ? "宿主运行 " : "服务运行 ") + run.id).font(.caption); Spacer(); Text(run.displayedStatus) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let failure = AgentXStopOperation.visibleFailure(failure, operationID: failureOperationID, current: operation) { Text(failure).font(.caption).foregroundStyle(.orange) }
            HStack {
                if let operation {
                    Button("复制诊断") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(operation.safeDiagnostic, forType: .string) }
                    Spacer()
                    if controller.state.apps.first(where: { $0.id == appID })?.enabled != true,
                       operation.status != .stopped || operation.persistenceFailure != nil {
                        Button(checking ? "正在检查…" : "重试停止并核对结果") {
                            checking = true; failure = nil; failureOperationID = nil
                            Task { @MainActor in
                                defer { checking = false }
                                do { try await controller.setApplicationEnabled(appID, enabled: false) }
                                catch { failureOperationID = controller.stopOperations[appID]?.id; failure = "停止仍未确认，请查看逐项状态；系统继续收集结束证据。" }
                            }
                        }.disabled(checking)
                    }
                }
            }
        }.padding(20).frame(width: 650, height: 620)
    }
}
