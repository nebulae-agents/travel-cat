# Local acceptance coverage — 2026-10-24

## Scope and evidence boundary

Approved item 8 is local acceptance and CI coverage on top of `5923e0139f423a1a5bf04844826a79dd9c090ca3`. It does not authorize a formal installation, SSH, a merge, or account/credential migration. This implementing agent did not launch a preview or operate the UI. Native and artifact UI acceptance belongs to the main agent and must be recorded separately from headless checks.

The production runtime changes are the successful `Task.start()` result adding its own already-generated `containerName` next to `sessionId`, and canonicalizing the case of the same model-approval UUID before lookup. This allows an opt-in test to bind a returned task ID to an inspected container without enumeration, guessed names, global context changes, or a write RPC. There is no new workspace-write RPC. The review revision also adds a bounded `AgentSidecarClient.waitForExit` observer for exact launched child lifetimes, independent of transport generations and public callbacks; existing production shutdown still sends EOF and does not stop the Native daemon.

## CI

- Keep checkout `actions/checkout@v7`, artifact upload `actions/upload-artifact@v7.0.2`, and all existing source/tooling/plugin/skill/agent/Swift/prompt/upload checks.
- Add `actions/setup-python@v7` with Python 3.13, explicitly assert Python >=3.11, and discover the complete `Tests/AgentRuntimeTests/test_*.py` suite.
- Explicitly unset inherited Docker live-test switches in the toolchain, runtime, and both Swift steps. Live integration remains opt-in. The existing workflow contract now also verifies this new runtime step/version boundary.
- Local Python used for runtime and Scripts suites: Homebrew 3.14.6. A current GitHub run is not established by these local results.

## Automated local results

| Check | Current result |
| --- | --- |
| `Tests/AgentRuntimeTests`, complete discovery | 200 tests, zero failures, 11.718 seconds |
| `Scripts/tests`, complete discovery after review | 162 tests, zero failures, 133.134 seconds |
| Latest selected Swift Native, workbench, conversation and exact sidecar-exit contracts | 121 tests executed, zero skips/failures, 3.694 seconds |
| Earlier affected Swift suite including the gated live test | 80 tests recorded, 1 live opt-in skipped, zero failures; 79 actually ran |
| Isolated preview packaging contracts | 2 tests passed |
| Native cleanup safety contracts | 7 tests passed; an in-memory copy with the process-identity gate deliberately removed failed its regression test |
| Exact sidecar subprocess-exit contracts | 4 tests passed, including an invalidated old transport generation with a still-running child |
| Real Docker/ACP opt-in, current fixed runtime | 1 executed, zero skips/failures, 2.649 seconds |
| Upload tooling, plugin, skill, agent contracts | Passed |
| `github_preflight.py`, upload audit, `git diff --check` | Passed before this document; repeated before freeze |

The existing runtime test first failed because `containerName` was absent (39 tests, one expected failure), then passed after the minimal metadata change. The packaging test first failed because the new packaging capability was absent, then both contracts passed. The first complete Scripts run found one existing workflow contract failure: adding live switches before the old `unset` prefix made its parser miss all three offline blocks. The fix preserves the old prefix, appends the new switches, and strengthens that contract; the complete 160-test rerun passed. Final self-review then added one cleanup case for selecting an executable different from the initial UI candidate; cleanup binds the actual successful first connection, still requiring the exact receipt/process/config identity. That complete Scripts suite passed 161 tests. The review revision then added the fail-closed actual-sidecar-exit contract; the final complete Scripts suite passed 162 tests.

The initial real run took 124.233 seconds and passed the old audit-only assertions. A stronger rerun **failed** its new explicit-deny-acknowledgement assertion: artifact operations took only 1.235 seconds, but the approval expired at 120 seconds rather than accepting the explicit deny. The production defect was Swift `UUID.uuidString` uppercasing the call ID while the sidecar dictionary stored the lower-case UUID and performed a raw string lookup. This initial result is not counted as successful explicit rejection.

