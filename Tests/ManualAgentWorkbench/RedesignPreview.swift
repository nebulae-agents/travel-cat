// Real production views with a deterministic offline runtime. No real account or user data.
import AppKit
import SwiftUI
import Combine

extension Bundle { static var module: Bundle { .main } }

@MainActor final class RedesignCredentials: TravelServiceCredentialStoring {
    var values: [String:String] = [:]
    func read(id: String) throws -> String? { values[id] }
    func save(_ secret: String?, id: String) throws { values[id] = secret }
}

@MainActor final class RedesignRuntime: AgentRuntimeClient {
    var onEvent: (([String:Any]) -> Void)?
    var onExit: (() -> Void)?
    var threads: [String:String] = [:]
    var instances: [String:String] = [:]
    var activeTurns: [String:String] = [:]
    var backgroundCount = 1
    var backgroundStatusFails = false
    let files: [String:Data] = ["分享提纲.md":Data("# 让 AI 进入日常工作\n\n1. 找到一个重复任务\n2. 先做一次可核对的小实验\n3. 让结果进入原有工作流程\n\n这是一份离线客户端验收制品。\n".utf8),"结果.txt":Data("离线制品预览与确认验收。\n".utf8)]
    func launch(python: String) throws {}
    func shutdown() { onExit?() }
    private func emit(_ id: String, _ method: String, _ params: [String:Any]) {
        onEvent?(["event":"native","taskId":id,"instanceId":instances[id] ?? "","data":["method":method,"params":params]])
    }
    private func complete(_ id: String, turn: String, text: String, interrupted: Bool = false) {
        let thread = threads[id] ?? ""
        if !interrupted { emit(id,"item/completed",["threadId":thread,"turnId":turn,"item":["id":UUID().uuidString,"type":"agentMessage","text":text]]) }
        emit(id,"turn/completed",["threadId":thread,"turn":["id":turn,"status":interrupted ? "interrupted" : "completed"]])
    }
    func request(_ method: String, _ params: [String:Any], timeout: UInt64) async throws -> [String:Any] {
        let id=params["taskId"] as? String ?? ""
        switch method {
        case "native_connect": return ["connected":true,"version":"离线 UI 夹具","account":["authenticated":true],"models":[["id":"fixture-only","model":"fixture-only","displayName":"离线模型","isDefault":true]],"capabilities":["authentication":true,"events":true,"approval":true,"history":true,"resume":true,"interrupt":true,"backgroundTerminals":true,"artifacts":true]]
        case "native_start":
            let thread=UUID().uuidString;threads[id]=thread;instances[id]=params["instanceId"] as? String
            return ["threadId":thread,"sessionId":thread]
        case "native_prompt":
            let turn=UUID().uuidString;activeTurns[id]=turn
            Task { try? await Task.sleep(for:.milliseconds(600)); self.complete(id,turn:turn,text:"已收到。这是通过真实对话组件显示的离线夹具回复；未调用模型服务。") }
            return ["turnId":turn]
        case "native_permission":
            let turn=activeTurns[id] ?? "fixture-turn"
            Task { try? await Task.sleep(for:.milliseconds(300)); self.complete(id,turn:turn,text:"审批选择已收到（离线夹具），操作完成结果已回读。") }
            return ["accepted":true]
        case "native_cancel":
            let turn=activeTurns[id] ?? "fixture-turn"
            Task { try? await Task.sleep(for:.milliseconds(200)); self.complete(id,turn:turn,text:"",interrupted:true) }
            return ["requested":true,"backgroundStopped":true,"terminatedCount":0]
        case "native_background_status":
            FileHandle.standardOutput.write(Data("fixture.backgroundStatus.read\n".utf8))
            if backgroundStatusFails { throw WorkbenchFailure("离线夹具：后台命令状态暂时无法核对。") }
            return ["threadId":threads[id] ?? "","count":backgroundCount,"itemIds":(0..<backgroundCount).map { "fixture-background-\($0)" }]
        case "native_background_stop":
            let stopped = backgroundCount; backgroundCount = 0
            return ["stopped":true,"terminatedCount":stopped]
        case "native_detach": return ["detached":true]
        case "native_resume":
            threads[id]=params["threadId"] as? String;instances[id]=params["instanceId"] as? String
            return ["threadId":threads[id] ?? "","backgroundCount":0,"turns":[["id":"fixture-turn","status":"completed"]],"items":[]]
        case "native_artifacts","artifacts": return ["files":files.keys.sorted().map { ["path":$0,"size":files[$0]!.count] }]
        case "native_export","export":
            guard let path=params["path"] as? String, let bytes=files[path] else { throw WorkbenchFailure("离线文件不存在。") }
            return ["name":path,"base64":bytes.base64EncodedString()]
        case "scan_local":
            let image="fixture-acp@sha256:"+String(repeating:"a",count:64)
            return ["tools":[["kind":"codex","path":"/fixture/codex","running":0]],"contexts":[["name":"fixture-local","local":true,"available":true]],"images":[["context":"fixture-local","ref":image]],"containers":[]]
        case "discover": return ["docker":true,"images":[],"message":"离线夹具环境已检查，未连接真实 Docker。"]
        case "probe": return ["probeId":params["probeId"] ?? "","compatible":true,"cleanupConfirmed":true,"message":"离线夹具握手和清理已确认"]
        case "probe_cleanup": return ["probeId":params["probeId"] ?? "","cleanupConfirmed":true]
        case "start": return ["sessionId":UUID().uuidString]
        case "prompt":
            onEvent?(["taskId":id,"event":"update","data":["sessionUpdate":"agent_message_chunk","content":["text":"ACP 离线夹具回复。"]]])
            return [:]
        case "cancel","stop": return ["stopped":true]
        case "audit_ack": return ["accepted":true]
        default: throw WorkbenchFailure("离线夹具未实现此操作。")
        }
    }
}

