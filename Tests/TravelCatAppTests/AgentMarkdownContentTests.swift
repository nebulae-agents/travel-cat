import AppKit
import Foundation
import XCTest
@testable import TravelCatApp

final class AgentMarkdownContentTests: XCTestCase {
    func testMixedListsKeepOriginalNumbersMarkersIndentAndContinuation() {
        let source = "说明 Intro\n7. 中文 first\n   continuation 继续\n9) second\n  - nested 子项\n\t+ tabbed\n* final\n"
        let content = AgentMarkdownContent.parse(source)
        XCTAssertFalse(content.isDegraded)
        XCTAssertEqual(content.blocks.map(\.kind), [.text, .listItem(marker: "7.", indentation: 0), .listItem(marker: "9)", indentation: 0), .listItem(marker: "-", indentation: 2), .listItem(marker: "+", indentation: 4), .listItem(marker: "*", indentation: 0)])
        guard content.blocks.count >= 4 else { return }
        XCTAssertEqual(content.text(in: content.blocks[1].contentRange), "中文 first\n   continuation 继续\n")
        XCTAssertEqual(content.text(in: content.blocks[2].contentRange), "second\n")
        XCTAssertEqual(content.text(in: content.blocks[3].sourceRange), "  - nested 子项\n")
        XCTAssertEqual(content.blocks.map { content.text(in: $0.sourceRange) }.joined(), source)
    }

    func testNumbersMinusInlineFencesAndComplexSyntaxRemainPlainText() {
        let source = "2026.10.24\n7.no space\n-42 degrees\nword - item\n1234567890. too many digits\ninline ```swift```\n![external](https://fixture.invalid/a.png)\n<script>alert(1)</script>\n# heading stays plain\n"
        let content = AgentMarkdownContent.parse(source)
        XCTAssertEqual(content.blocks.map(\.kind), [.text])
        XCTAssertEqual(content.text(in: content.blocks[0].contentRange), source)
    }

    func testBacktickFenceUsesLengthCharacterAndWhitespaceForClosure() {
        let source = "before\n````swift\none\n```\n~~~~\n```` trailing\n````` \t\nafter\n"
        let content = AgentMarkdownContent.parse(source)
        XCTAssertEqual(content.blocks.map(\.kind), [.text, .code(language: "swift", closed: true), .text])
        guard content.blocks.count >= 2 else { return }
        XCTAssertEqual(content.text(in: content.blocks[1].contentRange), "one\n```\n~~~~\n```` trailing\n")
        XCTAssertEqual(content.text(in: content.blocks[1].sourceRange), "````swift\none\n```\n~~~~\n```` trailing\n````` \t\n")
    }

    func testTildeFenceAndUnfinishedStreamingFencePreserveAvailableCode() {
        let closed = AgentMarkdownContent.parse("  ~~~text label\n  raw\n   ~~~~\n")
        XCTAssertEqual(closed.blocks.map(\.kind), [.code(language: "text label", closed: true)])
        XCTAssertEqual(closed.text(in: closed.blocks[0].contentRange), "  raw\n")
        for (source, expected) in [("```swift", ""), ("```swift\n", ""), ("```swift\npart🙂\n`", "part🙂\n`")] {
            let content = AgentMarkdownContent.parse(source)
            XCTAssertEqual(content.blocks.map(\.kind), [.code(language: "swift", closed: false)])
            XCTAssertEqual(content.text(in: content.blocks[0].contentRange), expected)
        }
        XCTAssertEqual(AgentMarkdownContent.parse("```bad`info\nplain").blocks.map(\.kind), [.text])
        XCTAssertEqual(AgentMarkdownContent.parse("    ```\nplain").blocks.map(\.kind), [.text])
    }

    func testCodeSliceBytesMatchIndependentCRLFTabsEmojiBlankLinesAndFinalNewline() {
        let source = "前言🙂\r\n```swift\r\n\r\n\tlet 表情 = \"🙂\"  \r\n\t\r\n```\r\n结尾"
        let content = AgentMarkdownContent.parse(source)
        guard content.blocks.count >= 2 else { XCTFail("code block missing"); return }
        let code = content.text(in: content.blocks[1].contentRange)
        let expected: [UInt8] = [13,10,9,108,101,116,32,232,161,168,230,131,133,32,61,32,34,240,159,153,130,34,32,32,13,10,9,13,10]
        XCTAssertEqual(Array(code.utf8), expected)
        XCTAssertEqual(content.source, source)
        XCTAssertEqual(content.blocks.map { content.text(in: $0.sourceRange) }.joined(), source)
        let noFinalNewline = AgentMarkdownContent.parse("~~~\r\nA\t🙂")
        XCTAssertEqual(Array(noFinalNewline.text(in: noFinalNewline.blocks[0].contentRange).utf8), [65,9,240,159,153,130])
    }

    func testByteLimitUsesValidPrefixAndKeepsCompleteRawSource() {
        let exact = String(repeating: "a", count: AgentMarkdownContent.maximumUTF8Bytes)
        XCTAssertFalse(AgentMarkdownContent.parse(exact).isDegraded)
        let source = String(repeating: "a", count: 8191) + "🙂" + String(repeating: "界", count: 50000)
        let content = AgentMarkdownContent.parse(source)
        XCTAssertTrue(content.isDegraded)
        XCTAssertTrue(content.blocks.isEmpty)
        XCTAssertEqual(content.preview, String(repeating: "a", count: 8191))
        XCTAssertEqual(content.source, source)
        XCTAssertLessThanOrEqual(content.preview.utf8.count, 8192)
        XCTAssertFalse(content.preview.contains("�"))
    }

