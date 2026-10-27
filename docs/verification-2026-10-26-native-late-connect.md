# Native late-connect submission guard (2026-10-26)

## Problem and design

Audit priority 3: startNative awaited connection using an instance captured earlier, then immediately inserted a task and sent native_start/native_prompt. During that wait a user could clear the submitted draft and delete the Agent; the late result still created a task referencing a missing configuration. Such a task cannot use normal recovery after restart. Configuration changes, shutdown and cancellation had the same unchecked asynchronous boundary.

After connection returns, recheck task cancellation, secure storage readiness (including shutdown), and equality with the currently saved instance. Perform these checks before inserting a task or recording a start intent. If the configuration changed or disappeared, report an actionable error and keep any draft the user has not independently cleared. No automatic resend, configuration recreation or forced blocking of legitimate deletion is added.

## Reproduction and validation

Five deterministic runtime-fixture tests failed against the original code with thirteen assertions. They cover asynchronous deletion after clearing the draft, synchronous deletion, a configuration update while retaining the draft, model shutdown and cancellation of the submitting child task. They assert no late native_start/native_prompt, no orphan task and release of the submitting state. The deletion case also reads the saved snapshot; the configuration case verifies the user's updated configuration and retained draft.

The final focused run passed 97 Native model, draft recovery, secure-storage and submission tests with zero failures. Independent read-only review found no blocking P1/P2 issue. These cases prove the connection-return boundary; cancellation after native_start has already been sent retains its existing behavior and is not covered by this new guard. Fixtures use a fake authenticated response and do not invoke official login, a model, SSH or Docker. Installed-client acceptance is not claimed and the formal app is not replaced by this PR.
