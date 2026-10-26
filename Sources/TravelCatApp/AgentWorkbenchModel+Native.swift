import Foundation

@MainActor
extension AgentWorkbenchModel {
    func connectNative(instance: WorkbenchInstance) async throws -> NativeConnectionInfo {
        guard let configuration = instance.native, isStorageReady else { throw WorkbenchFailure("原生实例配置无效。") }
        try configuration.validate(requireModel: false)
        guard !nativeBusy.contains(instance.id) else { throw WorkbenchFailure("正在连接，请稍候。") }
        nativeConnectionGenerations[instance.id] = UUID()
        for task in state.tasks where task.instanceID == instance.id { invalidateNativeBackgroundStatus(task.id) }
        nativeBusy.insert(instance.id); defer { nativeBusy.remove(instance.id) }
        try managementRecord("native.connect", fields: ["instanceId": instance.id.uuidString, "phase": "requested"])
        try client.launch(python: state.pythonPath)
        let profile = store.root.appendingPathComponent("native-runtime").appendingPathComponent(instance.id.uuidString)
        let result = try await client.request("native_connect", ["instanceId": instance.id.uuidString,
            "executable": configuration.executable, "workspace": configuration.workspace, "profileRoot": profile.path], timeout: 60)
        let info = try NativeConnectionInfo.decode(result)
        nativeConnections[instance.id] = info
        nativeNotice = info.authenticated ? "官方账号已连接。" : "请使用官方登录，再重新检测账号与模型。"
        return info
    }

    func loginNative(instance: WorkbenchInstance) async throws -> URL {
        guard nativeConnections[instance.id] != nil else { throw WorkbenchFailure("请先连接 Codex。") }
        try managementRecord("native.login", fields: ["instanceId": instance.id.uuidString, "phase": "requested"])
        let result = try await client.request("native_login", ["instanceId": instance.id.uuidString])
        guard let id = result["loginId"] as? String, let address = result["authUrl"] as? String,
              let url = URL(string: address), url.scheme == "https",
              let host = url.host, ["auth.openai.com", "auth.chatgpt.com"].contains(host), url.user == nil, url.password == nil, url.port == nil || url.port == 443 else {
            throw WorkbenchFailure("官方登录地址未确认。")
        }
        nativeLoginIDs[instance.id] = id
        return url
    }

    func cancelNativeLogin(instanceID: UUID) async {
        guard isStorageReady else { return }
        guard let id = nativeLoginIDs[instanceID] else { return }
        do {
            _ = try await client.request("native_login_cancel", ["instanceId": instanceID.uuidString, "loginId": id])
            nativeLoginIDs.removeValue(forKey: instanceID)
        } catch { self.error = "登录取消未确认，请稍后重新检测账号。" }
    }

    func nativeRecord(_ id: UUID, kind: String, fields: [String: Any] = [:]) throws {
        guard auditError == nil, let auditStore, isStorageReady else { throw WorkbenchFailure("安全审计不可用，操作未发送。") }
        var record = fields
        record["eventId"] = UUID().uuidString; record["taskId"] = id.uuidString
        record["kind"] = kind; record["timestamp"] = ISO8601DateFormatter().string(from: Date())
        do { try auditStore.append(record: record); auditRevision += 1 }
        catch { auditError = "审计保存失败，后续提交和授权已阻止。"; throw error }
    }

    func persistNative() throws {
        guard isStorageReady else { throw WorkbenchFailure("原数据未能读取，禁止覆盖。") }
        try store.save(state)
    }

    func nativeIntent(_ id: UUID, kind: NativeOperation.Kind, target: String, fields: [String: Any] = [:]) throws {
        invalidateArtifactReads(id)
        invalidateNativeBackgroundStatus(id)
        let operation = NativeOperation(kind: kind, targetID: target)
        var details = fields; details["operationId"] = operation.id.uuidString; details["targetId"] = target
        try nativeRecord(id, kind: "native.\(kind.rawValue).requested", fields: details)
        mutate(id) { $0.nativeState?.pendingOperation = operation }
        try persistNative()
    }

