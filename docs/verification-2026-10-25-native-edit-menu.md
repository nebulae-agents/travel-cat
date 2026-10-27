# Standalone Native preview editing menu (2026-10-25)

This follow-up is stacked after PR #24 and PR #25. It changes the manual preview harness and its tests, not the formal SwiftUI application's editing behavior.

## Reproduction and change

The manual NSApplication preview installed only its application menu. A user could paste into the message editor through the text view's context menu, but Command-V did not paste. The formal SwiftUI application supplies standard menus through its normal scene, whereas this standalone AppKit harness must register them itself.

The preview now obtains its application menu from a shared test-support factory. It adds Edit with Undo, Redo, Cut, Copy, Paste and Select All, using standard responder selectors and Command shortcuts (Command-Shift-Z for Redo). Edit actions keep nil targets and automatic validation, so the current editor controls availability and handling. Existing show-window and bounded-close actions remain bound to their existing owner. The preview build explicitly compiles the same factory tested by the Swift test target; the formal application target does not include this test support.

## Verification boundary

Extracting the previous application-only menu produced two real test failures for the missing Edit submenu while the existing show/close shortcut test passed. Adding Edit made the menu contract checks pass. The first dispatch test matched Command-V but did not deliver an action because that isolated test had not initialized its own NSApplication. Initializing NSApplication, without changing the menu implementation, made the same synchronous action assertion pass.

The dispatch regression routes Command-V through NSMenu.performKeyEquivalent to a test object. It never reads or changes the system clipboard. It proves shortcut matching and action delivery; because the test supplies an explicit target, it does not prove the running preview's nil-target path reaches the current SwiftUI message editor. Real Command-V entry, retained draft text, Cut/Copy/Select All and normal preview close still require manual acceptance. The native capture tool continues to report ScreenCaptureKit -3811; a tool attempt is not UI proof.

The final serial focused regression passed all 91 tests (three menu cases plus the existing 88 focused cases). R16 standalone compilation and two preview-packaging checks passed. Independent read-only review found no confirmed P1/P2 and retained the real-editor acceptance limitation above. Detailed private session receipts are retained locally; this public record contains no account/session status or model-list results.
