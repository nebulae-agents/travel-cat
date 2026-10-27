import AppKit
import XCTest

@MainActor
final class AcceptanceApplicationMenuTests: XCTestCase {
    private final class Target: NSObject {
        var actions: [String] = []
        @objc func showWindow() {}
        @objc func close() {}
        @objc func paste(_ sender: Any?) { actions.append("paste") }
    }

    private func make(_ target: Target) -> NSMenu {
        AcceptanceApplicationMenu.make(target: target, show: #selector(Target.showWindow), close: #selector(Target.close))
    }

    func testExistingWindowAndCloseShortcutsRemainBoundToOwner() throws {
        let target = Target()
        let menu = try XCTUnwrap(make(target).items.first?.submenu)
        XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.map(\.keyEquivalent), ["0", "q"])
        for item in menu.items where !item.isSeparatorItem { XCTAssertTrue(item.target === target) }
    }

    func testStandardEditingCommandsUseTheActiveResponder() throws {
        let menu = make(Target())
        let edit = try XCTUnwrap(menu.items.first { $0.title == "编辑" }?.submenu)
        let entries = edit.items.filter { !$0.isSeparatorItem }
        XCTAssertEqual(entries.map { NSStringFromSelector($0.action!) }, ["undo:", "redo:", "cut:", "copy:", "paste:", "selectAll:"])
        XCTAssertEqual(entries.map(\.keyEquivalent), ["z", "z", "x", "c", "v", "a"])
        XCTAssertEqual(entries[1].keyEquivalentModifierMask, [.command, .shift])
        XCTAssertTrue(edit.autoenablesItems)
        for item in entries { XCTAssertNil(item.target); XCTAssertTrue(item.keyEquivalentModifierMask.contains(.command)) }
    }

    func testCommandPasteActuallyDispatchesWithoutReadingTheClipboard() throws {
        _ = NSApplication.shared
        let target = Target()
        let menu = make(target)
        let edit = try XCTUnwrap(menu.items.first { $0.title == "编辑" }?.submenu)
        let paste = try XCTUnwrap(edit.items.first { $0.action == #selector(Target.paste(_:)) })
        edit.autoenablesItems = false; paste.target = target; paste.isEnabled = true
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: 0, context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
        XCTAssertTrue(menu.performKeyEquivalent(with: event))
        XCTAssertEqual(target.actions, ["paste"])
    }
}
