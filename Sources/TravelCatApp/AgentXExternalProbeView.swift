import SwiftUI

struct AgentXExternalProbeView: View {
    @ObservedObject var observer: AgentXExternalObserver
    let controller: AgentXController
    let appID: String
    @State private var session: UUID?
    var body: some View {
        GroupBox("外部运行器 · 只读实时探测") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("仅在详情打开时每 5 秒刷新 · 单轮限时 3 秒").font(.caption)
                    Spacer()
                    Button("立即探测") { controller.refreshExternalObservation(for: appID) }
                        .disabled(observer.samples[appID]?.refreshing == true)
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if let sample = observer.samples[appID] {
                        VStack(alignment: .leading, spacing: 6) {
                            if sample.refreshing { Text("正在只读探测…") }
                            if sample.isStale(at: context.date) { Text("探测结果已过期，请重新核验").foregroundStyle(.orange) }
                            Text("开始：\(sample.started.formatted(date: .omitted, time: .standard)) · 完成：\(sample.finished.map { $0.formatted(date: .omitted, time: .standard) } ?? "尚未完成")").font(.caption)

                            ForEach(sample.items) { item in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.kind.title + "：" + (sample.isStale(at: context.date) ? "已过期" : item.state.title))
                                    if let count = item.observedCount { Text("本轮核对进程数：\(count)").font(.caption) }
                                    Text("原因：" + item.reason.title).font(.caption)
                                    if let last = sample.lastSuccessByID[item.id] { Text("该目标最近成功：\(last.formatted(date: .omitted, time: .standard))（历史时间）").font(.caption) }
                                    Text("覆盖：" + item.kind.coverage).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } else { Text("未探测；不会自动启动或连接运行器。") }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: appID) {
            let id = observer.beginSession(appID)
            session = id
            while !Task.isCancelled {
                controller.refreshExternalObservation(for: appID)
                do { try await Task.sleep(for: .seconds(5)) } catch { break }
            }
            observer.endSession(appID, id: id)
        }
        .onDisappear { if let session { observer.endSession(appID, id: session) } }
    }
}
