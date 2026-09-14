---
name: travel-cat-journal
description: Use when the user asks for 当前旅程, 最新明信片, 旅行册, 暂停旅行, or 继续旅行 in a Travel Cat travel-journal task.
---

# Travel Cat Journal

Resolve `../../scripts/run-travelcatctl` relative to this installed `SKILL.md` directory, never relative to the current task working directory.

Preserve exactly these five intents:

| Intent | Authoritative action | Result |
|---|---|---|
| `当前旅程` | Invoke `../../scripts/run-travelcatctl journal` once. | Show phase, concise Chinese location, summary, mood, and next open hook. |
| `最新明信片` | Invoke the same journal query once. | Render the latest ready postcard and show location and mood quote. |
| `旅行册` | Invoke the same journal query once. | Show the newest 100 chronological records and `postcardCount`; render one selected available image. |
| `暂停旅行` | Locate and pause exactly one existing Travel Cat automation attached to the relevant task. | Confirm future checks are paused without changing travel data. |
| `继续旅行` | Locate and resume exactly one existing Travel Cat automation attached to the relevant task. | Confirm checks resume without catch-up events. |

## Read safety

The three read intents issue exactly one journal query and never call claim, publish, pending-images, validate-candidate, or mark-image. Resolve returned relative postcard paths only beneath that response's `runtime.dataRoot`; reject missing metadata, absolute paths, `..`, symlinked parents or leaves, nonregular files, and anything other than validated PNG or WebP. Never guess an author directory or use a second configuration response.

Never advance travel state or print IDs, versions, hashes, tokens, command output, or filesystem paths. Do not invent missing facts or future transitions.

## Automation identity

For pause/resume, match the existing heartbeat attached to the relevant current task using stable task context and the Travel Cat prompt contract, not a pet display title. Update status while preserving every other field. If none or multiple automations match, explain the ambiguity and ask the user; never create a replacement or change another task.
