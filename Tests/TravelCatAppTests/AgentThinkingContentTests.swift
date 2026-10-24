import AppKit
import XCTest
@testable import TravelCatApp

final class AgentThinkingContentTests: XCTestCase {
    func testOnlyExplicitAssistantThoughtSourcesCollapse() throws {
        let text = "思考 reasoning <think>仍是正文</think>\r\n\t🙂"
        for source in [nil, "future.reasoning", "acp.agent_message_chunk", "ACP.agent_thought_chunk"] as [String?] {
            let message = WorkbenchMessage(role: "assistant", text: text, sourceKind: source)
            XCTAssertNil(AgentThinkingContent.acp(message))
        }
        XCTAssertNil(AgentThinkingContent.acp(.init(role: "user", text: text, sourceKind: "acp.agent_thought_chunk")))
        let message = WorkbenchMessage(role: "assistant", text: text, sourceKind: "acp.agent_thought_chunk")
        let content = try XCTUnwrap(AgentThinkingContent.acp(message))
        XCTAssertEqual(content.id, "acp.thought:" + message.id.uuidString)
        XCTAssertEqual(Data(content.text.utf8), Data(text.utf8))
        XCTAssertNil(content.rawSource)
    }

    func testNativeProjectionReadsEveryStoredTextFieldInFieldAndArrayOrder() throws {
        let detail = "{\r\n\t\"text\":\"text🙂  \",\"summary\":[\"first\",{\"type\":\"summary_text\",\"text\":\"second\\r\\n\"},\"\"],\"content\":[{\"type\":\"reasoning_text\",\"text\":\"\\tcode\"},\"last\"]\r\n}"
        let item = NativeTimelineItem(id: "r", kind: "reasoning", title: "reasoning", detail: detail, status: "unknown")
        let content = try XCTUnwrap(AgentThinkingContent.native(item))
        XCTAssertEqual(content.id, "native.reasoning:r")
        XCTAssertEqual(Data(content.text.utf8), Data("text🙂  \n\nfirst\n\nsecond\r\n\n\n\tcode\n\nlast".utf8))
        XCTAssertEqual(Data(try XCTUnwrap(content.rawSource).utf8), Data(detail.utf8))
    }

    func testKnownEmptyReasoningDisappearsButUnknownOrLegacyDetailRemainsReachable() throws {
        for detail in ["{\"summary\":[]}", "{\"text\":\"\",\"summary\":[],\"content\":[]}", "{\"summary\":[\"  \", {\"text\":\"\\r\\n\"}]}"] {
            XCTAssertNil(AgentThinkingContent.native(.init(id: "empty", kind: "reasoning", title: "", detail: detail, status: "unknown")))
        }
        for detail in ["legacy\r\n\t🙂  ", "{\"summary\":{\"future\":\"shape\"}}", "{\"futurePayload\":[\"opaque\"]}", "{\"summary\":[],\"futurePayload\":\"opaque\"}", "{\"summary\":[{\"text\":\"\",\"future\":true}]}"] {
            let content = try XCTUnwrap(AgentThinkingContent.native(.init(id: "future", kind: "reasoning", title: "", detail: detail, status: "unknown")))
            XCTAssertEqual(Data(content.text.utf8), Data(detail.utf8))
            XCTAssertEqual(Data(try XCTUnwrap(content.rawSource).utf8), Data(detail.utf8))
        }
        XCTAssertNil(AgentThinkingContent.native(.init(id: "empty", kind: "reasoning", title: "", detail: "", status: "unknown")))
        XCTAssertNil(AgentThinkingContent.native(.init(id: "answer", kind: "agentMessage", title: "", detail: "reasoning", status: "unknown")))
    }

