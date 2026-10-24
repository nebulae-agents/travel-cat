import SwiftUI

private struct ConversationBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

@MainActor
struct AgentConversationView: View {
    @ObservedObject var model: AgentWorkbenchModel
    @ObservedObject var presentation: AgentWorkbenchPresentation
    let task: WorkbenchTask
    let artifacts: () -> Void
    let audit: () -> Void
    let handoff: (WorkbenchInstance) -> Void
    let settings: () -> Void
    @State private var showingDetails = false
    @State private var nearBottom = true
    @State private var hasNewReply = false
    @State private var viewportHeight: CGFloat = 0
    @State private var focusRequest = UUID()
    @State private var approvalIndex = 0
    private var instance: WorkbenchInstance? { model.state.instances.first { $0.id == task.instanceID } }
    private var target: WorkbenchDraftTarget { .task(task.id) }
    private var draft: Binding<WorkbenchSubmissionDraft> {
        Binding(get: { presentation.drafts.draft(for: target) }, set: { value in presentation.drafts.update(target) { $0 = value } })
    }
    private var canSend: Bool { model.canReply(task.id) && !draft.wrappedValue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var requests: [WorkbenchPermission] { model.permissions.filter { $0.taskID == task.id } }
    private var modelRequests: [WorkbenchModelApproval] { model.modelApprovals.filter { $0.taskID == task.id } }
    private var requestCount: Int { requests.count + modelRequests.count }
    private var recoveryBusy: Bool { model.nativeRecovering.contains(task.id) || model.nativeDetaching.contains(task.id) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack(alignment: .trailing) {
                VStack(spacing: 0) {
                    if let notice = importantNotice { noticeView(notice) }
                    messages
                    VStack(spacing: 11) {
                        if requestCount > 0 { approval }
                        AgentComposerView(draft: draft, instance: instance, isNew: false, canSend: canSend, focusRequest: focusRequest,
                            hint: composerHint, allowModelAccess: .constant(false), onFailure: { model.error = $0 }, send: send)
                    }.padding(.horizontal, 24).padding(.top, 9).padding(.bottom, 16).frame(maxWidth: 820)
                }.frame(maxWidth: .infinity)
                if showingDetails {
                    AgentConversationDetailsView(model: model, task: task, close: { showingDetails = false }, audit: audit)
                        .frame(width: 350).shadow(color: .black.opacity(0.05), radius: 15, x: -5).transition(.move(edge: .trailing))
                }
            }
        }.background(WorkbenchTheme.canvas)
        .onChange(of: requestCount) { _, value in approvalIndex = min(approvalIndex, max(0, value - 1)) }
    }
    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text(WorkbenchConversationPresentation.shortTitle(task.title)).font(.system(size: 14, weight: .semibold)).lineLimit(1).help(task.title)
                HStack(spacing: 6) {
                    Circle().fill(task.nativeState?.connection == .disconnected ? WorkbenchTheme.muted : WorkbenchTheme.accent).frame(width: 5, height: 5)
                    Text(instance?.name ?? "已移除的 Agent").lineLimit(1)
                    if let config = instance?.native {
                        Text("·"); Image(systemName: "folder").font(.system(size: 11))
                        Text(URL(fileURLWithPath: config.workspace).lastPathComponent).lineLimit(1).truncationMode(.middle)
                    }
                }.font(.system(size: 12)).foregroundStyle(WorkbenchTheme.muted)
            }
            Spacer(minLength: 5)
            Text(task.status.title).font(.system(size: 12)).foregroundStyle(task.status == .unknown || task.status == .awaitingPermission ? CottageTheme.terracotta : WorkbenchTheme.muted).fixedSize()
            if task.status.active {
                Button(task.status == .cancelling ? "正在停止…" : "停止本轮") { Task { await model.cancel(task.id) } }
                    .disabled(task.status == .cancelling || task.status == .connecting || recoveryBusy).controlSize(.small)
            }
            Button { withAnimation(.easeInOut(duration: 0.15)) { showingDetails.toggle() } } label: { Image(systemName: "sidebar.right") }
                .buttonStyle(.plain).frame(width: 28, height: 28).help("对话详情").accessibilityLabel("对话详情")
            Menu {
                Button("制品与文件…", action: artifacts)
                Button("调用与审计…", action: audit)
                Menu("交接给其他 Agent") { ForEach(model.state.instances) { instance in Button(instance.name) { handoff(instance) } } }
                    .disabled(task.messages.last(where: { $0.role == "assistant" }) == nil)
                if let parent = task.parentTaskID { Button("查看上游对话") { model.selectedTaskID = parent } }
                Divider()
                Button("Agent 设置…", action: settings)
                if model.isLive(task.id) {
                    if task.nativeState != nil && [.completed, .cancelled, .failed].contains(task.status) {
                        Button(model.nativeBackgroundStopping.contains(task.id) ? "正在停止后台命令…" : "停止后台命令") { Task { await model.stopNativeBackgroundTasks(task.id) } }
                            .disabled(model.nativeBackgroundStopping.contains(task.id) || recoveryBusy)
                    }
                    Button(task.nativeState == nil ? "结束会话" : "断开会话") { Task { await model.stop(task.id) } }
                        .disabled(task.nativeState != nil && (recoveryBusy || task.status == .cancelling || model.nativeBackgroundStopping.contains(task.id)))
                }
            } label: { Image(systemName: "ellipsis").frame(width: 20, height: 24) }.menuStyle(.borderlessButton).fixedSize().help("更多会话操作").accessibilityLabel("更多会话操作")
        }.padding(.horizontal, 24).padding(.vertical, 16)
    }
    private var messages: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(WorkbenchConversationPresentation.visibleMessages(task)) { message in messageView(message) }
                        if task.status == .running || task.status == .connecting {
                            HStack(spacing: 9) { ProgressView().controlSize(.small); Text(task.status == .connecting ? "正在建立会话…" : "正在处理…").font(.system(size: 12)).foregroundStyle(WorkbenchTheme.muted) }
                        }
                        let count = WorkbenchConversationPresentation.processItems(task).count + WorkbenchConversationPresentation.processMessages(task).count
                        HStack(spacing: 18) {
                            if count > 0 {
                                Button { showingDetails = true } label: {
                                    Label(WorkbenchConversationPresentation.hasProcessFailure(task) ? "运行过程 · 有失败记录" : "运行过程 · \(count) 条", systemImage: "list.bullet.rectangle")
                                }.foregroundStyle(WorkbenchConversationPresentation.hasProcessFailure(task) ? CottageTheme.terracotta : WorkbenchTheme.muted)
                            }
                            if !task.status.active { Button(action: artifacts) { Label("制品与文件", systemImage: "doc.on.doc") }.foregroundStyle(WorkbenchTheme.accent) }
                        }.buttonStyle(.plain).font(.system(size: 12)).padding(.leading, 36)
                        Color.clear.frame(height: 1).id("bottom")
                            .background(GeometryReader { geometry in Color.clear.preference(key: ConversationBottomKey.self, value: geometry.frame(in: .named("conversationScroll")).maxY) })
                    }.frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.vertical, 25)
                }
                .coordinateSpace(name: "conversationScroll")
                .background(GeometryReader { geometry in Color.clear.onAppear { viewportHeight = geometry.size.height }.onChange(of: geometry.size.height) { _, height in viewportHeight = height } })
                .onPreferenceChange(ConversationBottomKey.self) { value in nearBottom = value <= viewportHeight + 90 }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: task.messages) { _, _ in
                    if nearBottom { proxy.scrollTo("bottom", anchor: .bottom); hasNewReply = false }
                    else { hasNewReply = true }
                }
                if hasNewReply && !nearBottom {
                    Button("有新回复 ↓") { proxy.scrollTo("bottom", anchor: .bottom); hasNewReply = false }.buttonStyle(.bordered).controlSize(.small).padding(.bottom, 8)
                }
            }
        }
    }
    @ViewBuilder private func messageView(_ message: WorkbenchMessage) -> some View {
        if message.role == "user" {
            HStack { Spacer(minLength: 30); Text(verbatim: message.text).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled).padding(14).background(WorkbenchTheme.selection.opacity(0.65), in: RoundedRectangle(cornerRadius: 12)) }.padding(.leading, 20)
        } else if message.role == "assistant" {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: instance?.symbol ?? "sparkles").font(.system(size: 12)).foregroundStyle(WorkbenchTheme.accent).frame(width: 24, height: 24).background(WorkbenchTheme.sidebar, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 8) {
                    Text(instance?.name ?? "Agent").font(.system(size: 12, weight: .medium)).foregroundStyle(WorkbenchTheme.muted)
                    Text(verbatim: message.text).font(.system(size: 14)).lineSpacing(6).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            Label { Text(verbatim: message.text).textSelection(.enabled) } icon: { Image(systemName: "info.circle") }
                .font(.system(size: 12)).foregroundStyle(WorkbenchTheme.muted).padding(.leading, 36)
        }
    }
    private var importantNotice: String? {
        if let native = task.nativeState, native.connection == .disconnected { return "连接已断开。恢复后会先核对原会话，再允许继续发送。" }
        if task.status == .unknown { return task.nativeState?.historyNotice ?? "操作结果仍待核实，请先恢复或检查会话状态。" }
        if task.status == .cancelling { return "停止请求已提交，正在等待运行时确认本轮和后台命令的停止结果。" }
        if model.nativeBackgroundStopping.contains(task.id) { return "正在停止并核对后台命令，确认完成前不会标记已停止。" }
        return nil
    }
    private func noticeView(_ text: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(CottageTheme.terracotta)
            Text(text).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
            if let native = task.nativeState, native.threadID != nil, native.connection == .disconnected || task.status == .unknown {
                Button(recoveryBusy ? "正在核对…" : "恢复连接") { Task { await model.recoverNative(taskID: task.id) } }
                    .disabled(model.nativeBusy.contains(task.instanceID) || native.connection == .reconnecting || recoveryBusy).controlSize(.small)
            }
        }.padding(12).background(WorkbenchTheme.warning).overlay(alignment: .bottom) { Divider() }
    }
    private var composerHint: String? {
        if requestCount > 0 { return "先处理当前审批；未批准的操作不会自动执行。" }
        if !model.canReply(task.id) {
            if task.nativeState?.connection == .disconnected { return "可以先保存草稿，恢复连接后再发送。" }
            return task.status.active ? "可先写下下一条消息，本轮结束后再发送。" : "当前连接不能继续此会话，可新建对话。"
        }
        return nil
    }
    private var approval: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("需要你确认", systemImage: "hand.raised").font(.system(size: 13, weight: .semibold))
                Spacer()
                if requestCount > 1 {
                    Button { approvalIndex = max(0, approvalIndex - 1) } label: { Image(systemName: "chevron.left") }.disabled(approvalIndex == 0)
                    Text("\(min(approvalIndex + 1, requestCount)) / \(requestCount)").font(.caption)
                    Button { approvalIndex = min(requestCount - 1, approvalIndex + 1) } label: { Image(systemName: "chevron.right") }.disabled(approvalIndex >= requestCount - 1)
                }
            }
            let index = min(approvalIndex, max(0, requestCount - 1))
            if index < modelRequests.count {
                let request = modelRequests[index]
                Text("模型提交待确认").font(.system(size: 12, weight: .medium))
                Text(verbatim: "将发送到 \(request.destination) · \(request.model)").font(.system(size: 12)).textSelection(.enabled)
                Button("查看完整提交内容并决定", action: audit).controlSize(.small)
            } else if requests.indices.contains(index - modelRequests.count) {
                let request = requests[index - modelRequests.count]
                Text(verbatim: request.title).font(.system(size: 12)).textSelection(.enabled).lineLimit(2)
                DisclosureGroup("完整操作详情") {
                    ScrollView { Text(verbatim: request.detail).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 140)
                }.font(.system(size: 12))
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { permissionButtons(request) }
                    VStack(alignment: .leading, spacing: 8) { permissionButtons(request) }
                }
            }
        }.padding(13).background(WorkbenchTheme.warning, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(CottageTheme.border.opacity(0.7)))
    }
    @ViewBuilder private func permissionButtons(_ request: WorkbenchPermission) -> some View {
        ForEach(request.options) { option in
            Button(option.title) { Task { await model.respond(request, option: option) } }
                .disabled(model.nativeDeciding.contains(request.id)).controlSize(.small)
        }
    }
    private func send() {
        guard canSend else { return }
        let submitted = presentation.drafts.draft(for: target)
        Task { if await model.followUp(taskID: task.id, text: submitted.text) { presentation.drafts.clear(target, submittedRevision: submitted.revision) } }
    }
}