@MainActor final class RedesignActions: NSObject {
    let model: AgentWorkbenchModel
    let taskID: UUID
    let runtime: RedesignRuntime
    let window: NSWindow
    init(model:AgentWorkbenchModel,taskID:UUID,runtime:RedesignRuntime,window:NSWindow) { self.model=model;self.taskID=taskID;self.runtime=runtime;self.window=window }
    @objc func completed() {
        model.permissions.removeAll { $0.taskID == taskID };model.liveTasks.insert(taskID)
        model.mutate(taskID) { $0.status = .completed;$0.nativeState?.connection = .connected }
        model.selectedTaskID=taskID
    }
    @objc func backgroundRunning() {
        completed(); runtime.backgroundCount = 1; runtime.backgroundStatusFails = false
        model.invalidateNativeBackgroundStatus(taskID)
        Task { await model.refreshNativeBackgroundStatus(taskID) }
    }
    @objc func backgroundUnknown() {
        completed(); runtime.backgroundStatusFails = true
        model.invalidateNativeBackgroundStatus(taskID)
        Task { await model.refreshNativeBackgroundStatus(taskID) }
    }
    @objc func approval() {
        completed();let task=model.state.tasks.first { $0.id == taskID }!
        model.mutate(taskID) { $0.status = .awaitingPermission;$0.nativeState?.turnID="fixture-turn" }
        runtime.activeTurns[taskID.uuidString]="fixture-turn"
        let binding=NativeApprovalBinding(requestHash:String(repeating:"a",count:64),threadID:task.nativeState!.threadID!,turnID:"fixture-turn",itemID:"fixture-write",expiresAt:Date().addingTimeInterval(300))
        model.permissions.append(.init(id:UUID().uuidString,taskID:taskID,title:"写入分享提纲.md",detail:"命令：printf '示例内容' > 分享提纲.md\n目录：仅本任务工作目录\n本夹具不执行命令。",options:[.init(id:"accept",title:"仅允许这次",kind:"allow_once"),.init(id:"decline",title:"拒绝",kind:"reject_once"),.init(id:"cancel",title:"取消本轮",kind:"cancel")],nativeBinding:binding))
    }
    @objc func disconnected() { completed();model.liveTasks.remove(taskID);model.mutate(taskID) { $0.nativeState?.connection = .disconnected } }
    @objc func failed() { completed();model.mutate(taskID) { $0.status = .failed;$0.messages.append(.init(role:"system",text:"离线夹具：一次操作失败，记录保留在运行过程。")) } }
    @objc func compact() { window.setContentSize(NSSize(width:760,height:600)) }
    @objc func normal() { window.setContentSize(NSSize(width:1000,height:740)) }
}

