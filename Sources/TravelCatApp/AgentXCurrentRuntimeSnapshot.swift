import Foundation

/// A read-only sample of this host's bookkeeping. Never inferred from stop receipts.
struct AgentXCurrentRuntimeSnapshot: Equatable {
    enum LocalWork: Equatable { case busy, idle, unobserved }
    var hostTaskCount: Int
    var localRuntimeWork: LocalWork
    var sampledAt: Date
    var hostTitle: String { "宿主文本任务：\(hostTaskCount) 个未结束" }
    var localTitle: String {
        switch localRuntimeWork {
        case .busy: "本机运行器：有所属工作"
        case .idle: "本机运行器：未发现所属工作"
        case .unobserved: "本机运行器：未接入观测"
        }
    }
    var externalStatus: String { "外部引擎：未探测" }
    var coverage: String {
        "仅观察本应用在当前宿主登记的任务与运行器工作，不验证外部引擎在线状态。未发现本机工作不代表引擎在线或已退出。"
    }
}

extension AgentXController {
    func currentRuntimeSnapshot(for appID: String, at date: Date = Date()) -> AgentXCurrentRuntimeSnapshot {
        let owned = externalRuntimeHasOwnedWork?(appID)
        return .init(hostTaskCount: state.runs.filter { $0.appID == appID && !$0.status.terminal }.count,
            localRuntimeWork: owned.map { $0 ? .busy : .idle } ?? .unobserved, sampledAt: date)
    }
}