A new regression first failed on the upper-case call ID, then passed after minimal canonical UUID normalization. The exact task-local hash, deadline, stopped state and one-shot gates remain. The regression additionally rejects another UUID, wrong request SHA, replay, and expired approval; the audit-runtime subset passed 23 tests and the complete runtime passed 200. The final fixed real rerun completed in **2.649 seconds**, including **1.190509 seconds** of artifact operations while approval was pending and **1.418011 seconds** from approval observation through cleanup. Explicit deny was acknowledged, exactly one model request and one `allow=false` decision were observed, and model response/completion counts were zero. The adapter's final `completed` task status is its ACP completion after rejection, not successful official model inference. All completed real runs confirmed their exact container cleanup. A final static check also caught an invalid IDAT CRC in the original small PNG constant; the final run uses a deterministic 69-byte RGB PNG with all chunk CRCs and decompressed pixel bytes independently checked. This does not change the separate 640×360 offline UI fixture PNG.

Current local evidence: `/private/tmp/travelcat-r8-runtime-tests-final.log`, `/private/tmp/travelcat-r8-r2-scripts.log`, `/private/tmp/travelcat-r8-r2-regression.log`, and `/private/tmp/travelcat-r8-swift-live-freeze.log`. The review revision changes child-exit observation and offline fixture harnesses only; the successful real Docker run was retained and not repeated.

Full aggregate Swift testing is intentionally reserved for the main agent after separately authorized item 9. Do not infer that full Swift, CI, UI, or installed-app acceptance passed from the selected suite.

## Real Docker and artifact contract

Verified local server: Docker 29.2.1, explicit context `colima-travelcat-agent`, locally existing image `localhost:5000/travelcat-codex-acp@sha256:9e1ac8187c77450bb885f269cf82464aea77fff820fd798a6b1bd8012b838bce`. No pull or global context switch occurred.

The unique opt-in live test imports `report.txt` A, PNG, and a two-page PDF before the real ACP prompt baseline. During the first real model approval, production list/load APIs verify imported files are `unchanged`, inventory/hash completeness, execution/binding metadata, exact bytes and SHA. All three previews are confirmed and downloaded through the production model API. Calling the model's history method here tests persistence and does not count as native visual acceptance.

The transparent real `AgentSidecarClient` wrapper captures only the successful start response's exact task/container association and acknowledged deny. Inspection requires the returned name, pinned image, non-root `65532:65532`, read-only filesystem, network `none`, and no host mounts. Only the inspected exact container ID receives the external same-size A→B test write. Production refresh must show `modified` and a different SHA at unchanged size; the old A remains immutable/downloadable and fails a new confirmation attempt. B can be loaded and confirmed while A's prior path+SHA confirmation remains. PNG/PDF history stores metadata only.

The final model approval is rejected. Audit checks require `model.request`, `model.decision`, `model.failed`, baseline, verified-confirmation, and completed-download events, and forbid model completion/response. This is real Docker + real ACP RPC + real approval/read/export evidence; the changed file was written by the external test, so SHA change does not establish Agent authorship or official model-generated PNG/PDF.

All exit paths perform bounded task stop. A thrown failure, including unconfirmed cleanup, retains the test root and failure metadata. The test root is removed only after production `!isLive` and exact-ID Docker inspection confirms no such container while the daemon remains reachable. XCTest assertion failures remain visible in the test log and must be interpreted alongside the result JSON. There is no defer that silently removes an unconfirmed container or its evidence.

Final evidence is `/private/tmp/travelcat-r8-live-result.json` together with a passing current `/private/tmp/travelcat-r8-swift-live-freeze.log`. The JSON alone is not a test verdict. The fixed passing run recorded these exact download hashes:

| Download | SHA-256 |
| --- | --- |
| `preview.png` | `dee4b975389e75fef6d0f2979530d79f3f7d322b63740c368bcd7ab3e4f447a1` |
| `report-new-B.txt` | `f75e543df40f1f05f931fe4c975d40f86bc5d3607752c8945d5284edf3f9a19e` |
| `report-old-A.txt` | `c84057ca677dbbdd91c603b3bc33ebc1a497245088cfb76269c85c7c01f80aa2` |
| `report.txt` | `c84057ca677dbbdd91c603b3bc33ebc1a497245088cfb76269c85c7c01f80aa2` |
| `two-pages.pdf` | `1eaf964f8fb99a0264747a50071f011df12fe852302eaaabf4ee7381bcd19745` |

## Native UI fixtures and operation

