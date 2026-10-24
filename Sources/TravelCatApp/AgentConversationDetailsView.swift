import SwiftUI

@MainActor
struct AgentConversationDetailsView: View {
    @ObservedObject var model: AgentWorkbenchModel
    let task: WorkbenchTask
    let close: () -> Void
    let audit: () -> Void
    @State private var page: Page = .process
    private enum Page: String, CaseIterable { case process = "运行过程", info = "会话信息", audit = "调用与审计" }
    private var instance: WorkbenchInstance? { model.state.instances.first { $0.id == task.instanceID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("对话详情").font(.headline); Spacer()
                Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.plain).help("关闭详情").accessibilityLabel("关闭详情")
            }
            Picker("详情分类", selection: $page) { ForEach(Page.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch page {
                    case .process: process
                    case .info: info
                    case .audit:
                        Text("查看当前对话的模型提交、工具操作与确认记录。").font(.callout)
                        Button("打开调用与审计…", action: audit)
                        Text("只展示实际收到的事件；断连期间的观测缺口会保留说明。").font(.caption).foregroundStyle(WorkbenchTheme.muted)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WorkbenchTheme.canvas).overlay(alignment: .leading) { Rectangle().fill(WorkbenchTheme.line).frame(width: 1) }
    }
    private var process: some View {
        VStack(alignment: .leading, spacing: 13) {
            let items = WorkbenchConversationPresentation.processItems(task)
            let messages = WorkbenchConversationPresentation.processMessages(task)
            if items.isEmpty && messages.isEmpty { Text("暂时没有工具过程记录。").font(.callout).foregroundStyle(WorkbenchTheme.muted) }
            ForEach(items) { item in
                DisclosureGroup {
                    if !item.detail.isEmpty {
                        ScrollView([.horizontal, .vertical]) { Text(verbatim: item.detail).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 220).padding(.top, 8)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title.isEmpty ? item.kind : item.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                        Text(statusTitle(item.status)).font(.system(size: 12)).foregroundStyle(WorkbenchTheme.muted)
                    }
                }
                Divider()
            }
            ForEach(messages) { message in Text(verbatim: message.text).font(.system(size: 12)).textSelection(.enabled); Divider() }
            if !items.isEmpty || !messages.isEmpty {
                Text("过程与正文分别显示，顺序以各自收到的记录为准。").font(.caption).foregroundStyle(WorkbenchTheme.muted)
            }
            Button("查看完整调用与审计…", action: audit).font(.caption)
        }
    }
    private var info: some View {
        VStack(alignment: .leading, spacing: 13) {
            LabeledContent("Agent", value: instance?.name ?? "已移除的 Agent")
            LabeledContent("本轮状态", value: task.status.title)
            if let native = task.nativeState {
                LabeledContent("连接", value: native.connection.title)
                if let configuration = instance?.native {
                    Text("工作目录").font(.caption).foregroundStyle(WorkbenchTheme.muted)
                    Text(verbatim: configuration.workspace).font(.system(size: 12)).textSelection(.enabled)
                }
                if let info = model.nativeConnections[task.instanceID] {
                    LabeledContent("官方账号", value: info.authenticated ? "已登录" : "未登录")
                    DisclosureGroup("运行时与能力") {
                        Text(verbatim: info.version).font(.caption).textSelection(.enabled)
                        Text(info.capabilities.filter { $0.value }.map(\.key).sorted().joined(separator: "、")).font(.caption).textSelection(.enabled)
                        if let thread = native.threadID { Text(verbatim: "会话：\(thread)").font(.caption.monospaced()).textSelection(.enabled) }
                    }
                }
                if let notice = native.historyNotice {
                    Text("最近核对记录").font(.caption).foregroundStyle(WorkbenchTheme.muted)
                    Text(verbatim: notice).font(.caption).textSelection(.enabled)
                }
                Text("工作台加密自身记录；Codex 独立管理其登录与会话。断开工作台连接不会自动停止后台任务。").font(.caption).foregroundStyle(WorkbenchTheme.muted)
            } else if let instance {
                LabeledContent("运行位置", value: instance.host.isEmpty ? "本机 Docker" : instance.host)
                LabeledContent("模型", value: instance.provider.model)
                Text(verbatim: instance.provider.baseURL).font(.caption).textSelection(.enabled)
                Text(task.modelPolicy == "task" ? "本任务持续允许向所选模型提交上下文。" : "模型请求按次确认。")
                    .font(.caption).foregroundStyle(WorkbenchTheme.muted)
            }
        }.font(.system(size: 12))
    }
    private func statusTitle(_ value: String) -> String {
        switch value { case "completed": "已完成"; case "inProgress", "in_progress", "running": "执行中"; case "failed", "error": "失败"; case "declined": "已拒绝"; case "interrupted", "cancelled": "已取消"; default: value.isEmpty ? "已记录" : value }
    }
}
