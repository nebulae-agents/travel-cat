# Artifact changes and viewed-version comparisons — 2026-10-24

This change is item 5 of the approved workbench improvements. It adds runtime SHA evidence, immutable previews, encrypted viewed-version history and bounded comparisons. It does not claim that a file was authored by the Agent or reconstruct a complete turn diff.

## Behavior and evidence boundaries

- ACP captures its manifest under the prompt turn lock after input import and immediately before `session/prompt`. A new execution clears the previous baseline before collecting its own evidence. Native captures immediately before `turn/start` and clears the prior baseline before attempting that scan. If the scan fails, no turn is submitted and a later explicit read stays unknown instead of reusing old execution evidence. A completion notification received before the start response cannot revive a completed turn.
- Each binding and prompt execution has a runtime-owned identity. The changes response includes binding/execution identity, known turn identity, baseline capture time, current check time, separate inventory/hash coverage and a reason when coverage is incomplete. Resume starts a new binding without pretending that history supplies a real prompt baseline.
- Only explicit file open/refresh and actual prompt submission scan files. Five-second background status observations do not scan the workspace.
- A same-size change is detected by SHA. Missing baselines, incomplete inventories, unsafe files, exhausted hash budgets and file races retain `unknown` where evidence is insufficient. Incomplete inventory prevents attributing a listed path as new/modified/unchanged. An existing unsafe or oversized path remains present as metadata, so an unavailable baseline hash is never treated as absence.
- Legacy `artifacts` and `export` remain supported. New `artifact_changes` and `native_artifact_changes` provide the evidence used by the workbench.

## Filesystem and request bounds

The manifest reads at most 8 MiB, hashes at most 4 MiB per file, retains at most 200 file entries, discovers at most 1,000 entries and follows at most eight directory levels. Hidden/credential-like names retain their existing denial policy. Symlinks, hardlinks and special files are not read; safe relative path presence is retained with an unavailable-hash reason.

Reads pin directory device/inode identity, refuse links and compare file metadata before and after reading. Export additionally rewalks its complete relative path from the pinned root after reading; a replaced child directory cannot confirm bytes for the newly named child. Native pins the configured workspace at binding time and rechecks the configured path after reads. ACP sends its pinned workspace identity back to the trusted workspace reader.

Native observations share the existing nonqueued read slot and a five-second observation deadline, including scope-lock acquisition. Native artifact filesystem work releases the control-operation lock; stale or late results are rejected afterward. ACP explicit artifact reads have a nonqueued task slot and a five-second workspace process timeout. Swift explicit reads use 15 seconds and reject results after local binding/revision changes. Control RPC deadline permissions were not broadened.

Filesystem calls inside the kernel cannot be forcibly cancelled by this code. The five-second checks and bounded data work are observation limits, not a guarantee that every possible filesystem syscall returns within five seconds. Native control operations are not held behind that filesystem work. The two-sided scope and configured-path checks prevent publishing a stale result after a control or path change.

## Preview, confirmation and history

Refresh preserves the existing preview bytes. A changed current SHA marks the preview as old and offers read-new/compare actions. Missing current SHA is shown as unverified. Download writes the exact selected preview bytes, including the original line endings; downloading an old preview never silently substitutes current file bytes.

Confirmation rereads the current file in a fresh bound scope and requires its SHA to match the preview. Confirmation records are keyed by `(path, SHA)` and remain independent of unread status, approvals, task completion and the rolling viewed-history records. Confirming another SHA no longer deletes an earlier confirmation.

The optional `artifactVersions` field remains inside schema 1 and the existing AES-GCM store/key. Plaintext store writes refuse populated artifact history. Listing or merely fetching bytes does not itself create viewed history: the UI records history after presenting a preview or a comparison. History keeps the most recent two distinct viewed SHAs per path; only that path rolls. Earlier confirmation SHA metadata stays in `artifactReviews`. Reopening saved text updates its viewed timestamp/order through the same recorder: A → B → reopen A → C retains A and C. The saved-text action presents validated immutable bytes before persisting the new viewing order, so a persistence failure leaves the preview visible and surfaces an error.

History permits 16 paths per task, 128 version metadata records globally, UTF-8 bodies up to 256 KiB each and at most 2 MiB of saved text globally. Reaching a global/body/path capacity stops the applicable new storage and displays a reason. It does not clear another task, path, audit record or draft to free capacity. Binary data, images, PDFs, non-UTF-8 content and oversized text retain SHA/size/reason metadata only. Legacy tasks without the optional field continue to decode.