    func startNative(instance: WorkbenchInstance, text: String, instruction: String, files: [[String: String]], parentTaskID: UUID?, onStarted: (@MainActor () -> Void)?) async throws {
        try instance.validate()
        guard files.isEmpty else { throw WorkbenchFailure("原生任务请在选定工作目录中准备文件，再在任务正文中引用路径。") }
        let info = try await connectNative(instance: instance)
        try Task.checkCancellation()
        try requireStorageReady()
        guard state.instances.first(where: { $0.id == instance.id }) == instance else {
            throw WorkbenchFailure("Agent 配置已变更或已删除，请确认当前配置后重试；草稿已保留。")
        }
        guard info.authenticated, let config = instance.native,
              info.models.contains(where: { $0.model == config.model }) else { throw WorkbenchFailure("请先完成官方登录，并在实例设置中选择当前可用模型。") }
        var task = WorkbenchTask(instanceID: instance.id, title: String(text.prefix(64)))
        task.parentTaskID = parentTaskID; task.nativeState = NativeTaskState()
        task.messages.append(.init(role: "user", text: text))
        state.tasks.insert(task, at: 0); preferredInstanceID = instance.id; selectedTaskID = task.id
        do {
            try nativeIntent(task.id, kind: .start, target: instance.id.uuidString)
            liveTasks.insert(task.id)
            let result = try await client.request("native_start", ["instanceId": instance.id.uuidString, "taskId": task.id.uuidString, "model": config.model], timeout: 90)
            guard let thread = result["threadId"] as? String, !thread.isEmpty else { throw WorkbenchFailure("会话启动结果未知，请核对后恢复；不会重发任务。") }
            mutate(task.id) {
                $0.sessionID = thread; $0.nativeState?.threadID = thread; $0.nativeState?.connection = .connected
                $0.nativeState?.pendingOperation?.status = .confirmed
            }
            try persistNative()
            try await promptNative(task.id, text: instruction, addUserMessage: false)
            onStarted?()
        } catch { nativeFailure(task.id, error); throw error }
    }