    func testProjectionPreservesItemOrderUnknownProcessAndSnapshotBytes() throws {
        var task = WorkbenchTask(instanceID: UUID(), title: "projection")
        task.messages = [.init(role: "assistant", text: "普通思考正文"), .init(role: "assistant", text: "typed", sourceKind: "acp.agent_thought_chunk")]
        task.nativeState = NativeTaskState(items: [
            .init(id: "a", kind: "reasoning", title: "", detail: "{\"summary\":[\"first\"]}", status: "unknown"),
            .init(id: "empty", kind: "reasoning", title: "", detail: "{\"summary\":[]}", status: "unknown"),
            .init(id: "unknown", kind: "futureProcess", title: "", detail: "raw\r\n\t🙂", status: "unknown"),
            .init(id: "b", kind: "reasoning", title: "", detail: "legacy  \r\n", status: "unknown")])
        var snapshot = WorkbenchSnapshot(); snapshot.tasks = [task]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(snapshot)
        XCTAssertEqual(WorkbenchConversationPresentation.thinkingItems(task).map(\.id), ["native.reasoning:a", "native.reasoning:b"])
        XCTAssertEqual(WorkbenchConversationPresentation.processItems(task).map(\.id), ["unknown"])
        XCTAssertEqual(WorkbenchConversationPresentation.visibleMessages(task).map(\.id), task.messages.map(\.id))
        XCTAssertEqual(try encoder.encode(snapshot), before)
        XCTAssertEqual(task.nativeState?.items.map(\.id), ["a", "empty", "unknown", "b"])
    }

    @MainActor func testDisclosureDefaultsCollapsedAndRetainsExpansionForStableTaskEntryIdentity() throws {
        let expansion = AgentThinkingExpansion()
        var message = WorkbenchMessage(role: "assistant", text: "first", sourceKind: "acp.agent_thought_chunk")
        let taskID = UUID()
        let first = AgentThinkingIdentity(taskID: taskID, entryID: try XCTUnwrap(AgentThinkingContent.acp(message)).id)
        XCTAssertFalse(expansion.isExpanded(first))
        expansion.setExpanded(true, for: first)
        message.text += "\r\nstream🙂"
        let update = AgentThinkingIdentity(taskID: taskID, entryID: try XCTUnwrap(AgentThinkingContent.acp(message)).id)
        XCTAssertEqual(first, update)
        XCTAssertTrue(expansion.isExpanded(update))
        let otherTask = AgentThinkingIdentity(taskID: UUID(), entryID: first.entryID)
        let newEntry = AgentThinkingIdentity(taskID: taskID, entryID: "native.reasoning:new")
        XCTAssertFalse(expansion.isExpanded(otherTask)); XCTAssertFalse(expansion.isExpanded(newEntry))
        expansion.setExpanded(true, for: newEntry)
        expansion.setExpanded(false, for: first)
        XCTAssertFalse(expansion.isExpanded(first)); XCTAssertTrue(expansion.isExpanded(newEntry))
        XCTAssertFalse(AgentThinkingExpansion().isExpanded(newEntry), "new presentation sessions start collapsed")
    }

    @MainActor func testNativeRawActionsUseOriginalDetailAndKeepOpenedSnapshotFixed() throws {
        let display = "1. summary\n\n```\r\n\t🙂\r\n```"
        let raw = "{\r\n\t\"summary\":[\"1. summary\"],\"future\":\"🙂  \"\r\n}\r\n"
        let view = AgentMarkdownMessageView(text: display, rawSource: raw)
        let snapshot = view.makeRawSnapshot()
        XCTAssertTrue(snapshot.isRecord)
        XCTAssertEqual(Data(snapshot.text.utf8), Data(raw.utf8))
        let pasteboard = NSPasteboard(name: .init("travelcat-thinking-tests-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(view.copyRaw(to: pasteboard))
        XCTAssertEqual(Data(try XCTUnwrap(pasteboard.string(forType: .string)).utf8), Data(raw.utf8))
        let newer = AgentMarkdownMessageView(text: display + "new", rawSource: raw + "updated")
        XCTAssertEqual(Data(snapshot.text.utf8), Data(raw.utf8))
        XCTAssertEqual(newer.makeRawSnapshot().text, raw + "updated")
        let textView = AgentMarkdownRawText.makeTextView(snapshot.text)
        textView.setSelectedRange(NSRange(location: 0, length: 3))
        AgentMarkdownRawText.update(textView, snapshot: snapshot.text)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 3))
        let ordinary = AgentMarkdownMessageView(text: display)
        XCTAssertFalse(ordinary.makeRawSnapshot().isRecord)
        XCTAssertEqual(ordinary.makeRawSnapshot().text, display)
    }