## Comparison limits

Only actually saved UTF-8 text can supply an old body. Missing old bodies, binary formats and different paths produce a SHA/size metadata explanation. HTML is displayed as plain text. Shared UTF-8/control-character classification accepts Chinese, tabs, LF and CRLF while rejecting binary control characters and invalid UTF-8.

LCS work is limited to 2,000 lines per side, 1,000,000 comparison cells and 256 KiB of output. Line-ending-only differences are identified explicitly. Unicode normalization byte differences are preserved as changes, rather than incorrectly being called line-ending changes. Exceeding a comparison limit returns an explanation instead of a truncated result presented as complete.

## Verification

All commands used the repository Swift wrapper or Python 3.14 with bytecode writes disabled. Logs are local temporary verification output and are not repository artifacts.

| Evidence | Result | Log filename |
| --- | --- | --- |
| Initial runtime RED after correcting test import setup | 8 tests: 2 failures, 5 missing-feature errors, 1 pass | `artifact-versions-python-red.log` |
| First runtime GREEN | 8 tests, 0 failures | `artifact-versions-python-green.log` |
| Root/caller-scope RED | 12 tests, 2 failures | `artifact-versions-python-red2.log` |
| New-execution/incomplete-inventory RED | 17 tests, 2 failures | `artifact-versions-python-red3.log` |
| Relative-ancestor replacement RED | 18 tests, 1 failure | `artifact-versions-python-red4.log` |
| Review regression RED: failed Native baseline scan | 19 tests, 1 failure; old capture time incorrectly survived a new execution | `artifact-versions-python-review-red.log` |
| Final complete runtime suite | 199 tests, 0 failures | `artifact-versions-python-final.log` |
| Initial Swift RED | Compile failure for the absent history/comparison APIs; no tests executed | `artifact-versions-swift-red.log` |
| First Swift GREEN | 14 artifact tests, 0 failures | `artifact-versions-swift-green.log` |
| Unicode-normalization RED | 16 tests; 1 failed test containing 3 failed assertions | `artifact-versions-swift-red2.log` |
| Preview-state RED | Compile failure for absent preview-state API; no tests executed | `artifact-versions-swift-red3.log` |
| Different-path comparison RED | 20 tests, 1 failure | `artifact-versions-swift-red4.log` |
| Output limit including explanatory text RED | 21 tests, 1 failure (262,168 bytes exceeded 262,144) | `artifact-versions-swift-red5.log` |
| Review regression RED: saved-text reopen action | Compile failure for the absent shared action used by reopen/recency and save-failure cases; no tests executed | `artifact-versions-swift-history-review-red.log` |
| Final affected Swift suite | 186 tests, 0 failures: 163 app/model/storage tests plus 23 packaging contracts; includes 23 artifact tests | `artifact-versions-swift-final.log` |

The runtime tests use real temporary filesystem bytes with controlled native transport/ACP protocol fixtures. They cover same-size SHA changes, imported-input baseline ordering, resumed unknown state, unsafe/root/relative-ancestor replacement, stale binding/execution, nonqueued reads, scope-lock deadlines, no background scan, early turn completion and metadata-only baseline audit records. `git diff --check`, `Scripts/github_preflight.py` and `Scripts/audit-project-upload.sh` passed on the unstaged implementation checkout. The latter reported zero staged bytes; the publishing owner must repeat both audits after staging its final reviewed candidate. Protected source/media/state paths have no Git diff.

Swift covers native/ACP routing, fresh-SHA confirmation, preserved confirmation history, immutable old downloads, encrypted restoration, global/path/body capacities, binary/PDF metadata fallback, Chinese/CRLF/Unicode byte differences and comparison limits. Existing real ACP stdio fixtures now read an actual temporary workspace baseline and wait for the actual prompt write before cancellation.

## Not verified by these results

The Mac remained locked. This item has no new human/native interaction acceptance for opening, refreshing, comparing, selecting saved history, confirmation or save-panel downloads. The existing automated render contract passing within the affected suite is not a substitute for that interaction acceptance. No official Codex live inference or real Docker artifact workflow is claimed by the controlled protocol tests. No SSH acceptance was attempted. No formal installation, merge, publication or Git mutation was performed by this implementation task.
