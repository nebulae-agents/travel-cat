# Markdown message reading verification — 2026-10-24

## Scope and source

Backlog item 6 adds local, read-only reading of assistant message bodies. Feature baseline: `542462a3cfd3b7252f995c59fb06338f854e9d9d`, branch `codex/pr-markdown-reading`. The implementation does not change `WorkbenchMessage.text`, persisted schema, transport, audit, approvals, control actions, drafts, attention, or conversation scroll handling. User and system messages retain their existing display.

`AgentMarkdownContent` keeps one immutable source plus UTF-8 source/content ranges. It recognizes ordered/unordered list markers, original numbering, indentation and continuation lines, and backtick/tilde fences with longer valid closing fences and incomplete streaming bodies. Other syntax is plain selectable text; there is no HTML, WebView, remote image loading, dependency or executable highlighter. Code labels are plain text. Code blocks have monospace text, horizontal/vertical scrolling and a 260-point height bound.

Code copying takes the original range between fence lines without trimming or joining. Raw copy takes the complete current message source. Opening raw view captures an immutable snapshot; subsequent message updates cannot replace its selection. The raw view is a selectable, read-only, non-rich native `NSTextView` with graphics/import/link/data detection disabled.

The retained reading state starts without parsing and updates only when source bytes change. The SwiftUI task identity and state comparison use UTF-8 equality, because Swift's canonical String equality would otherwise ignore distinct Unicode encodings.

## Bounds and large raw source

Rich parsing accepts at most 128 KiB of UTF-8 and 512 blocks. Oversized content displays at most an 8 KiB valid UTF-8 prefix with explicit full-raw actions; the complete source remains unchanged. The oversized check itself allocates at most 128 KiB + 1 bytes rather than duplicating an arbitrary raw source.

Current surrounding limits are an 8 MiB sidecar receive buffer (`AgentSidecarClient.receive`), 500,000-character ACP assistant accumulation (`AgentWorkbenchModel` update handling), and a 64 MiB encoded encrypted snapshot (`EncryptedWorkbenchStore`). These are different bounds; a character limit is not a byte limit. This feature does not alter them. Full raw text is loaded only after explicit action, with noncontiguous layout and no wrapping to avoid eager layout of the entire source. The component test loaded and verified all 8,100,000 source bytes in 0.739 seconds in this run. That is a component check, not a guarantee of native scrolling performance at the maximum snapshot size.

## Automated evidence

- Initial API RED: `/private/tmp/travelcat-markdown-red.log` (new feature types absent).
- Behavior RED: `/private/tmp/travelcat-markdown-behavior-red.log` (11 tests exercised the minimal skeleton, 28 failing assertions including missing copy output).
- Unicode regression RED: `/private/tmp/travelcat-markdown-unicode-red.log` (1 test, 4 expected failures: canonical-equal byte changes were skipped).
- GREEN: `Scripts/travel-cat-swift.sh test --filter AgentMarkdownContentTests`; 13 tests, 0 failures, no skips. Log: `/private/tmp/travelcat-markdown-green.log`.
- Related regressions: `Scripts/travel-cat-swift.sh test --filter 'AgentMarkdownContentTests|AgentWorkbenchPresentationTests|AgentWorkbenchNavigationTests|AgentWorkbenchSubmissionTests'`; 42 tests, 0 failures, no skips. Log: `/private/tmp/travelcat-markdown-regressions.log`.

Coverage includes mixed Chinese/English lists starting at 7, non-list numbers/minus, indentation/continuation, fence character/length/closing rules, inline backticks, incomplete streaming fences, independent expected UTF-8 byte arrays for CRLF/tabs/emoji/blank lines/end newline, source-range coverage, both renderer limits, complete raw copy after fallback, and unchanged encoded message/snapshot content. Copy tests execute the production copy actions on a uniquely named pasteboard and release it; they do not access the user's general clipboard. Native text component tests check read-only/selectable/plain configuration and selection preservation for the same snapshot. Sixty repeated identical updates cause only one parse; an actual byte change causes another.

## Packaging and native interaction

The original complete preview build script compiled the production application and `Tests/ManualAgentWorkbench/MarkdownPreview.swift` using:

```sh
TRAVEL_CAT_PREVIEW_SOURCE=MarkdownPreview.swift Scripts/preview-agent-workbench.sh
```

Exit 0. Build log: `/private/tmp/travelcat-markdown-preview-build.log`. Candidate: `/private/tmp/travelcat-agent-preview.1EWUT8/AgentWorkbenchPreview.app`. The existing wrapper emits a `--build-system native` deprecation warning. No preview app was launched by the implementer, and no formal app was installed.

The first full-window check found that this standalone conversation fixture omitted the production workbench surface, causing poor contrast under the system dark appearance. Only the fixture was corrected: its outer surface now uses the production `.workbenchSurface()` and its window uses Aqua appearance. The full original preview script was rerun successfully; production theme code was unchanged.

The offline fixture uses temporary encrypted storage and in-memory credentials, with no account, Keychain, network, sidecar or real workspace. It embeds the production conversation, approvals and Markdown views. Its controls switch between 1000×740 and 760×600, start/pause deterministic 500 ms source updates, and add an oversized source. It includes CRLF/tab/emoji code, a long horizontal line, 24 vertical code lines, a shorter fence inside a longer fence, and an unfinished streaming fence. Approval remains visible beside the composer.

The parent completed native interaction checks through CUA after the user unlocked the Mac. The candidate above used the production views with deterministic offline data, not a real runtime or installed app:

- Full front-window screenshots covered 1000×740 and 760×600 content sizes with the production theme, readable controls and the approval/composer visible. Stage Manager thumbnails from the initial background launch were excluded from layout evidence; opening the candidate through Finder brought it to the foreground.
- Copy Code was clicked and pasted through the native text context menu into the isolated composer. The readback contained the leading blank line, tab-indented emoji declaration, long horizontal line, all 24 numbered lines and the inner shorter fence. Exact CRLF/UTF-8 bytes remain established by the named-pasteboard tests, rather than AX text normalization.
- The code horizontal scroll bar changed from 0 to 0.5703971119133574 and returned to 0. Reading above the bottom exposed the new-reply control; selecting it returned the outer scrollbar to approximately 0.97657 while streaming continued.
- The raw snapshot was opened at appended sequence 69, then its Chinese/emoji sentence was selected. A later native readback retained the same selection and source ending at 69; closing the sheet showed the live message had reached 345. The raw Copy Complete action remained reachable.
- Adding the oversized source showed the explicit degraded-reading notice. Its raw view remained selectable and scrollable; AX returned all 12,000 repeated source lines (24,000 occurrences including the focused-field duplicate), instead of only the 8 KiB reading prefix.
- The existing draft text remained unchanged by raw viewing. The offline approval stayed visible and its explicit reject action removed the approval card. This fixture action executes no command.

These checks establish the listed local native reading interactions. They do not establish official Codex inference, a real ACP/Docker artifact flow, SSH, formal installation or runtime approval behavior. CUA had one transient timeout/reset and transition AX errors; the resulting state was reacquired before continuing, and attempts were not counted as acceptance without readback.

## Delivery boundary

No commit, index update, push, ref mutation, merge, installation or selected-pet change was performed by this implementation agent. `TravelPetData`, `.local`, original assets and prior feature code were preserved. Publication audits must be rerun by the parent on the final staged feature and updated stack base; this feature's untracked files have not yet been staged or audited as index contents.