`Scripts/prepare-agent-preview.py` creates a fresh bundle, validates its simple app name/reverse-domain bundle ID, refuses to overwrite an existing preview, and copies exactly the production AgentRuntime top-level `.py` files, excluding caches. Existing raster resources are only read/copied; originals are not replaced. `TRAVEL_CAT_PREVIEW_NAME`, `TRAVEL_CAT_PREVIEW_BUNDLE_ID`, and `TRAVEL_CAT_PREVIEW_SOURCE` are fixed before first launch. This agent builds but does not launch previews.

Current review-revision bundles use independent R8R2 identities, retain the current runtime snapshot, and include the corrected fixture harnesses:

- Conversation: `/private/tmp/travelcat-conversation-acceptance-20261024-r8-r2/TravelCatConversationAcceptanceR8R2.app`, bundle ID `com.nebulae.travelcat.conversation-acceptance.r8r2`. The mailbox fixture now injects unread through production `model.mutate` before opening the mailbox. It does not change production navigation or add a view observer.
- Native: `/private/tmp/travelcat-native-acceptance-20261024-r8-r2/TravelCatNativeAcceptanceR8R2.app`, bundle ID `com.nebulae.travelcat.native-acceptance.r8r2`. Uses actual sidecar, Native setup, workbench, composer/conversation, and interrupt toolbar. The independent empty workspace and encrypted store/profile are siblings; no default Codex profile or real worktree is selected. It does not automatically connect, log in, or send a task. Its close path publishes detached metadata only after bounded exact sidecar termination observation.
- Artifact: `/private/tmp/travelcat-artifact-acceptance-20261024-r8-r2/TravelCatArtifactAcceptanceR8R2.app`, bundle ID `com.nebulae.travelcat.artifact-acceptance.r8r2`. Uses actual `AgentArtifactsView`, production model confirmation/history/download, temporary encrypted store/in-memory key, deterministic 640×360 PNG, two-page PDF, and same-length A/B text. It is explicitly labeled an offline fixture with external test writes.

All three harnesses reserve 40 points for the fixture toolbar plus a one-point divider. Size-button values 760×600 and 1000×740 describe the production viewport; total window content is respectively 760×641 and 1000×781, before the native titlebar. Initial/minimum sizes follow the same rule. Product minimum height is unchanged.

The existing R8 apps remain at the analogous `...-r8/TravelCat...AcceptanceR8.app` paths with IDs ending `.r8`; they were not overwritten. The UI evidence below was obtained from those exact old binaries. Their packaged sidecar predates the ACP UUID normalization, their Conversation mailbox harness bypassed normalization, and their Native detach metadata lacked actual exit proof. They do not establish fixed ACP or R2 lifecycle acceptance. Exact old and new binary/resource hashes are in the temporary freeze manifest.

Artifact operations: select PNG/PDF and inspect PDF pages 1/2, confirm the current version, and use the production SavePanel to save downloads under the app's sibling `artifact-session/downloads`. Expected exact bytes are retained in `artifact-session/expected`; initial hashes/sizes are in `expected-manifest.json`. Keep A selected, click external A→B, then production Refresh to inspect the preserved old preview, old-version download, and Read New Version. Use both 1000×740 and 760×600 controls. Headless `downloadArtifactPreview` passing does not substitute for an actual SavePanel interaction and external byte/hash read-back.

Native operations: click “打开官方登录设置”, continue the production three-step form, check connection and use “使用 ChatGPT 官方登录”. The workspace is prefilled; account completion is a user action in the official browser. A prior main-agent probe (`travelcat-native-account-probe-result.json`) established connected=true, seven models, authenticated=false with official 0.158.0. That prior probe is not current UI authentication or active interruption evidence. Never copy auth files/tokens, touch Keychain or protected authorization, or assume the default CLI login is shared.

After an authorized official login, the main agent can submit one bounded text-only task in the empty workspace and use production “停止本轮” only when an actual active task has thread/turn IDs. Completion racing first is inconclusive. Required evidence is the exact task/instance/thread/turn, requested operation, official terminal `interrupted`, and fresh matching background count 0; a button disappearing or RPC acknowledgement alone is insufficient.

