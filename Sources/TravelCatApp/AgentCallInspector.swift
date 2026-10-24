import SwiftUI

@MainActor
struct AgentCallInspector: View {
    @ObservedObject var model: AgentWorkbenchModel
    let taskID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var records: [[String: Any]] = []
    @State private var deciding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("调用与审计 · \(model.state.tasks.first(where: { $0.id == taskID })?.title ?? "历史任务")").font(CottageTheme.title).lineLimit(2)
                Spacer()
                Button("关闭") { dismiss() }
            }
            Text("调用审计、任务对话与实例配置均加密保存在本机。未经过网关的外部调用不在此覆盖范围内。").font(.caption).foregroundStyle(CottageTheme.mutedInk)
            if let task = model.state.tasks.first(where: { $0.id == taskID }), task.nativeState != nil {
                Text("原生权限：所选工作目录与运行时工具审批。模型请求由官方 Codex 提交，不经过容器模型网关；这里记录收到的原生事件，断连期间可能存在审计缺口。").font(.caption)
                Text("Codex 自行保存登录和会话历史；工作台加密仅覆盖自身记录。").font(.caption).foregroundStyle(CottageTheme.mutedInk)
            } else {
                Text("权限：任务容器工作区与明确导入的文件；无宿主目录挂载。模型许可：\(model.state.tasks.first(where: { $0.id == taskID })?.modelPolicy == "task" ? "本任务持续授权" : "逐次确认")").font(.caption)
            }
            if let error = model.auditError { Text(error).foregroundStyle(CottageTheme.terracotta) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if records.isEmpty { Text("暂无受控调用记录。不会用对话文本推测模型提交内容或用量。").foregroundStyle(CottageTheme.mutedInk) }
                    ForEach(Array(records.enumerated()), id: \.offset) { _, record in
                        entry(record)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Token 与缓存按上游实报展示；未提供则显示未知。费用尚未接入价格表。操作日志中的 requested 只代表请求，不能作为成功凭据。").font(.caption).foregroundStyle(CottageTheme.mutedInk)
        }.padding(20).frame(minWidth: 700, idealWidth: 820, minHeight: 560, idealHeight: 680)
        .cottageSurface()
        .onAppear { reload() }
        .onChange(of: model.auditRevision) { _, _ in reload() }
    }

    @ViewBuilder private func entry(_ record: [String: Any]) -> some View {
        let kind = record["kind"] as? String ?? "unknown"
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title(kind)).font(CottageTheme.heading)
                Spacer()
                Text(record["timestamp"] as? String ?? "时间未知").font(.caption).foregroundStyle(CottageTheme.mutedInk)
            }
            if kind == "model.request" {
                Text(verbatim: "目的地：\(record["destination"] as? String ?? "未知")\n模型：\(record["model"] as? String ?? "未知") · 请求：\(record["bytes"] as? Int ?? 0) 字节").font(.caption).textSelection(.enabled)
                Text(verbatim: "SHA-256：\(record["requestHash"] as? String ?? "未知")").font(.caption.monospaced()).textSelection(.enabled)
                if record["bodyRedacted"] as? Bool == true {
                    Text("此请求预览已遮蔽已知凭据；SHA-256 与字节数对应实际发送内容，不能用遮蔽后的预览复算。").font(.caption).foregroundStyle(CottageTheme.terracotta)
                }
                DisclosureGroup(record["bodyRedacted"] as? Bool == true ? "提交内容（已遮蔽凭据）" : "完整提交内容（包含实际上下文与工具定义）") { payload(record["body"] as? String ?? "内容不可用") }
                if let call = record["callId"] as? String, let callID = UUID(uuidString: call),
                   let approval = model.modelApprovals.first(where: { $0.id == callID && $0.taskID == taskID }) {
                    HStack {
                        Button("拒绝本次") { decide(approval, allow: false) }
                        Button("允许发送本次内容") { decide(approval, allow: true) }
                    }.disabled(deciding || model.auditError != nil)
                    Text("授权绑定上面的请求摘要，内容变化需要重新确认。").font(.caption)
                }
            } else if kind == "model.response" {
                Text("返回片段 \(record["sequence"] as? Int ?? 0)").font(.caption)
                payload(record["text"] as? String ?? "")
            } else if kind == "model.completed" {
                let usage = record["usage"] as? [String: Any] ?? [:]
                Text("输入 \(metric(usage["totalInput"])) · 输出 \(metric(usage["output"])) · 缓存读取 \(metric(usage["cacheRead"])) · 缓存写入 \(metric(usage["cacheWrite"]))")
                Text("来源：\(usage["source"] as? String ?? "unknown") · 状态：\(String(describing: record["status"] ?? "未知")) · 完整返回：\((record["complete"] as? Bool == true) ? "是" : "未确认") · 费用：未知").font(.caption)
                DisclosureGroup("原始用量与完成记录") { payload(json(record)) }
            } else {
                payload(json(record))
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .cottageCard()
    }
    private func payload(_ value: String) -> some View {
        ScrollView([.horizontal, .vertical]) {
            Text(verbatim: value).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxHeight: 240).padding(8).cottageCard(fill: CottageTheme.paper)
    }
    private func title(_ kind: String) -> String {
        switch kind {
        case "model.request": "提交给模型"
        case "model.response": "模型返回"
        case "model.completed": "调用完成与用量"
        case "model.decision": "授权决定"
        case "model.failed": "调用失败"
        default: "操作记录 · \(kind)"
        }
    }
    private func metric(_ value: Any?) -> String { (value as? NSNumber)?.stringValue ?? "未知" }
    private func json(_ value: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])).flatMap { String(data: $0, encoding: .utf8) } ?? "记录格式不可显示"
    }
    private func reload() { records = model.auditRecords(taskID: taskID) }
    private func decide(_ request: WorkbenchModelApproval, allow: Bool) {
        deciding = true
        Task { await model.respondModel(request, allow: allow); deciding = false }
    }
}
