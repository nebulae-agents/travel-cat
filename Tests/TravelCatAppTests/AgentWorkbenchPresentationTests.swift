import XCTest
@testable import TravelCatApp

final class AgentWorkbenchPresentationTests: XCTestCase {
    func testNewAndExistingConversationsKeepIndependentDrafts() {
        var drafts = WorkbenchDraftCollection()
        let a = WorkbenchDraftTarget.task(UUID()), b = WorkbenchDraftTarget.task(UUID())
        let fresh = WorkbenchDraftTarget.new(UUID())
        drafts.update(a) { $0.text = "对话甲"; $0.files = [["name":"甲.txt"]] }
        drafts.update(b) { $0.text = "对话乙" }
        drafts.update(fresh) { $0.text = "新对话"; $0.parentTaskID = UUID() }
        XCTAssertEqual(drafts.draft(for: a).text, "对话甲")
        XCTAssertEqual(drafts.draft(for: a).files.first?["name"], "甲.txt")
        XCTAssertEqual(drafts.draft(for: b).text, "对话乙")
        XCTAssertEqual(drafts.draft(for: fresh).text, "新对话")
        XCTAssertNotNil(drafts.draft(for: fresh).parentTaskID)
    }
    func testAcknowledgementCannotClearNewerDraftOrAnotherTask() {
        var drafts = WorkbenchDraftCollection()
        let a = WorkbenchDraftTarget.task(UUID()), b = WorkbenchDraftTarget.new(UUID())
        drafts.update(a) { $0.text = "已发送" }
        let submitted = drafts.draft(for: a)
        drafts.update(a) { $0.text = "继续编辑" }
        drafts.update(b) { $0.text = "另一个输入框" }
        drafts.clear(a, submittedRevision: submitted.revision)
        XCTAssertEqual(drafts.draft(for: a).text, "继续编辑")
        XCTAssertEqual(drafts.draft(for: b).text, "另一个输入框")
        let current = drafts.draft(for: a)
        drafts.clear(a, submittedRevision: current.revision)
        XCTAssertEqual(drafts.draft(for: a).text, "")
        XCTAssertEqual(drafts.draft(for: b).text, "另一个输入框")
    }
    func testAgentSpecificNewDraftsDoNotLeakBetweenAgents() {
        var drafts = WorkbenchDraftCollection()
        let first = WorkbenchDraftTarget.new(UUID()), second = WorkbenchDraftTarget.new(UUID())
        drafts.update(first) { $0.text = "只交给第一个 Agent" }
        XCTAssertTrue(drafts.draft(for: second).text.isEmpty)
        XCTAssertEqual(drafts.draft(for: first).text, "只交给第一个 Agent")
    }
    func testProcessRecordsLeaveConversationWithoutHidingErrorsOrEditingSource() {
        var task = WorkbenchTask(instanceID: UUID(), title: "检查")
        task.messages = [.init(role:"user",text:"看看这个"), .init(role:"system",text:"读取文件 · completed"), .init(role:"system",text:"连接中断，操作结果待核实。"), .init(role:"assistant",text:"已整理")]
        let original = task.messages
        XCTAssertEqual(WorkbenchConversationPresentation.visibleMessages(task).map(\.text), ["看看这个","连接中断，操作结果待核实。","已整理"])
        XCTAssertEqual(WorkbenchConversationPresentation.processMessages(task).map(\.text), ["读取文件 · completed"])
        XCTAssertEqual(task.messages, original)
    }
    func testEmptyReasoningJSONIsNotCountedAsAnOperation() {
        var task = WorkbenchTask(instanceID:UUID(),title:"hello")
        task.nativeState = NativeTaskState()
        task.nativeState?.items = [.init(id:"r",kind:"reasoning",title:"reasoning",detail:"{\"summary\":[]}",status:"completed"),.init(id:"u",kind:"userMessage",title:"User",detail:"hello",status:"completed"),.init(id:"c",kind:"commandExecution",title:"读取材料",detail:"pwd",status:"completed")]
        XCTAssertEqual(WorkbenchConversationPresentation.processItems(task).map(\.id),["c"])
        XCTAssertEqual(task.nativeState?.items.count,3)
    }
    func testLongTitleIsShortenedForDisplayOnly() {
        let original = String(repeating:"这是很长的中文任务标题",count:8)+"\n不要改原问题"
        let title = WorkbenchConversationPresentation.shortTitle(original)
        XCTAssertLessThanOrEqual(title.count,32)
        XCTAssertFalse(title.contains("\n"))
        XCTAssertTrue(original.contains("不要改原问题"))
    }
    func testAgentFilterOnlyReturnsMatchingTasks() {
        let a = UUID(), b = UUID()
        let first = WorkbenchTask(instanceID:a,title:"a"), second = WorkbenchTask(instanceID:b,title:"b")
        XCTAssertEqual(WorkbenchConversationPresentation.tasks([first,second],instanceID:a).map(\.id),[first.id])
        XCTAssertEqual(WorkbenchConversationPresentation.tasks([first,second],instanceID:nil).count,2)
    }
    func testImageChoicesStayInsideTheSelectedAvailableLocalEnvironment() {
        let inventory = LocalRuntimeInventory(tools:[],contexts:[.init(name:"a",local:true,available:true),.init(name:"b",local:true,available:true),.init(name:"remote",local:false,available:true)],images:[.init(context:"a",ref:"codex-a@sha256:fixture"),.init(context:"a",ref:"other-a@sha256:fixture"),.init(context:"b",ref:"codex-b@sha256:fixture"),.init(context:"remote",ref:"codex-remote@sha256:fixture")],containers:[])
        XCTAssertEqual(WorkbenchConversationPresentation.images(in:inventory,context:"a").map(\.context),["a","a"])
        XCTAssertEqual(WorkbenchConversationPresentation.images(in:inventory,context:"b").count,1)
        XCTAssertTrue(WorkbenchConversationPresentation.images(in:inventory,context:"remote").isEmpty)
        XCTAssertTrue(WorkbenchConversationPresentation.images(in:inventory,context:"").isEmpty)
    }

    func testEmptyAssistantMessagesStayInRecordsWithoutRenderingBlankReplyRows() {
        var task = WorkbenchTask(instanceID: UUID(), title: "空回复")
        task.messages = [.init(role: "user", text: "继续"), .init(role: "assistant", text: ""), .init(role: "assistant", text: "  \n  "), .init(role: "assistant", text: "完成"), .init(role: "system", text: "操作结果待核实")]
        let original = task.messages
        XCTAssertEqual(WorkbenchConversationPresentation.visibleMessages(task).map(\.text), ["继续", "完成", "操作结果待核实"])
        XCTAssertEqual(task.messages, original)
    }

}