The Native fixture retains `native-session/fixture.json`, first-launch `daemon-ownership.json`, and `acceptance-metadata.json` containing identifiers/status/model count/authenticated/audit kinds only. It does not export prompts, response bodies, authentication URL parameters, tokens or line-level logs. After terminal state, click “记录验收元数据” to refresh background state, then close within its 10-second freshness window. Closing freezes current terminal/background evidence, calls production shutdown, and keeps the app run loop alive for at most 10 seconds to observe actual sidecar termination. It publishes `clientDetached=true` and `sidecarExitConfirmed=true` only after that observation. Timeout/cancellation, unexpected run-loop return or evidence publication failure leaves detached evidence false; cleanup refuses it. The Native daemon remains independent and daemon exit is a separate action.

For a daemon started for the first time by this fixture, run `python3 Scripts/cleanup-native-acceptance.py <native-session>` promptly after closing (metadata must be <=120 seconds old). Default mode checks only. `--stop` additionally signals only the exact receipt's PID after receipt hash, profile/workspace/executable/config hash, full process identity/start string, socket path/inode/ownership, detached state plus `sidecarExitConfirmed=true`, official terminal turns, and background-zero checks pass. Reused daemons, changed identities, unknown/nonzero backgrounds and active turns refuse cleanup. There is no broad process kill, socket/receipt deletion, or official account/Keychain removal. Evidence and the official profile remain after verified process exit.

## Review regression evidence

The initial Native fixture wrote detached metadata before shutdown and did not wait for actual child exit. Merely swapping those statements would still mistake EOF for process termination. Production `disconnected()` deliberately changes generation and may suppress a later old-generation public exit callback. The minimal observer retains only exact launched child processes and removes each in its actual termination handler before the existing generation guard. A malformed-protocol subprocess test first invalidates the transport while keeping that exact child alive: exit observation must time out, and succeeds only after the child is released and terminates. Deliberately moving lifetime removal behind the generation guard reproduced a failure. Separate real empty-sidecar tests cover fake public callback, EOF alone and a nil public callback. No Native daemon or account is involved in these tests.

The old Conversation fixture directly set unread on an archived task, bypassing production normalization. The new meaningful flow regression first reproduced the missing active row, then passed with production mutation: unread injection → mailbox open/reveal → mark-read keeps the target visible in active scope. A second regression opens a quiet archived upstream entry and confirms it remains visible in archived scope. Production navigation/layout behavior was not changed. Red/green evidence: `/private/tmp/travelcat-r8-conversation-fixture-red.log`, `/private/tmp/travelcat-r8-exit-generation-red.log`, and `/private/tmp/travelcat-r8-r2-regression.log`.

## Separate native UI evidence from the original R8 fixtures

Delegated UI operator report: `/private/tmp/travelcat-r8-ui-evidence.md`. The operator verified the old R8 executable hashes against the original freeze and used actual production views, controls and `NSSavePanel`. Full Cua screenshots showed the 640×360 PNG, both PDF pages with blue/yellow blocks and correct page/previous/next controls, preserved old A preview after the external same-size change, the A/B comparison and read-new-version flow, and independent A/B SHA confirmations/history. Screenshots exist in Cua tool outputs; no screenshot file path is invented here.

All five real SavePanel downloads were read back byte-for-byte against their offline expected files under `/private/tmp/travelcat-artifact-acceptance-20261024-r8/artifact-session`. This PNG/PDF evidence uses different fixture bytes from the real Docker test:

| UI SavePanel download | Bytes | SHA-256 |
| --- | ---: | --- |
| `preview.png` | 14811 | `e52733c2dce56e34bd8e149dd89f867517cdd8931783e8e986c0d0c4d39a2f7b` |
| `two-pages.pdf` | 9649 | `08a2264c01d1581da99e04cc7b15234b7a459f413720a193542384b31a184973` |
| `report.txt` | 10 | `c84057ca677dbbdd91c603b3bc33ebc1a497245088cfb76269c85c7c01f80aa2` |
| `report-old-A.txt` | 10 | `c84057ca677dbbdd91c603b3bc33ebc1a497245088cfb76269c85c7c01f80aa2` |
| `report-new-B.txt` | 10 | `f75e543df40f1f05f931fe4c975d40f86bc5d3607752c8945d5284edf3f9a19e` |

