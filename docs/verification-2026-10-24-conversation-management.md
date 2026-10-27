# Conversation management verification — 2026-10-24

## Scope and storage contract

Approved item 7 adds local conversation search, rename, pin, archive, and restore. The existing schema remains 1. `WorkbenchTask` now has optional `customTitle`, `pinnedAt`, and `archivedAt`; `displayTitle` falls back to the unchanged original `title`.

An optional `cleanupEvidence` stores an explicit ACP cleanup receipt bound to the exact task ID and session ID, plus confirmation time. It is created only after the existing `stop` operation confirms `stopped`, or an existing failure explicitly confirms `taskRetained: false`. It survives encrypted reopening. New activity, unknown state, session change, live observation, or incompatible binding invalidates it. Legacy records and ordinary disconnection do not establish cleanup.

Rename, pin, archive, and restore perform a synchronous copy → encrypted store save → publish transaction. Failure leaves the published snapshot unchanged. These operations do not call runtime RPC, stop/detach, mutate messages or process bodies, or append audit entries. Pinning an already pinned task preserves its original pin time. Drafts remain independent and editable in the archived view.

## Search and presentation

- Search uses literal, case-insensitive matching over original titles, custom titles, and raw message text. Chinese and punctuation retain their literal meaning. Process items, audit records, runtime queries, network requests, and query logging are excluded.
- Rename accepts at most 160 characters and 2,048 UTF-8 bytes of single-line text. Search accepts at most 256 characters and 2,048 UTF-8 bytes. Invalid input produces a visible error; raw records are not truncated. An invalid query keeps the prior valid query.
- Pins sort before unpinned tasks, then by pin time descending, creation time descending, and UUID ascending. Replies and rename do not alter those ordering keys.
- The sidebar offers active and archived scopes. Mailbox, upstream, instance, and pending-request navigation reveal the exact task by adjusting the scope, Agent filter, and incompatible query. A navigation revision also handles reopening the already selected ID.
- Attention and mailbox projection continue to use all tasks. Pending approval, unread output, active execution, or unknown status makes an archived task reappear. The independent `modelApproval` append path is covered. Runtime event application does not depend on a successful metadata save. Accepted Native item/delta events also reveal an archived task and mark it unread when message content or visible process progress actually changes, including a known older turn's final body. Identical final replays, rejected late deltas, evidence bookkeeping without visible changes, and background-only reconciliation/observation retain archive state.

## Archive gates

Every new archive requires ready storage, a terminal task (`completed`, `cancelled`, or `failed`), read state, no pending permission/model approval, and no active control/submission/reconciliation operation. Unknown status is rejected.

ACP additionally requires a bound explicit cleanup receipt and no current live task. A stop response for an old session cannot remove or certify a newer session binding. While stop is pending, new replies and archive are blocked. ACP permission replies are tracked per task/request until their RPC receipts finish, even after the pending-choice row is removed. A concurrent confirmed stop therefore cannot bypass the still-running reply gate; stop itself remains available.

Native may remain observed and connected. It requires matching terminal turn evidence, terminal evidence for process items, no unresolved pending operation, and a current background observation with count 0. That observation is valid for 10 seconds and must match task, instance, execution, thread, turn, operation, connection generation, and revision. Disconnected, stale, mismatched, unknown, or nonzero observations are rejected. Archive does not claim that the Codex process ended.

Restore only changes archive metadata after successful storage; it does not require current runtime proof. Relevant existing safe controls remain available in the archived detail.

## Verification performed

1. Red: encrypted schema-1 round trip lost the three optional metadata fields — 3 expected assertion failures. Green: 2 legacy/encrypted-storage tests passed after adding compatible fields.
2. Red: behavior tests could not compile because the new management interfaces were absent. Green: management behavior tests passed after implementing those interfaces. One fixture was corrected to provide an explicit terminal runtime event after an unconfirmed cleanup; cleanup alone deliberately does not turn an unknown execution into a terminal result.
3. Red: two boundary tests exposed six assertions for an oversized single grapheme and a stop response received after session change. Green: byte bounds and exact stop-session binding resolved these failures.
4. Specification review exposed two additional P2 edges. Red: a suspended ACP permission RPC plus a confirmed stop bypassed the archive gate (2 failed assertions). Green: the dedicated test passed after tracking the reply to completion. Red: late Native output/process events stayed archived, while a repeated final turn manufactured unread state (19 failed assertions). Green: 4 focused Native activity/replay/background tests passed after the event-specific fix.
5. Final targeted regression after review fixes: **144 tests passed, zero failures**. This includes **24 new conversation-management tests**, 56 Native model tests, and existing audit/presentation/navigation/submission/draft/mailbox coverage.
6. The current production-source preview script compiled the independent `ConversationPreview.swift` fixture successfully. It uses temporary encrypted storage and in-memory credentials, with no account, real Keychain, sidecar, network, real workspace, or user state. It was compiled, not launched or installed by the implementing agent.
7. `github_preflight.py`, `audit-project-upload.sh`, and `git diff --check` passed. The upload audit reports `staged_bytes=0`; the implementation agent performed no Git index/ref/commit writes. The final staged audit remains the integrating agent's responsibility.
8. No tracked changes exist under original `Assets`, `Fixtures`, `Tests/Fixtures`, or `Sources/TravelUI/Resources`. `TravelPetData` and `.local` were not opened, moved, reset, staged, or deleted.

## Evidence and remaining acceptance

- `/private/tmp/travelcat-conversation-red-storage.log`
- `/private/tmp/travelcat-conversation-green-storage.log`
- `/private/tmp/travelcat-conversation-red-behavior.log`
- `/private/tmp/travelcat-conversation-green-behavior-2.log`
- `/private/tmp/travelcat-conversation-red-input-control.log`
- `/private/tmp/travelcat-conversation-green-final-core.log`
- `/private/tmp/travelcat-conversation-regression.log` (pre-review baseline)
- `/private/tmp/travelcat-conversation-red-pending-permission.log`
- `/private/tmp/travelcat-conversation-green-pending-permission.log`
- `/private/tmp/travelcat-conversation-red-late-native.log`
- `/private/tmp/travelcat-conversation-green-late-native.log`
- `/private/tmp/travelcat-conversation-regression-review-fixes.log` (current source)
- `/private/tmp/travelcat-conversation-preview-build.log` (pre-review baseline)
- `/private/tmp/travelcat-conversation-preview-build-review-fixes.log` (current source)
- `/private/tmp/travelcat-conversation-preflight.log`
- `/private/tmp/travelcat-conversation-preflight-review-fixes.log`
- `/private/tmp/travelcat-conversation-upload-audit.log`
- `/private/tmp/travelcat-conversation-upload-audit-review-fixes.log`

Preview app: `/private/tmp/travelcat-conversation-preview/AgentWorkbenchPreview.app`. Its toolbar offers 1000×740 and 760×600 layouts, pending-request reappearance, exact mailbox opening, late Native reply reappearance, and simulated metadata save failure. The fixture includes pinned Chinese/literal queries, an archived task with a retained draft, and a legacy ACP record without cleanup evidence.

The preview build emitted the existing `TravelCatApp.swift` weak-capture warning and the preview script's deprecated `--build-system native` warning. No new conversation-management source warning was reported.

Native UI interaction is reserved for the main agent, so this document does not claim visual or mouse/keyboard acceptance. Full aggregate/runtime testing, real runtime acceptance, remote publication/CI, formal installation, and GitHub merge are not established by this verification. The main agent will merge the separately validated common Receipt/Visibility cleanup foundation after this feature is frozen/reviewed; those common source changes were not copied into this feature.
