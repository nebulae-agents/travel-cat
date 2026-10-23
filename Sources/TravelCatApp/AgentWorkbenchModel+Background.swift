import Foundation
import CoreFoundation

@MainActor
extension AgentWorkbenchModel {
    func nativeBackgroundBinding(_ id: UUID) -> NativeBackgroundBinding? {
        guard isStorageReady, liveTasks.contains(id), !nativeRecovering.contains(id), !nativeDetaching.contains(id),
              !nativeInterruptPending.contains(id), !nativeBackgroundStopping.contains(id),
              let task = state.tasks.first(where: { $0.id == id }), let native = task.nativeState,
              native.connection == .connected, let thread = native.threadID, !thread.isEmpty else { return nil }
        return .init(taskID: id, instanceID: task.instanceID, executionID: native.executionID, threadID: thread,
                     turnID: native.turnID, operationID: native.pendingOperation?.id,
                     connectionGeneration: nativeConnectionGenerations[task.instanceID], revision: nativeBackgroundRevisions[id])
    }

    /// Consumers must use this accessor rather than treating a historical count as current.
    func freshNativeBackgroundObservation(_ id: UUID, now: Date = Date()) -> NativeBackgroundObservation? {
        guard let observation = nativeBackgroundObservations[id], observation.binding == nativeBackgroundBinding(id),
              (0...10).contains(now.timeIntervalSince(observation.checkedAt)) else { return nil }
        return observation
    }

    func nativeBackgroundStatusTitle(_ id: UUID, now: Date = Date()) -> String {
        if let request = nativeBackgroundRequests[id], request.binding == nativeBackgroundBinding(id) { return "正在核对…" }
        if let pending = nativeBackgroundPendingRefreshes[id], pending.binding == nativeBackgroundBinding(id),
           nativeBackgroundVisibility[id] == pending.visibilityToken { return "正在核对…" }
        if let observation = freshNativeBackgroundObservation(id, now: now) { return "后台命令：\(observation.count) 个" }
        return "后台命令待核对"
    }

    func invalidateNativeBackgroundStatus(_ id: UUID) {
        nativeBackgroundRevisions[id] = UUID()
        nativeBackgroundObservations.removeValue(forKey: id)
        nativeBackgroundPendingRefreshes.removeValue(forKey: id)?.continuation.resume()
        // Keep an outstanding request registered until it returns, so a second caller cannot overlap it.
    }

    func invalidateAllNativeBackgroundStatus() {
        for id in Set(nativeBackgroundObservations.keys).union(nativeBackgroundRequests.keys).union(nativeBackgroundVisibility.keys).union(nativeBackgroundPendingRefreshes.keys) {
            invalidateNativeBackgroundStatus(id)
        }
    }

    func canStopNativeBackgroundTasks(_ id: UUID) -> Bool {
        nativeBackgroundBinding(id) != nil && state.tasks.first(where: { $0.id == id }).map {
            [.completed, .cancelled, .failed].contains($0.status)
        } == true
    }

    func refreshNativeBackgroundStatus(_ id: UUID, visibilityToken: UUID? = nil) async {
        guard !Task.isCancelled,
              visibilityToken == nil || nativeBackgroundVisibility[id] == visibilityToken && selectedTaskID == id,
              let binding = nativeBackgroundBinding(id) else { return }
        if let outstanding = nativeBackgroundRequests[id] {
            // A completion or new view can need a current read while an old runtime ignores cancellation.
            // The visible caller waits for that IPC slot, then rechecks its own cancellation and binding.
            guard let visibilityToken,
                  outstanding.binding != binding || outstanding.visibilityToken != visibilityToken else { return }
            await waitForNativeBackgroundSlot(id, binding: binding, visibilityToken: visibilityToken)
            guard !Task.isCancelled, nativeBackgroundRequests[id] == nil, binding == nativeBackgroundBinding(id),
                  nativeBackgroundVisibility[id] == visibilityToken, selectedTaskID == id else { return }
        }
        let request = NativeBackgroundRequest(token: UUID(), binding: binding, visibilityToken: visibilityToken)
        nativeBackgroundRequests[id] = request
        defer {
            if nativeBackgroundRequests[id]?.token == request.token {
                nativeBackgroundRequests.removeValue(forKey: id)
                nativeBackgroundPendingRefreshes.removeValue(forKey: id)?.continuation.resume()
            }
        }
        do {
            let result = try await client.request("native_background_status", ["taskId": id.uuidString], timeout: 15)
            guard backgroundRequestIsCurrent(id, request: request) else { return }
            guard result["threadId"] as? String == binding.threadID,
                  let count = result["count"] as? Int, let number = result["count"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue == Double(count), (0...256).contains(count),
                  let itemIDs = result["itemIds"] as? [String], itemIDs.count == count, Set(itemIDs).count == count,
                  itemIDs.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 512 && !$0.contains("\0") }) else {
                throw WorkbenchFailure("后台命令状态尚未核实。")
            }
            nativeBackgroundObservations[id] = .init(count: count, itemIDs: itemIDs, checkedAt: Date(), requestToken: request.token, binding: binding)
        } catch {
            guard backgroundRequestIsCurrent(id, request: request) else { return }
            // A failed read cannot change a completed turn or claim that commands have stopped.
            nativeBackgroundObservations.removeValue(forKey: id)
        }
    }

    private func waitForNativeBackgroundSlot(_ id: UUID, binding: NativeBackgroundBinding, visibilityToken: UUID) async {
        let token = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(); return }
                let pending = NativeBackgroundPendingRefresh(token: token, binding: binding, visibilityToken: visibilityToken, continuation: continuation)
                let superseded = nativeBackgroundPendingRefreshes.updateValue(pending, forKey: id)
                superseded?.continuation.resume()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.nativeBackgroundPendingRefreshes[id]?.token == token else { return }
                self.nativeBackgroundPendingRefreshes.removeValue(forKey: id)?.continuation.resume()
            }
        }
    }

    private func backgroundRequestIsCurrent(_ id: UUID, request: NativeBackgroundRequest) -> Bool {
        !Task.isCancelled && nativeBackgroundRequests[id]?.token == request.token && request.binding == nativeBackgroundBinding(id) &&
        (request.visibilityToken == nil || nativeBackgroundVisibility[id] == request.visibilityToken && selectedTaskID == id)
    }

    @discardableResult
    func beginNativeBackgroundObservation(_ id: UUID, token: UUID = UUID()) -> UUID {
        invalidateNativeBackgroundStatus(id)
        nativeBackgroundVisibility[id] = token
        return token
    }

    func endNativeBackgroundObservation(_ id: UUID, token: UUID) {
        guard nativeBackgroundVisibility[id] == token else { return }
        nativeBackgroundVisibility.removeValue(forKey: id)
        invalidateNativeBackgroundStatus(id)
    }

    /// Owned by SwiftUI's visible conversation task; no timer or automation survives the view.
    func observeNativeBackgroundStatus(_ id: UUID, token: UUID = UUID()) async {
        guard !Task.isCancelled, selectedTaskID == id, !hasShutdown else { return }
        beginNativeBackgroundObservation(id, token: token)
        defer { endNativeBackgroundObservation(id, token: token) }
        while !Task.isCancelled, nativeBackgroundVisibility[id] == token, selectedTaskID == id, !hasShutdown {
            await refreshNativeBackgroundStatus(id, visibilityToken: token)
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
        }
    }
}
