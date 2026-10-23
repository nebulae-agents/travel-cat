import Foundation
import CoreFoundation

@MainActor
extension AgentWorkbenchModel {
    func reconcileNativeHistory(_ id: UUID) async {
        guard !Task.isCancelled, !hasShutdown, nativeReconciliationRequests[id] == nil,
              let binding = nativeBackgroundBinding(id) else { return }
        let request = NativeBackgroundRequest(token: UUID(), binding: binding, visibilityToken: nil)
        nativeReconciliationRequests[id] = request
        nativeReconciliationNotices.removeValue(forKey: id)
        defer {
            if nativeReconciliationRequests[id]?.token == request.token { nativeReconciliationRequests.removeValue(forKey: id) }
        }
        do {
            let result = try await client.request("native_reconcile", ["taskId": id.uuidString], timeout: 15)
            guard reconciliationIsCurrent(id, request: request) else { return }
            guard result["threadId"] as? String == binding.threadID,
                  let turns = result["turns"] as? [[String: Any]], turns.count <= 4000,
                  let entries = result["items"] as? [[String: Any]], entries.count <= 4000,
                  JSONSerialization.isValidJSONObject(result),
                  let encoded = try? JSONSerialization.data(withJSONObject: result), encoded.count <= 8 * 1024 * 1024,
                  turns.allSatisfy({ validNativeIdentity($0["id"]) && ($0["threadId"] == nil || $0["threadId"] as? String == binding.threadID) }),
                  entries.allSatisfy({ entry in
                      guard validNativeIdentity(entry["turnId"]), entry["threadId"] == nil || entry["threadId"] as? String == binding.threadID,
                            let item = entry["item"] as? [String: Any] else { return false }
                      return validNativeIdentity(item["id"]) && validNativeIdentity(item["type"])
                  }),
                  Set(turns.compactMap { $0["id"] as? String }).count == turns.count,
                  Set(entries.compactMap { ($0["item"] as? [String: Any])?["id"] as? String }).count == entries.count else {
                throw WorkbenchFailure("官方执行记录未能核实。")
            }
            // Preserve original messages, process bodies, their order and the append-only audit.
            // A history read adds evidence only to an already observed process with the same turn.
            mutate(id) { task in
                for turn in turns {
                    if let turnID = turn["id"] as? String { task.nativeState?.recordTurnStatus(turnID, status: turn["status"] as? String) }
                }
                for entry in entries {
                    guard let item = entry["item"] as? [String: Any], let itemID = item["id"] as? String,
                          let index = task.nativeState?.items.firstIndex(where: { $0.id == itemID }),
                          let saved = task.nativeState?.items[index], saved.turnID == entry["turnId"] as? String,
                          saved.kind == item["type"] as? String, !saved.hasTerminalEvidence,
                          !["agentMessage", "userMessage", "reasoning"].contains(saved.kind) else { continue }
                    let status = item["status"] as? String
                    let explicitTerminal = NativeTimelineItem.terminalStatuses(for: saved.kind).contains(status ?? "")
                    let completionTime = validNativeCompletionTime(entry["completedAtMs"])
                    task.nativeState?.items[index].reconciledStatus = status ?? (completionTime && NativeTimelineItem.statuslessKinds.contains(saved.kind) ? "unknown" : nil)
                    task.nativeState?.items[index].completionObserved = explicitTerminal || completionTime && NativeTimelineItem.statuslessKinds.contains(saved.kind)
                }
                task.nativeState?.lastReconciledAt = Date()
            }
            try persistNative()
            nativeReconciliationNotices[id] = "已核对官方执行记录；缺少最终证据的项目仍待核对。"
        } catch {
            guard reconciliationIsCurrent(id, request: request) else { return }
            nativeReconciliationNotices[id] = "本次核对未确认，保留最后记录；可稍后重试。"
        }
    }

    private func reconciliationIsCurrent(_ id: UUID, request: NativeBackgroundRequest) -> Bool {
        !Task.isCancelled && !hasShutdown && nativeReconciliationRequests[id]?.token == request.token && request.binding == nativeBackgroundBinding(id)
    }

    private func validNativeIdentity(_ value: Any?) -> Bool {
        guard let text = value as? String else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= 512 && !text.contains("\0")
    }

    func validNativeCompletionTime(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        let timestamp = number.doubleValue
        return timestamp.isFinite && timestamp >= 0 && timestamp.rounded(.towardZero) == timestamp && timestamp <= Date().timeIntervalSince1970 * 1000
    }

    func nativeProcessStatusTitle(_ id: UUID, item: NativeTimelineItem, now: Date = Date()) -> String {
        if freshNativeBackgroundObservation(id, now: now)?.itemIDs.contains(item.id) == true { return "后台运行" }
        if item.hasTerminalEvidence {
            switch item.evidenceStatus {
            case "failed": return "失败"
            case "declined": return "已拒绝"
            case "interrupted": return "已取消"
            default: return "已完成"
            }
        }
        let task = state.tasks.first(where: { $0.id == id })
        let turnStatus = item.turnID.flatMap { task?.nativeState?.turnStatuses?[$0] }
        let isRunning = ["inProgress", "in_progress", "running"].contains(item.status)
        if isRunning, task?.nativeState?.turnID == item.turnID, task?.nativeState?.connection == .connected,
           task?.status.active == true, !NativeTaskState.terminalTurnStatuses.contains(turnStatus ?? "") { return "执行中" }
        switch item.status {
        case "inProgress", "in_progress", "running": return "待核对（最后记录：执行中）"
        case "completed": return "待核对（最后记录：已完成）"
        case "failed", "error": return "待核对（最后记录：失败）"
        case "declined": return "待核对（最后记录：已拒绝）"
        case "interrupted", "cancelled": return "待核对（最后记录：已取消）"
        default: return "待核对"
        }
    }
}
