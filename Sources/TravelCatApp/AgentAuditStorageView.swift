import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
struct AgentAuditStorageView: View {
    @ObservedObject var model: AgentWorkbenchModel
    let selectedTaskID: UUID?
    var embedded = false
    @Environment(\.dismiss) private var dismiss
    @State private var days = 0
    @State private var includeContents = false
    @State private var exportAll = true
    @State private var inventory: AgentAuditInventory?
    @State private var failure: String?
    @State private var preview: Cleanup?
    private struct Cleanup { let cutoff: Date; let count: Int; let head: String }

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("数据与审计").font(.title3.weight(.semibold)); Spacer(); if !embedded { Button("关闭") { dismiss() } } }
            Text("对话、实例配置和调用审计使用独立密钥加密保存在本机。旧对话仅在加密写入并读回验证后移除明文；系统快照和外部备份中的旧副本不在此清理范围内。").font(.caption).foregroundStyle(CottageTheme.mutedInk)
            if let inventory {
                Text("现存 \(inventory.records) 条 · \(ByteCountFormatter.string(fromByteCount: Int64(inventory.bytes), countStyle: .file)) · 已到期清理 \(inventory.retiredRecords) 条")
            }
            Text("审计上限 64 MiB / 4096 条，其中预留少量空间用于管理记录；容量不足会停止新调用。").font(.caption).foregroundStyle(CottageTheme.mutedInk)
            Divider()
            Text("日志保留").font(CottageTheme.heading)
            Picker("保留期限", selection: $days) {
                Text("不自动删除").tag(0)
                Text("7 天").tag(7)
                Text("30 天").tag(30)
                Text("90 天").tag(90)
            }.frame(maxWidth: 320)
            Text("保存后，在下次启动或结束全部会话时清理到期日志。清理仅移除连续到期的前缀，并保留可校验检查点；无法识别时间的记录会阻止继续向后清理。").font(.caption).foregroundStyle(CottageTheme.mutedInk)
            HStack {
                Button("保存保留策略") { run { try model.setAuditRetention(days: days == 0 ? nil : days); preview = nil } }
                Button("预览现在可清理的记录") { makePreview() }.disabled(days == 0)
            }.disabled(!model.canManageRetention)
            if !model.canManageRetention { Text("请结束全部会话后管理保留期限与清理；不会删除当前审批证据。").font(.caption).foregroundStyle(CottageTheme.terracotta) }
            if let preview {
                HStack {
                    Text("可清理 \(preview.count) 条；只保留检查点，删除的正文无法从应用恢复。本次手动清理不改变自动保留策略。")
                    Button("确认清理 \(preview.count) 条", role: .destructive) {
                        run { try model.pruneAudit(before: preview.cutoff, expectedHead: preview.head); self.preview = nil }
                    }.disabled(preview.count == 0 || !model.canManageRetention)
                }.font(.caption).padding(12).cottageCard(fill: CottageTheme.warningPaper, warning: true)
            }
            Divider()
            Text("审计导出").font(CottageTheme.heading)
            Picker("导出范围", selection: $exportAll) {
                Text("所有保留日志").tag(true)
                if selectedTaskID != nil { Text("打开面板时所选任务").tag(false) }
            }.frame(maxWidth: 320)
            Toggle("包含模型请求、返回与工具详情", isOn: $includeContents)
            Text(includeContents ? "将输出含正文的明文 JSON，可能包含代码、文件内容和个人资料。仅保存到你选择的位置，不自动上传。" : "默认只输出时间、标识、模型目的地、状态、内容摘要和数值用量，不包含请求正文、返回正文、工具参数和原始用量对象。").font(.caption).foregroundStyle(includeContents ? CottageTheme.terracotta : CottageTheme.mutedInk)
            Button(includeContents ? "选择位置并导出含正文日志…" : "选择位置并导出审计摘要…") { export() }
            if let notice = model.storageNotice { Text(notice).font(.caption).textSelection(.enabled) }
            if let failure { Text(failure).font(.caption).foregroundStyle(CottageTheme.terracotta).textSelection(.enabled) }
            Spacer(minLength: 0)
        }.padding(22)
        }
        .frame(minWidth: embedded ? 0 : 680, idealWidth: embedded ? nil : 760, minHeight: embedded ? 0 : 620)
        .workbenchSurface()
        .onAppear { reload(); days = model.state.auditRetentionDays ?? 0 }
        .onChange(of: days) { _, _ in preview = nil }
        .onChange(of: model.auditRevision) { _, _ in reload(); preview = nil }
    }
    private func reload() {
        do { inventory = try model.auditInventory() }
        catch { failure = error.localizedDescription }
    }
    private func run(_ action: () throws -> Void) {
        failure = nil
        do { try action(); reload() } catch { failure = error.localizedDescription }
    }
    private func makePreview() {
        run {
            guard [7, 30, 90].contains(days) else { return }
            let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
            let result = try model.retentionPreview(before: cutoff)
            preview = Cleanup(cutoff: cutoff, count: result.removableCount, head: result.head)
        }
    }
    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = includeContents ? "agent-audit-with-content.json" : "agent-audit-summary.json"
        panel.title = "保存明文审计导出"
        panel.message = includeContents ? "此文件包含请求、返回与工具详情，请确认保存位置的访问权限。" : "此文件包含审计摘要和模型目的地，不包含正文。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run { try model.exportAudit(taskID: exportAll ? nil : selectedTaskID, includeContents: includeContents, to: url) }
    }
}
