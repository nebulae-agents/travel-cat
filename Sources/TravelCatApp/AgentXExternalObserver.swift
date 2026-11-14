import Foundation
import Combine

struct AgentXProbeFailure: Error { let reason: AgentXExternalProbeItem.Reason; init(_ reason: AgentXExternalProbeItem.Reason) { self.reason = reason } }

struct AgentXExternalProbeItem: Equatable, Identifiable, Sendable {
    enum Kind: String, Sendable { case native, docker, travel, pi, coverage, transport
        var title: String { switch self { case .native: "Codex 已连接会话"; case .docker: "已登记 Docker 容器"; case .travel: "旅行 CLI 子进程"; case .pi: "Pi 子进程"; case .coverage: "覆盖范围"; case .transport: "工作台连接" } }
        var coverage: String { switch self {
        case .native: "仅当前已连接的原生会话只读接口；不验证模型服务或认证。"
        case .docker: "仅当前工作台登记且身份核对一致的容器及其原 Docker 上下文；不扫描其他容器。"
        case .travel: "仅当前宿主登记的 CLI 根进程和已跟踪子进程；存活不等于引擎可用。"
        case .pi: "仅当前宿主内存中的 Pi 进程凭据；不读取往次会话账本，不验证模型服务。"
        case .coverage: "本轮有数量或时间上限，未覆盖对象不能据此推断状态。"
        case .transport: "仅现有工作台连接；未连接时不自动启动或重连。"
        } }
    }
    enum State: String, Sendable { case responsive, alive, exited, unknown, unobserved
        var title: String { switch self { case .responsive: "只读接口有响应"; case .alive: "所属进程存活"; case .exited: "已确认目标退出"; case .unknown: "未知"; case .unobserved: "未探测" } }
    }
    enum Reason: String, Sendable {
        case none, notConnected = "not_connected", busy, timeout, disconnected, permissionDenied = "permission_denied", identityMismatch = "identity_mismatch", invalidResponse = "invalid_response", unsupported, budgetExhausted = "budget_exhausted", coverageOmitted = "coverage_omitted", identityUnavailable = "identity_unavailable", noObjects = "no_registered_objects"
        var title: String { switch self {
        case .none: "无"; case .notConnected: "未连接"; case .busy: "读取被占用"; case .timeout: "探测超时"; case .disconnected: "传输断开"; case .permissionDenied: "读取权限不足"; case .identityMismatch: "对象身份不匹配"; case .invalidResponse: "响应不合法"; case .unsupported: "此范围尚不支持查询"; case .budgetExhausted: "本轮时间预算已用尽"; case .coverageOmitted: "部分对象超出本轮覆盖上限"; case .identityUnavailable: "缺少可验证的对象身份"; case .noObjects: "没有当前登记的目标"
        } }
    }
    var id: String
    var kind: Kind
    var state: State
    var reason: Reason
    var observedCount: Int? = nil
    static func decode(_ data: [String: Any]) throws -> [Self] {
        guard let rows = data["items"] as? [[String: Any]], !rows.isEmpty, rows.count <= 132 else { throw AgentXProbeFailure(.invalidResponse) }
        var ids = Set<String>()
        return try rows.map { row in
            guard let id = row["id"] as? String, !id.isEmpty, id.utf8.count <= 128, ids.insert(id).inserted,
                  let kind = Kind(rawValue: row["kind"] as? String ?? ""),
                  let state = State(rawValue: row["state"] as? String ?? ""),
                  let reason = Reason(rawValue: row["reason"] as? String ?? "") else { throw AgentXProbeFailure(.invalidResponse) }
            guard [.native, .docker, .coverage].contains(kind),
                  ![.responsive, .alive, .exited].contains(state) || reason == .none,
                  state != .responsive || kind == .native,
                  kind != .coverage || state == .unobserved else { throw AgentXProbeFailure(.invalidResponse) }
            return .init(id: id, kind: kind, state: state, reason: reason)
        }
    }
    static func process(_ sample: AgentXOwnedProcessSnapshot, kind: Kind) -> Self {
        let state: State = switch sample.state { case .alive: .alive; case .exited: .exited; case .unknown: .unknown; case .unobserved: .unobserved }
        let reason: Reason = switch sample.reason { case nil: .none; case .noRegisteredObjects: .noObjects; case .unsupported: .unsupported; case .busy: .busy; case .identityMismatch: .identityMismatch; case .partialIdentity: .identityUnavailable }
        return .init(id: kind.rawValue, kind: kind, state: state, reason: reason, observedCount: sample.observedCount)
    }
}

struct AgentXExternalProbeSample: Equatable {
    var started: Date
    var finished: Date?
    var lastSuccess: Date?
    var items: [AgentXExternalProbeItem]
    var refreshing: Bool
    var lastSuccessByID: [String: Date] = [:]
    func isStale(at date: Date) -> Bool { finished.map { date.timeIntervalSince($0) > 15 } ?? false }
}