    @MainActor func testNativeProjectionCacheParsesOnlyChangedUTF8DetailIncludingEmptyResults() throws {
        var calls: [String] = []
        let cache = AgentNativeThinkingCache { item in calls.append(item.id); return AgentThinkingContent.native(item) }
        var task = WorkbenchTask(instanceID: UUID(), title: "cached")
        task.nativeState = NativeTaskState(items: [
            .init(id: "a", kind: "reasoning", title: "", detail: "Cafe\u{301}", status: "unknown"),
            .init(id: "empty", kind: "reasoning", title: "", detail: "{\"summary\":[]}", status: "unknown")])
        XCTAssertTrue(calls.isEmpty)
        let initial = cache.contents(for: task)
        XCTAssertEqual(calls, ["a", "empty"])
        XCTAssertEqual(initial.count, 1)
        for count in 0..<60 {
            task.unread = count.isMultiple(of: 2)
            task.status = count.isMultiple(of: 2) ? .running : .awaitingPermission
            task.nativeState?.items[0].status = count.isMultiple(of: 2) ? "unknown" : "inProgress"
            XCTAssertEqual(cache.contents(for: task).map(\.id), initial.map(\.id))
        }
        XCTAssertEqual(calls, ["a", "empty"], "ordinary refreshes and cached empty results do not parse again")
        task.messages.append(.init(role: "assistant", text: "final"))
        XCTAssertEqual(cache.contents(for: task).map(\.id), initial.map(\.id))
        task.nativeState?.items[0].detail = "Caf\u{e9}"
        XCTAssertEqual(cache.contents(for: task).map(\.id), initial.map(\.id))
        XCTAssertEqual(calls, ["a", "empty", "a"], "canonically equal but byte-different detail reparses only that item")
        XCTAssertEqual(Data(try XCTUnwrap(cache.contents(for: task).first?.rawSource).utf8), Data("Caf\u{e9}".utf8))
        var otherTask = task; otherTask.id = UUID()
        _ = cache.contents(for: otherTask)
        XCTAssertEqual(calls, ["a", "empty", "a", "a", "empty"], "task identity isolates cached records")
    }


    func testPartialFutureArraysStillDisplayEveryKnownStoredText() throws {
        let detail = "{\"text\":\"first\",\"summary\":[{\"text\":\"second\"},{\"future\":true},{\"text\":\"third\"}],\"content\":[\"fourth\"]}"
        let item = NativeTimelineItem(id: "mixed", kind: "reasoning", title: "", detail: detail, status: "unknown")
        let content = try XCTUnwrap(AgentThinkingContent.native(item))
        XCTAssertEqual(content.text, "first\n\nsecond\n\nthird\n\nfourth")
        XCTAssertEqual(content.rawSource, detail)
    }


    @MainActor func testLargeNativeRecordCopiesCompleteRawWhileReaderParsesOnlyDisplay() throws {
        let raw = "{\"summary\":[\"available\"],\"opaque\":\"" + String(repeating: "🙂\r\n\t", count: 30_000) + "\"}"
        let display = "available"
        var parses = 0
        let reading = AgentMarkdownReadingState { source in parses += 1; return .parse(source) }
        XCTAssertTrue(reading.update(display))
        let view = AgentMarkdownMessageView(text: display, rawSource: raw)
        let snapshot = view.makeRawSnapshot()
        XCTAssertFalse(reading.update(display))
        XCTAssertEqual(parses, 1)
        XCTAssertEqual(reading.content?.source, display)
        XCTAssertGreaterThan(snapshot.text.utf8.count, AgentMarkdownContent.maximumUTF8Bytes)
        let pasteboard = NSPasteboard(name: .init("travelcat-large-thinking-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(view.copyRaw(to: pasteboard))
        XCTAssertEqual(Data(try XCTUnwrap(pasteboard.string(forType: .string)).utf8), Data(raw.utf8))
        let rawView = AgentMarkdownRawText.makeTextView(snapshot.text, isRecord: snapshot.isRecord)
        XCTAssertEqual(rawView.accessibilityLabel(), "原始记录（打开时快照）")
        XCTAssertEqual(Data(rawView.string.utf8), Data(raw.utf8))
    }

}