    func promptNative(_ id: UUID, text: String, addUserMessage: Bool) async throws {
        guard let task = state.tasks.first(where: { $0.id == id }), liveTasks.contains(id),
              task.nativeState?.connection == .connected, let thread = task.nativeState?.threadID else { throw WorkbenchFailure("请先恢复并核对会话。") }
        let messageID = UUID().uuidString
        try nativeIntent(id, kind: .prompt, target: thread, fields: ["clientUserMessageId": messageID, "text": text])
        mutate(id) {
            $0.status = .running; $0.nativeState?.turnID = nil; $0.unread = false
            $0.nativeState?.historyNotice = nil
            if addUserMessage { $0.messages.append(.init(role: "user", text: text)) }
        }
        try persistNative()
        let result = try await client.request("native_prompt", ["taskId": id.uuidString, "text": text, "clientUserMessageId": messageID], timeout: 90)
        guard let turn = result["turnId"] as? String, !turn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WorkbenchFailure("本轮提交结果未知，不会自动重发。") }
        mutate(id) {
            // Completion notifications may arrive before the start response.
            if $0.nativeState?.turnID == nil && !NativeTaskState.terminalTurnStatuses.contains($0.nativeState?.turnStatuses?[turn] ?? "") { $0.nativeState?.turnID = turn }
            if $0.nativeState?.pendingOperation?.kind == .prompt && $0.nativeState?.pendingOperation?.status == .requested {
                $0.nativeState?.pendingOperation?.status = .accepted
            }
        }
        try persistNative()
    }

    func nativeFailure(_ id: UUID, _ failure: Error) {
        mutate(id) {
            $0.status = .unknown; $0.unread = true
            $0.nativeState?.pendingOperation?.status = .unknown
            $0.nativeState?.historyNotice = "操作结果待核实；恢复只核对官方会话，不会重发正文。"
            $0.messages.append(.init(role: "system", text: failure.localizedDescription))
        }
        permissions.removeAll { $0.taskID == id }; persist()
    }

    private func nativeControlIsCurrent(_ id: UUID, operationID: UUID?) -> Bool {
        operationID == nil || state.tasks.first(where: { $0.id == id })?.nativeState?.pendingOperation?.id == operationID
    }

    func cancelNative(_ id: UUID) async {
        guard isStorageReady else { return }
        guard !nativeInterruptPending.contains(id), !nativeRecovering.contains(id), !nativeDetaching.contains(id), let task = state.tasks.first(where: { $0.id == id }), task.status.active,
              let turn = task.nativeState?.turnID, liveTasks.contains(id) else { return }
        var controlID: UUID?
        defer { if nativeControlIsCurrent(id, operationID: controlID) { nativeInterruptPending.remove(id) } }
        do {
            try nativeIntent(id, kind: .interrupt, target: turn)
            controlID = state.tasks.first(where: { $0.id == id })?.nativeState?.pendingOperation?.id
            mutate(id) { $0.status = .cancelling }; try persistNative()
            nativeInterruptPending.insert(id)
            permissions.removeAll { $0.taskID == id }
            let result = try await client.request("native_cancel", ["taskId": id.uuidString, "turnId": turn], timeout: 60)
            guard nativeControlIsCurrent(id, operationID: controlID) else { return }
            guard result["backgroundStopped"] as? Bool == true else { throw WorkbenchFailure("模型轮次已请求中断，但后台命令停止尚未确认；请恢复核对。") }
            try nativeRecord(id, kind: "native.interrupt.cleanupConfirmed", fields: ["turnId": turn, "terminatedCount": result["terminatedCount"] as? Int ?? 0])
            nativeInterruptPending.remove(id); nativeInterruptUnverified.remove(id)
            mutate(id) {
                if $0.nativeState?.pendingOperation?.status == .requested { $0.nativeState?.pendingOperation?.status = .accepted }
                $0.nativeState?.historyNotice = "已核对该会话后台命令全部停止；轮次状态以官方完成事件为准。"
            }
            if let completed = nativeInterruptEvents.removeValue(forKey: id) { receiveNative(completed) }
            try persistNative()
        } catch {
            guard nativeControlIsCurrent(id, operationID: controlID) else { return }
            nativeInterruptUnverified.insert(id); nativeFailure(id, error)
        }
    }

    func stopNativeBackgroundTasks(_ id: UUID) async {
        guard isStorageReady else { return }
        guard canStopNativeBackgroundTasks(id),
              let thread = state.tasks.first(where: { $0.id == id })?.nativeState?.threadID else { return }
        var controlID: UUID?
        nativeBackgroundStopping.insert(id)
        defer { if nativeControlIsCurrent(id, operationID: controlID) { nativeBackgroundStopping.remove(id) } }
        do {
            try nativeIntent(id, kind: .interrupt, target: thread, fields: ["scope": "backgroundTerminals"])
            controlID = state.tasks.first(where: { $0.id == id })?.nativeState?.pendingOperation?.id
            let result = try await client.request("native_background_stop", ["taskId": id.uuidString], timeout: 60)
            guard nativeControlIsCurrent(id, operationID: controlID) else { return }
            guard result["stopped"] as? Bool == true else { throw WorkbenchFailure("后台命令停止尚未确认，请恢复会话后核对。") }
            let count = result["terminatedCount"] as? Int ?? 0
            try nativeRecord(id, kind: "native.backgroundStop.confirmed", fields: ["threadId": thread, "terminatedCount": count])
            mutate(id) {
                $0.nativeState?.pendingOperation?.status = .confirmed
                $0.nativeState?.historyNotice = "本次已停止 \(count) 个后台命令；停止操作完成时已确认该会话无运行中的后台命令。"
            }
            nativeInterruptUnverified.remove(id)
            if let completed = nativeInterruptEvents.removeValue(forKey: id) { receiveNative(completed) }
            try persistNative()
        } catch {
            guard nativeControlIsCurrent(id, operationID: controlID) else { return }
            nativeFailure(id, error)
        }
        nativeBackgroundStopping.remove(id)
        await reconcileNativeHistory(id)
    }

    func detachNative(_ id: UUID) async {
        guard isStorageReady else { return }
        guard !nativeDetaching.contains(id), !nativeRecovering.contains(id), !nativeInterruptPending.contains(id), !nativeBackgroundStopping.contains(id) else { return }
        nativeDetaching.insert(id); defer { nativeDetaching.remove(id) }
        var controlID: UUID?
        do {
            try nativeIntent(id, kind: .detach, target: id.uuidString)
            controlID = state.tasks.first(where: { $0.id == id })?.nativeState?.pendingOperation?.id
            nativeInterruptPending.remove(id); nativeInterruptUnverified.remove(id); nativeInterruptEvents.removeValue(forKey: id)
            nativeBackgroundStopping.remove(id)
            liveTasks.remove(id); permissions.removeAll { $0.taskID == id }
            mutate(id) {
                $0.nativeState?.connection = .disconnected
                if $0.status.active { $0.status = .unknown }
            }
            try persistNative()
            _ = try await client.request("native_detach", ["taskId": id.uuidString])
            guard nativeControlIsCurrent(id, operationID: controlID) else { return }
            liveTasks.remove(id); permissions.removeAll { $0.taskID == id }
            mutate(id) {
                $0.nativeState?.connection = .disconnected; $0.nativeState?.pendingOperation?.status = .confirmed
                if $0.status.active { $0.status = .unknown }
                $0.nativeState?.historyNotice = "已断开观察连接。原生运行时可能仍在执行，可恢复核对。"
            }
            try persistNative()
        } catch {
            guard nativeControlIsCurrent(id, operationID: controlID) else { return }
            nativeFailure(id, error)
        }
    }

    func respondNative(_ request: WorkbenchPermission, option: WorkbenchPermission.Option) async {
        guard isStorageReady else { return }
        guard let current = permissions.first(where: { $0.id == request.id && $0.taskID == request.taskID }),
              let binding = current.nativeBinding, binding == request.nativeBinding,
              binding.expiresAt > Date(), current.options.contains(where: { $0.id == option.id }),
              ["accept", "decline", "cancel"].contains(option.id), !nativeDeciding.contains(request.id),
              let task = state.tasks.first(where: { $0.id == request.taskID }), task.status == .awaitingPermission,
              !nativeInterruptPending.contains(task.id), !nativeInterruptUnverified.contains(task.id), !nativeRecovering.contains(task.id), !nativeDetaching.contains(task.id),
              task.nativeState?.threadID == binding.threadID, task.nativeState?.turnID == binding.turnID,
              !NativeTaskState.terminalTurnStatuses.contains(task.nativeState?.turnStatuses?[binding.turnID] ?? ""),
              task.nativeState?.connection == .connected, liveTasks.contains(task.id) else { return }
        nativeDeciding.insert(request.id); defer { nativeDeciding.remove(request.id) }
        do {
            if option.id == "cancel" {
                try nativeRecord(task.id, kind: "native.approval.cancelRequested", fields: ["requestHash": binding.requestHash, "requestId": request.id, "itemId": binding.itemID])
                await cancelNative(task.id)
                return
            }
            try nativeIntent(task.id, kind: .approval, target: binding.itemID,
                fields: ["requestHash": binding.requestHash, "requestId": request.id, "decision": option.id])
            _ = try await client.request("native_permission", ["taskId": task.id.uuidString,
                "requestId": request.id, "requestHash": binding.requestHash, "optionId": option.id])
            permissions.removeAll { $0.id == request.id && $0.taskID == task.id }
            mutate(task.id) {
                if $0.nativeState?.pendingOperation?.status == .requested { $0.nativeState?.pendingOperation?.status = .accepted }
                if $0.status == .awaitingPermission { $0.status = permissions.contains(where: { $0.taskID == task.id }) ? .awaitingPermission : .running }
                $0.messages.append(.init(role: "system", text: "已回复确认：\(option.title)"))
            }
            try persistNative()
        } catch { nativeFailure(task.id, error) }
    }

    func recoverNative(taskID id: UUID) async {
        guard isStorageReady else { return }
        guard !nativeRecovering.contains(id), !nativeDetaching.contains(id), let task = state.tasks.first(where: { $0.id == id }),
              let thread = task.nativeState?.threadID,
              let instance = state.instances.first(where: { $0.id == task.instanceID }) else { return }
        nativeRecovering.insert(id); nativeEventBuffers[id] = []
        defer { nativeRecovering.remove(id); nativeEventBuffers.removeValue(forKey: id) }
        permissions.removeAll { $0.taskID == id }
        do {
            // Supersede an outstanding control request before the first suspension.
            try nativeIntent(id, kind: .resume, target: thread)
            nativeInterruptPending.remove(id); nativeInterruptUnverified.remove(id); nativeInterruptEvents.removeValue(forKey: id)
            nativeBackgroundStopping.remove(id)
            mutate(id) { $0.nativeState?.connection = .reconnecting }; try persistNative()
            _ = try await connectNative(instance: instance)
            liveTasks.insert(id)
            let result = try await client.request("native_resume", ["instanceId": instance.id.uuidString, "taskId": id.uuidString, "threadId": thread], timeout: 90)
            guard nativeRecovering.contains(id), nativeEventBuffers[id] != nil, result["threadId"] as? String == thread else { throw WorkbenchFailure("恢复会话标识不一致，已停止合并。") }
            let backgroundCount = result["backgroundCount"] as? Int
            let turns = result["turns"] as? [[String: Any]] ?? []
            let entries = result["items"] as? [[String: Any]] ?? []
            for entry in entries {
                if let item = entry["item"] as? [String: Any] { mergeNativeItem(id, item: item, turnID: entry["turnId"] as? String, completedEvent: validNativeCompletionTime(entry["completedAtMs"])) }
            }
            mutate(id) { task in
                for turn in turns {
                    if let turnID = turn["id"] as? String { task.nativeState?.recordTurnStatus(turnID, status: turn["status"] as? String) }
                }
            }
            mutate(id) {
                $0.nativeState?.connection = .connected; $0.nativeState?.lastReconciledAt = Date()
                $0.nativeState?.pendingOperation?.status = .confirmed
                $0.nativeState?.historyNotice = "已从官方记录核对。断开期间的实时审计可能有缺口；恢复交界处的流式文本以项目完成后的记录为准，旧审批不自动重放。"
                if let count = backgroundCount { $0.nativeState?.historyNotice? += " 恢复时核对到后台命令：\(count) 个。" }
                if let turn = result["turnId"] as? String {
                    $0.nativeState?.turnID = turn
                    $0.status = nativeStatus($0.nativeState?.turnStatuses?[turn] ?? "inProgress")
                } else if let last = turns.last {
                    $0.nativeState?.turnID = last["id"] as? String
                    let savedStatus = $0.nativeState?.turnStatuses?[last["id"] as? String ?? ""]
                    $0.status = nativeStatus(savedStatus ?? last["status"] as? String)
                } else { $0.status = .unknown; $0.nativeState?.turnID = nil }
            }
            let buffered = nativeEventBuffers.removeValue(forKey: id) ?? []
            nativeRecovering.remove(id)
            let snapshotIDs = Set(entries.compactMap { ($0["item"] as? [String: Any])?["id"] as? String })
            for event in buffered {
                let data = event["data"] as? [String: Any] ?? [:]
                let method = data["method"] as? String ?? ""
                let params = data["params"] as? [String: Any] ?? [:]
                let itemID = params["itemId"] as? String ?? (params["item"] as? [String: Any])?["id"] as? String
                // History has no event cursor. Replaying a covered delta would duplicate text.
                // Final items remain authoritative; active output settles on item/completed.
                if let itemID, snapshotIDs.contains(itemID), method.hasSuffix("Delta") || method.hasSuffix("/delta") || method == "item/started" { continue }
                receiveNative(event)
            }
            try nativeRecord(id, kind: "native.resume.confirmed", fields: ["threadId": thread, "itemCount": entries.count, "observationGap": true])
            try persistNative()
            await reconcileNativeHistory(id)
        } catch {
            mutate(id) { $0.nativeState?.connection = .disconnected }
            liveTasks.remove(id); nativeFailure(id, error)
        }
    }

    func nativeStatus(_ status: String?) -> WorkbenchTaskStatus {
        switch status { case "completed": .completed; case "interrupted": .cancelled; case "failed": .failed; case "inProgress": .running; default: .unknown }
    }

    func receiveNative(_ event: [String: Any]) {
        guard isStorageReady else { return }
        guard let instanceText = event["instanceId"] as? String, let instanceID = UUID(uuidString: instanceText),
              let data = event["data"] as? [String: Any], let method = data["method"] as? String,
              let params = data["params"] as? [String: Any] else { return }
        if method.hasPrefix("account/") {
            if method == "account/login/completed", params["loginId"] as? String == nativeLoginIDs[instanceID] {
                nativeLoginIDs.removeValue(forKey: instanceID)
                nativeNotice = params["success"] as? Bool == true ? "登录已完成，请重新检测账号与模型。" : "登录未完成，请重试。"
            }
            return
        }
        guard let taskText = event["taskId"] as? String, let id = UUID(uuidString: taskText), liveTasks.contains(id),
              let task = state.tasks.first(where: { $0.id == id }), task.instanceID == instanceID, task.nativeState != nil else { return }
        if nativeRecovering.contains(id) {
            guard (nativeEventBuffers[id]?.count ?? 0) < 1000 else {
                nativeRecovering.remove(id); nativeEventBuffers.removeValue(forKey: id)
                nativeFailure(id, WorkbenchFailure("恢复期间事件超过限制，请重新核对会话。")); return
            }
            nativeEventBuffers[id, default: []].append(event); return
        }
        if method == "connection/lost" {
            invalidateArtifactReads(id)
            invalidateNativeBackgroundStatus(id)
            nativeConnectionGenerations[instanceID] = UUID()
            permissions.removeAll { $0.taskID == id }; liveTasks.remove(id)
            mutate(id) { $0.nativeState?.connection = .disconnected; if $0.status.active { $0.status = .unknown }; $0.unread = true }
            persist(); return
        }
        guard let thread = params["threadId"] as? String else { return }
        if let known = task.nativeState?.threadID { guard known == thread else { return } }
        else {
            guard task.nativeState?.pendingOperation?.kind == .start else { return }
            mutate(id) { $0.nativeState?.threadID = thread; $0.sessionID = thread }
        }
        let turnObject = params["turn"] as? [String: Any]
        let turn = params["turnId"] as? String ?? turnObject?["id"] as? String
        if let turn {
            if method == "turn/started", NativeTaskState.terminalTurnStatuses.contains(task.nativeState?.turnStatuses?[turn] ?? "") {
                do { try nativeRecord(id, kind: "native.event", fields: ["method": method, "params": params]) }
                catch { self.error = error.localizedDescription }
                return
            }
            if task.nativeState?.turnID != turn, method == "item/completed" {
                // Only an already bound process may finish after a newer turn starts.
                guard let item = params["item"] as? [String: Any],
                      let itemID = item["id"] as? String,
                      let saved = task.nativeState?.items.first(where: { $0.id == itemID }),
                      saved.turnID == turn, saved.kind == item["type"] as? String,
                      !["agentMessage", "userMessage"].contains(saved.kind) else { return }
                do {
                    try nativeRecord(id, kind: "native.event", fields: ["method": method, "params": params])
                    mergeNativeItem(id, item: item, turnID: turn, completedEvent: true, isLiveCompletion: true, isRuntimeEvent: true)
                    try persistNative()
                } catch { self.error = error.localizedDescription }
                return
            } else if let known = task.nativeState?.turnID {
                guard known == turn else { return }
            } else {
                guard method == "turn/started", task.nativeState?.pendingOperation?.kind == .prompt else { return }
                mutate(id) { $0.nativeState?.turnID = turn }
            }
        }
        if method == "turn/completed" {
            guard let turn, turn == task.nativeState?.turnID, turnObject?["id"] as? String == turn,
                  let status = turnObject?["status"] as? String, NativeTaskState.terminalTurnStatuses.contains(status) else {
                do { try nativeRecord(id, kind: "native.event", fields: ["method": method, "params": params]) }
                catch { self.error = error.localizedDescription }
                return
            }
        }
        if method == "turn/completed", nativeInterruptPending.contains(id) || nativeInterruptUnverified.contains(id) {
            nativeInterruptEvents[id] = event
            return
        }
        do {
            // Deltas update the encrypted snapshot; control/final events are append-only audit records.
            if !method.hasSuffix("/delta") { try nativeRecord(id, kind: "native.event", fields: ["method": method, "params": params]) }
            switch method {
            case "turn/started":
                mutate(id) {
                    if let turn { $0.nativeState?.recordTurnStatus(turn, status: "inProgress") }
                    if $0.status != .cancelling, !NativeTaskState.terminalTurnStatuses.contains($0.nativeState?.turnStatuses?[turn ?? ""] ?? "") { $0.status = .running }
                    $0.nativeState?.connection = .connected
                }
            case "turn/completed":
                guard let turn, turn == state.tasks.first(where: { $0.id == id })?.nativeState?.turnID else { return }
                let previousOutcome = task.nativeState?.turnStatuses?[turn]
                let outcome = NativeTaskState.terminalTurnStatuses.contains(previousOutcome ?? "") ? previousOutcome : turnObject?["status"] as? String
                let newOutcome = previousOutcome != outcome || task.status != nativeStatus(outcome)
                mutate(id) {
                    $0.nativeState?.recordTurnStatus(turn, status: turnObject?["status"] as? String)
                    $0.status = nativeStatus($0.nativeState?.turnStatuses?[turn] ?? turnObject?["status"] as? String)
                    if newOutcome { $0.unread = true }
                    $0.nativeState?.pendingOperation?.status = .confirmed
                }
                permissions.removeAll { $0.taskID == id }
                if newOutcome {
                    invalidateNativeBackgroundStatus(id)
                    Task { [weak self] in await self?.reconcileNativeHistory(id) }
                }
            case "permission":
                guard let requestID = params["requestId"] as? String, let hash = params["requestHash"] as? String,
                      let turn, let item = params["itemId"] as? String, let expiry = params["expiresAt"] as? Double,
                      !NativeTaskState.terminalTurnStatuses.contains(task.nativeState?.turnStatuses?[turn] ?? ""),
                      Date(timeIntervalSince1970: expiry) > Date() else { return }
                let options = (params["options"] as? [[String: Any]] ?? []).compactMap { value -> WorkbenchPermission.Option? in
                    guard let option = value["id"] as? String, ["accept", "decline", "cancel"].contains(option) else { return nil }
                    return .init(id: option, title: value["title"] as? String ?? option, kind: value["kind"] as? String ?? "")
                }
                permissions.removeAll { $0.id == requestID && $0.taskID == id }
                permissions.append(.init(id: requestID, taskID: id, title: params["title"] as? String ?? "Codex 请求确认", detail: params["detail"] as? String ?? "", options: options,
                    nativeBinding: .init(requestHash: hash, threadID: thread, turnID: turn, itemID: item, expiresAt: Date(timeIntervalSince1970: expiry))))
                mutate(id) { $0.status = .awaitingPermission }
            case "permission/expired", "permissionExpired", "permission/invalidated":
                if let requestID = params["requestId"] as? String { permissions.removeAll { $0.id == requestID && $0.taskID == id } }
                if params["reason"] as? String == "resolved", let itemID = params["itemId"] as? String {
                    mutate(id) { if $0.nativeState?.pendingOperation?.kind == .approval && $0.nativeState?.pendingOperation?.targetID == itemID { $0.nativeState?.pendingOperation?.status = .confirmed } }
                }
                mutate(id) { if $0.status == .awaitingPermission && !permissions.contains(where: { $0.taskID == id }) { $0.status = .running } }
            case "item/started", "item/completed":
                if let item = params["item"] as? [String: Any] {
                    mergeNativeItem(id, item: item, turnID: turn, completedEvent: method == "item/completed", isLiveCompletion: method == "item/completed", isRuntimeEvent: true)
                    if method == "item/completed", let itemID = item["id"] as? String {
                        permissions.removeAll { $0.taskID == id && $0.nativeBinding?.itemID == itemID }
                        mutate(id) {
                            if $0.nativeState?.pendingOperation?.kind == .approval && $0.nativeState?.pendingOperation?.targetID == itemID { $0.nativeState?.pendingOperation?.status = .confirmed }
                            if $0.status == .awaitingPermission && !permissions.contains(where: { $0.taskID == id }) { $0.status = .running }
                        }
                    }
                }
            case "item/agentMessage/delta", "item/commandExecution/outputDelta":
                guard let itemID = params["itemId"] as? String, let delta = params["delta"] as? String else { return }
                mutateNativeConversationEvent(id) { task in
                    if let index = task.nativeState?.items.firstIndex(where: { $0.id == itemID }) {
                        guard task.nativeState?.items[index].hasTerminalEvidence != true else { return }
                        task.nativeState?.items[index].detail += delta
                        let bounded = String((task.nativeState?.items[index].detail ?? "").suffix(500_000))
                        task.nativeState?.items[index].detail = bounded
                    } else {
                        task.nativeState?.upsert(.init(id: itemID, turnID: turn, kind: method.contains("agentMessage") ? "agentMessage" : "commandExecution", title: method.contains("agentMessage") ? "回复" : "命令输出", detail: String(delta.prefix(500_000)), status: "inProgress"))
                    }
                    if method.contains("agentMessage") { upsertNativeMessage(&task, itemID: itemID, role: "assistant", text: task.nativeState?.items.first(where: { $0.id == itemID })?.detail ?? "") }
                }
            default: break
            }
            if !method.hasSuffix("/delta") { try persistNative() }
        } catch { nativeFailure(id, error) }
    }

    func upsertNativeMessage(_ task: inout WorkbenchTask, itemID: String, role: String, text: String) {
        if let index = task.messages.firstIndex(where: { $0.runtimeItemID == itemID }) { task.messages[index].text = text }
        else { task.messages.append(.init(role: role, text: text, runtimeItemID: itemID)) }
    }

    func mergeNativeItem(_ id: UUID, item: [String: Any], turnID: String?, completedEvent: Bool = false, isLiveCompletion: Bool = false, isRuntimeEvent: Bool = false) {
        guard let itemID = item["id"] as? String, let kind = item["type"] as? String else { return }
        let detail: String
        if let text = item["text"] as? String { detail = text }
        else if kind == "commandExecution" { detail = [item["command"] as? String, item["aggregatedOutput"] as? String].compactMap { $0 }.joined(separator: "\n") }
        else if let raw = try? JSONSerialization.data(withJSONObject: item, options: [.prettyPrinted, .sortedKeys]), let text = String(data: raw, encoding: .utf8) { detail = text }
        else { detail = "" }
        var incoming = NativeTimelineItem(id: itemID, turnID: turnID, kind: kind,
            title: item["command"] as? String ?? kind, detail: String(detail.prefix(500_000)),
            status: item["status"] as? String ?? "unknown",
            completionObserved: NativeTimelineItem.terminalStatuses(for: kind).contains(item["status"] as? String ?? "") || completedEvent && NativeTimelineItem.statuslessKinds.contains(kind))
        incoming.liveCompletionObserved = isLiveCompletion && incoming.hasTerminalEvidence ? true : nil
        mutateNativeConversationEvent(id, isRuntimeEvent: isRuntimeEvent) { task in
            if let saved = task.nativeState?.items.first(where: { $0.id == itemID }) {
                guard saved.accepts(incoming) else { return }
                if saved.hasTerminalEvidence { incoming.reconciledStatus = saved.reconciledStatus }
            }
            task.nativeState?.upsert(incoming)
            if kind == "agentMessage" { upsertNativeMessage(&task, itemID: itemID, role: "assistant", text: detail) }
        }
    }
}
