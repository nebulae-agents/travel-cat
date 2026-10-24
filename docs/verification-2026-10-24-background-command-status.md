# Background command visibility verification — 2026-10-24

A completed Codex turn can leave background commands running. This change shows a current count beside the conversation controls and provides the existing audited stop action directly in the main view. A missing or failed observation is shown as awaiting verification, never as zero or a completed process.

## Scope and safeguards

- The status RPC accepts only the bound task ID. Official thread, connection generation and execution binding are checked before, between and after bounded pages.
- Observations are ephemeral and expire after 10 seconds. They are invalidated by new turns, resume, disconnect and control actions, and never become saved proof of current process state.
- Polling is owned by the selected, visible conversation. Hidden or superseded callers cancel; an in-flight physical request keeps its slot until it returns. Completion refreshes wait for that slot and recheck visibility and binding before starting.
- Runtime status reads share a five-second deadline across scope locks, writer lock, frame write, response and all pages. Busy read/control locks reject the read rather than queue it. Late read responses cannot overwrite another request, and ordinary control request semantics remain unchanged.
- Routine reads do not rewrite the audit or a completed turn. Stop retains the original audited control path.

## Verification

The completion-refresh race and timeout/lock issues were first reproduced with failing regressions, then fixed. Final complete Python runtime regression: 164 tests passed. Final Swift NativeAgentModel regression: 34 tests passed. The controller/transport deadline subset contains 69 passing tests. Specification and quality review passed after the fixes; the whitespace check was clean. No complete Swift suite was rerun for this localized change.

## Local acceptance limits

An isolated production-view preview was built. No successful AX or screenshot acceptance was obtained for this feature: the first UI call did not return, and the subsequent inventory reported that the Mac was locked. This is not counted as native UI acceptance. No formal app installation, system Keychain action, SSH acceptance or upstream model request was performed for this change. The user selected local-only acceptance.