@main @MainActor struct RedesignPreview {
    static func main() throws {
        let app=NSApplication.shared;app.setActivationPolicy(.regular)
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("travelcat-redesign-preview-\(UUID().uuidString)")
        let workspace=root.appendingPathComponent("分享资料")
        try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true)
        let credentials=RedesignCredentials(),runtime=RedesignRuntime()
        let model=AgentWorkbenchModel(root:root.appendingPathComponent("state"),credentials:credentials,client:runtime)
        var native=WorkbenchInstance(name:"日常助手（离线）",image:"",command:[])
        native.native = .init(executable:"/usr/bin/true",workspace:workspace.path,model:"fixture-only")
        try model.save(instance:native,newKey:"")
        var acp=WorkbenchInstance(name:"代码助手（离线）",image:"fixture-acp@sha256:"+String(repeating:"a",count:64),command:["codex-acp"])
        acp.provider.model="fixture-only";acp.provider.baseURL="https://fixture.invalid/v1"
        try model.save(instance:acp,newKey:"fixture-only")
        var task=WorkbenchTask(instanceID:native.id,title:"整理一份具体、简单的 AI 工作分享提纲")
        task.status = .completed;task.sessionID="fixture-thread";task.nativeState = NativeTaskState();task.nativeState?.threadID="fixture-thread";task.nativeState?.turnID="fixture-turn";task.nativeState?.connection = .connected
        task.messages=[.init(role:"user",text:"帮我整理一份 15 分钟的内部分享提纲，主题是让 AI 进入日常工作。内容具体一点，少讲概念。"),.init(role:"assistant",text:"可以把这 15 分钟串成一条清楚的线：找到一个重复任务，把它做顺，再判断是否值得推广。\n\n1. 从一个真实场景开始 · 3 分钟\n用整理会议纪要开场，看看哪些步骤最耗时间，哪些信息最容易漏。\n\n2. 展示三个能复用的小做法 · 8 分钟\n资料整理：先给来源，再提取可核对的要点。\n文档起草：提供结构和例子，保留人的判断。\n流程协作：让结果进入原来的工作流程。\n\n3. 留下一个容易行动的起点 · 4 分钟\n每个人选一个下周会重复三次的任务，做一次小实验，记录节省的时间和仍需人工检查的部分。\n\n分享提纲.md 已作为离线示例制品提供，可从下方入口查看。")]
        task.nativeState?.items=[.init(id:"tool",kind:"commandExecution",title:"整理分享材料",detail:"离线示例命令与输出\n未执行真实工具。",status:"completed"),.init(id:"reason",kind:"reasoning",title:"reasoning",detail:"{\"content\":[],\"summary\":[]}",status:"completed")]
        var other=WorkbenchTask(instanceID:acp.id,title:"检查登录页交互");other.status = .completed;other.sessionID="fixture-acp-session";other.messages=[.init(role:"user",text:"检查登录页的错误提示和加载状态。"),.init(role:"assistant",text:"先核对三个地方：错误提示贴近字段、提交期间避免重复点击、失败后保留原来的输入。")]
        model.state.tasks=[task,other];model.selectedTaskID=task.id;model.preferredInstanceID=native.id;model.liveTasks=[task.id,other.id]
        model.nativeConnections[native.id] = .init(authenticated:true,version:"离线 UI 夹具",models:[.init(id:"fixture-only",model:"fixture-only",name:"离线模型",isDefault:true)],capabilities:["history":true,"resume":true,"approval":true,"interrupt":true,"artifacts":true])
        runtime.threads[task.id.uuidString]="fixture-thread";runtime.instances[task.id.uuidString]=native.id.uuidString
        let window=NSWindow(contentRect:NSRect(x:100,y:100,width:1000,height:740),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
        window.title="Travel Cat · 界面验收（离线夹具）";window.isReleasedWhenClosed=false;window.contentMinSize=NSSize(width:760,height:600)
        let hosting=NSHostingView(rootView:AgentWorkbenchView(model:model));hosting.sizingOptions=[];window.contentView=hosting
        let actions=RedesignActions(model:model,taskID:task.id,runtime:runtime,window:window)
        let menu=NSMenu();let appItem=NSMenuItem();let appMenu=NSMenu();appMenu.addItem(withTitle:"退出离线夹具",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q");appItem.submenu=appMenu;menu.addItem(appItem)
        let scenesItem=NSMenuItem(title:"验收场景",action:nil,keyEquivalent:"");let scenes=NSMenu(title:"验收场景")
        for (title,action,key) in [("完成状态",#selector(RedesignActions.completed),"0"),("等待审批",#selector(RedesignActions.approval),"1"),("连接断开",#selector(RedesignActions.disconnected),"2"),("操作失败",#selector(RedesignActions.failed),"3"),("后台命令 1 个",#selector(RedesignActions.backgroundRunning),"7"),("后台命令待核对",#selector(RedesignActions.backgroundUnknown),"8"),("小窗口 760×600",#selector(RedesignActions.compact),"5"),("常用窗口 1000×740",#selector(RedesignActions.normal),"6")] {
            let item=NSMenuItem(title:title,action:action,keyEquivalent:key);item.target=actions;item.keyEquivalentModifierMask=[.command,.option];scenes.addItem(item)
        }
        scenesItem.submenu=scenes;menu.addItem(scenesItem);app.mainMenu=menu
        window.center();window.makeKeyAndOrderFront(nil);app.activate(ignoringOtherApps:true)
        let observer=NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:window,queue:.main) { _ in MainActor.assumeIsolated { app.stop(nil) } }
        withExtendedLifetime(actions) { app.run() }
        NotificationCenter.default.removeObserver(observer);model.shutdown();try? FileManager.default.removeItem(at:root)
    }
}