Original Conversation R8 actual AX operations passed Chinese/literal/no-result search, rename with original messages retained, pin ordering, archive/restore with draft preserved, disabled legacy ACP archive gate/reason, metadata-save failure rollback, late reply while save fails, and pending-request reappearance. Its mailbox and minimum-height observations exposed the fixture bugs corrected above. The independent UI operator checked the corrected R2 source/binary identity. An initial R2 attempt was blocked by an explicit `Mac is locked` response. After the user brought the app forward again, root reported the corrected R2 mailbox AX flow passed. The 760×600 and 1000×740 screenshot attempts still returned Stage Manager thumbnails, so actual viewport layout acceptance remains blocked by the tool; no repeated unlock request is required. Thumbnails do not count as layout acceptance.

Root's separate original Native R8 UI opened official login settings, checked connection with authenticated=false, and clicked official login, which showed waiting-for-browser/cancel. The subsequent browser observation did not establish the official page or user login. Long `getApp` calls are tool delays, not evidence of a locked Mac or passing authentication. No task/model call was sent in that Native UI attempt, and no real active-turn interruption was accepted. The old Native app may remain running; it was not stopped or migrated to the new proof contract.

## Remaining acceptance and protected data

At implementing-agent freeze, the separate original R8 artifact native-view/SavePanel evidence above is established by the delegated UI operator. Corrected Conversation R2 mailbox AX acceptance passed in the later root-reported attempt; its actual minimum/large viewport layout remains tool-blocked. Real official Native login/active interruption remains unverified and owned by the main agent. R2 Native detach has subprocess-level regression evidence, but no new Native R2 UI run is claimed. Formal installed-app behavior is outside this item's scope. No SSH, Git index/ref/commit writes, pushes, PR creation, formal installation, user data reset, or credential migration was performed by this implementation agent.

Original `Assets`, `Fixtures`, `Tests/Fixtures`, and `Sources/TravelUI/Resources` have no tracked changes. `TravelPetData` and `.local` were not opened, staged, moved, reset or deleted. Production `Resources/AgentRuntime/sidecar.py` is the explicitly authorized functional source exception.


## Follow-up: safe CI identities and subprocess startup handshake

The runtime CI step now uses `Scripts/run-agent-runtime-contracts.py` with the same complete discovery pattern, original assertions, normal unittest results and failure exit status. Only when `GITHUB_ACTIONS=true`, failures produce at most ten deduplicated annotations with fixed text and a strict ASCII ID captured before execution. Exact test objects remain retained; runtime ID changes, exception text, subtest parameters and unknown objects cannot supply annotation IDs. Class/module setup and teardown holders match precomputed static fixture identities; an unmatched standard holder receives only `unittest.suite.unknown_fixture_failure`. The local whitelist contains 200 discovered test IDs, 58 fixture markers and that one constant. No CI raw logs, annotation bodies/messages, stack or crash contents were read. Differing CI outcomes alone do not establish their cause.

Final diagnostic checks passed: 12 runner safety contracts, one workflow contract, and all 200 runtime tests in 11.993 seconds. A successful run with `GITHUB_ACTIONS=true` produced zero annotation bytes. Diagnostic source freeze and safe title whitelist are `/private/tmp/travelcat-r8-safe-runner-freeze.json` and `/private/tmp/travelcat-r8-runtime-static-test-ids.json`.

A separate local aggregate Swift run caught a startup assumption in the new subprocess test: its first callback check ran before the malformed-protocol callback, although later actual exit and callback suppression succeeded. A controlled 1.5-second startup delay reproduced that same old-polling failure; the same delayed child passed after adding a ready marker, a parent invalidation gate and a bounded expectation for the actual callback. The temporary delay was removed. The final four exit tests passed in 1.496 seconds. The original 50-millisecond still-alive rejection, five-second exact old-child termination and final single-callback assertions remain. Every failure path releases only the owned fixture, and its directory is deleted only after actual exit confirmation. No production client behavior or exit budget changed. Evidence is `/private/tmp/travelcat-r8-sidecar-startup-freeze.json` and its three linked red/green/final logs.

Earlier complete Scripts runs were initially treated as Python-only, but the existing `packaged_postage_tests.py` invokes a Swift build in its own temporary miniature package. Some of those runs overlapped other Swift work; no causal link to the late callback has been established. Further final aggregate validation belongs to root and must run serially: full Swift, prompt subset, complete Scripts including its Swift probe, then the remaining contracts. This addendum does not claim that final sequence, a current CI root cause, viewport layout acceptance or official Native login/interruption has passed.