    func testBlockLimitBoundsWorkAndRetainsFullRaw() {
        let exact = (0..<512).map { "- item \($0)\n" }.joined()
        XCTAssertEqual(AgentMarkdownContent.parse(exact).blocks.count, 512)
        let source = exact + "- overflow\n"
        let content = AgentMarkdownContent.parse(source)
        XCTAssertTrue(content.isDegraded)
        XCTAssertTrue(content.blocks.isEmpty)
        XCTAssertEqual(content.source, source)
        XCTAssertEqual(content.preview, String(source.prefix(8192)))
    }

    func testReadingDoesNotChangeMessageOrEncodedSnapshot() throws {
        var task = WorkbenchTask(instanceID: UUID(), title: "unchanged")
        task.messages = [.init(role: "assistant", text: "7. 中文\r\n~~~\r\n\t🙂\r\n~~~\r\n")]
        var snapshot = WorkbenchSnapshot(); snapshot.tasks = [task]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(snapshot)
        let reading = AgentMarkdownContent.parse(task.messages[0].text)
        _ = reading.blocks.map { reading.text(in: $0.contentRange) }
        XCTAssertEqual(try encoder.encode(snapshot), before)
        XCTAssertEqual(Data(snapshot.tasks[0].messages[0].text.utf8), Data("7. 中文\r\n~~~\r\n\t🙂\r\n~~~\r\n".utf8))
    }

    @MainActor func testReadingStateParsesOnlyWhenContentChangesAndRawSnapshotStaysFixed() {
        var parses = 0
        let reading = AgentMarkdownReadingState { source in parses += 1; return .parse(source) }
        XCTAssertEqual(parses, 0, "view/state initialization must not parse")
        XCTAssertTrue(reading.update("```\nfirst"))
        let snapshot = reading.rawSnapshot()
        for _ in 0..<60 { XCTAssertFalse(reading.update("```\nfirst")) }
        XCTAssertEqual(parses, 1)
        XCTAssertTrue(reading.update("```\nfirst second\n```"))
        XCTAssertEqual(parses, 2)
        XCTAssertEqual(snapshot.text, "```\nfirst")
        XCTAssertEqual(reading.rawSnapshot().text, "```\nfirst second\n```")
    }

    @MainActor func testCanonicallyEquivalentUnicodeStillUpdatesExactSourceBytes() {
        let decomposed = "```\nCafe\u{301}\n```"
        let composed = "```\nCaf\u{e9}\n```"
        XCTAssertEqual(decomposed, composed, "Swift canonical equality is deliberately insufficient for source identity")
        XCTAssertNotEqual(AgentMarkdownSourceIdentity(decomposed), AgentMarkdownSourceIdentity(composed))
        var parses = 0
        let reading = AgentMarkdownReadingState { source in parses += 1; return .parse(source) }
        XCTAssertTrue(reading.update(decomposed))
        XCTAssertTrue(reading.update(composed))
        XCTAssertEqual(parses, 2)
        XCTAssertEqual(Array(reading.rawSnapshot().text.utf8), Array(composed.utf8))
        let view = AgentMarkdownRawText.makeTextView(decomposed)
        AgentMarkdownRawText.update(view, snapshot: composed)
        XCTAssertEqual(Array(view.string.utf8), Array(composed.utf8))
    }

    @MainActor func testLargeRawSnapshotIsCompleteWithDeferredLayout() {
        let source = String(repeating: "0123456789ABCDEF\r\n", count: 450_000)
        XCTAssertGreaterThan(source.utf8.count, 8_000_000)
        let view = AgentMarkdownRawText.makeTextView(source)
        XCTAssertTrue(view.layoutManager?.allowsNonContiguousLayout == true)
        XCTAssertFalse(view.textContainer?.widthTracksTextView ?? true)
        XCTAssertEqual(view.string.utf8.count, 8_100_000)
        XCTAssertTrue(view.string.utf8.elementsEqual(source.utf8))
    }

    @MainActor func testActualCopyActionsUseCompleteOriginalAndExactCodeOnNamedPasteboard() throws {
        let pasteboard = NSPasteboard(name: .init("travelcat-markdown-tests-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let source = "~~~\r\n\t🙂  \r\n\r\n~~~\r\n" + String(repeating: "界", count: 50000)
        let content = AgentMarkdownContent.parse(source)
        XCTAssertTrue(content.isDegraded)
        XCTAssertTrue(AgentMarkdownCopy.raw(source, to: pasteboard))
        XCTAssertEqual(Data(try XCTUnwrap(pasteboard.string(forType: .string)).utf8), Data(source.utf8))
        let codeContent = AgentMarkdownContent.parse("~~~\r\n\t🙂  \r\n\r\n~~~\r\n")
        XCTAssertTrue(AgentMarkdownCopy.code(codeContent, block: codeContent.blocks[0], to: pasteboard))
        XCTAssertEqual(Array(try XCTUnwrap(pasteboard.string(forType: .string)).utf8), [9,240,159,153,130,32,32,13,10,13,10])
        XCTAssertFalse(AgentMarkdownCopy.code(.parse("plain"), block: AgentMarkdownContent.parse("plain").blocks[0], to: pasteboard))
    }

    @MainActor func testRawTextViewIsReadOnlySelectableAndKeepsSelectionForSameSnapshot() {
        let view = AgentMarkdownRawText.makeTextView("first\r\n\t🙂")
        XCTAssertFalse(view.isEditable); XCTAssertTrue(view.isSelectable); XCTAssertFalse(view.isRichText)
        XCTAssertFalse(view.importsGraphics)
        XCTAssertEqual(view.string, "first\r\n\t🙂")
        view.setSelectedRange(NSRange(location: 0, length: 5))
        AgentMarkdownRawText.update(view, snapshot: "first\r\n\t🙂")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 5))
    }
}