/// Memory only; timed-out workers retain their slot until completion to prevent overlap.
@MainActor final class AgentXExternalObserver: ObservableObject {
    typealias Probe = @MainActor () async throws -> [AgentXExternalProbeItem]
    @Published private(set) var samples: [String: AgentXExternalProbeSample] = [:]
    private var workers: [String: Task<Void, Never>] = [:]
    private var timers: [String: Task<Void, Never>] = [:]
    private var tokens: [String: UUID] = [:]
    private var sessions: [String: UUID] = [:]
    private let timeout: Duration
    init(timeout: Duration = .seconds(3)) { self.timeout = timeout }
    func refresh(_ appID: String, generation: @escaping @MainActor () -> UUID?, connectionGeneration: @escaping @MainActor () -> UUID? = { nil }, probe: @escaping Probe) {
        guard workers[appID] == nil else { return }
        let token = UUID(), expected = generation(), expectedConnection = connectionGeneration(), started = Date()
        tokens[appID] = token
        let last = samples[appID]?.lastSuccess
        let previous = samples[appID]?.items ?? []
        let successes = samples[appID]?.lastSuccessByID ?? [:]
        func failureItems(_ reason: AgentXExternalProbeItem.Reason) -> [AgentXExternalProbeItem] {
            let items = previous.isEmpty ? [AgentXExternalProbeItem(id: "transport", kind: .transport, state: .unknown, reason: reason)] : previous
            return items.map { .init(id: $0.id, kind: $0.kind, state: [.notConnected, .unsupported].contains(reason) ? .unobserved : .unknown, reason: reason) }
        }
        samples[appID] = .init(started: started, finished: nil, lastSuccess: last, items: [], refreshing: true, lastSuccessByID: successes)
        timers[appID] = Task { [weak self, timeout] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, self.tokens[appID] == token else { return }
            self.tokens.removeValue(forKey: appID)
            guard expected == generation(), expectedConnection == connectionGeneration() else { self.samples.removeValue(forKey: appID); return }
            self.samples[appID] = .init(started: started, finished: .now, lastSuccess: last, items: failureItems(.timeout), refreshing: false, lastSuccessByID: successes)
        }
        workers[appID] = Task { [weak self] in
            let items: [AgentXExternalProbeItem]
            do { items = try await probe() }
            catch { items = failureItems((error as? AgentXProbeFailure)?.reason ?? .disconnected) }
            guard let self else { return }
            self.workers.removeValue(forKey: appID)
            self.timers.removeValue(forKey: appID)?.cancel()
            guard self.tokens[appID] == token else { return }
            self.tokens.removeValue(forKey: appID)
            guard expected == generation(), expectedConnection == connectionGeneration() else { self.samples.removeValue(forKey: appID); return }
            let finished = Date()
            var perObject = successes
            for item in items where [.responsive, .alive, .exited].contains(item.state) { perObject[item.id] = finished }
            // Retain only this round's objects; removed objects cannot accumulate indefinitely.
            perObject = perObject.filter { entry in items.contains { $0.id == entry.key } }
            let success = !items.isEmpty && items.allSatisfy { [.responsive, .alive, .exited].contains($0.state) }
            self.samples[appID] = .init(started: started, finished: finished, lastSuccess: success ? finished : last, items: items, refreshing: false, lastSuccessByID: perObject)
        }
    }
    func beginSession(_ appID: String) -> UUID {
        let id = UUID(); sessions[appID] = id; return id
    }
    func endSession(_ appID: String, id: UUID) {
        guard sessions[appID] == id else { return }
        sessions.removeValue(forKey: appID); close(appID)
    }
    func close(_ appID: String) {
        tokens.removeValue(forKey: appID)
        timers.removeValue(forKey: appID)?.cancel()
        // No transport shutdown or cancellation signal to the observed engine.
        samples.removeValue(forKey: appID)
    }
}

extension AgentXController {
    func refreshExternalObservation(for appID: String) {
        externalObserver.refresh(appID, generation: { [weak self] in
            guard let self, self.state.apps.contains(where: { $0.id == appID }) else { return UUID() }
            return self.externalRuntimeGeneration?(appID)
        }, connectionGeneration: { [weak self] in self?.externalRuntimeProbeGeneration?(appID) }) { [weak self] in
            guard let self, self.state.apps.contains(where: { $0.id == appID }) else { throw AgentXProbeFailure(.notConnected) }
            if let app = self.state.apps.first(where: { $0.id == appID }), app.kind == .chat {
                guard let owner = AgentXStopProcessIdentity.read(getpid()) else { throw AgentXProbeFailure(.identityUnavailable) }
                let runIDs = Set(self.state.runs.filter { $0.appID == appID }.map(\.id))
                return [.process(AgentXPiProcessLedger(root: self.repository.root).observeOwnedProcesses(owner: owner, runIDs: runIDs), kind: .pi)]
            }
            guard let probe = self.externalRuntimeProbe else { throw AgentXProbeFailure(.notConnected) }
            return try await probe(appID)
        }
    }
}
