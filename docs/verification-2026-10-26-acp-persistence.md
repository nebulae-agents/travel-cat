# ACP submission persistence (2026-10-26)

## Priority and design

The current audit has three confirmed issues, each intended for a separate PR:

1. **P1 — ACP submission can continue after encrypted snapshot saving fails.** Require durable task and accepted-session checkpoints before starting or prompting the runtime. Retain the current draft on failure.
2. **P1 — Exporting into the repository can recursively copy its staging directory.** Reject destinations inside the physical repository before creating staging; retain valid external exports.
3. **P2 — A late Native connection can start a task for a removed Agent.** Revalidate cancellation, storage and the current instance after connecting, before inserting or starting a task.

This PR implements only item 1. Existing build-identification, documentation and CI proposals are not duplicated. New fixes do not replace the installed application or perform real model, SSH or Docker operations.

## Reproduction and change

Three regression cases failed against the original code with nine assertions: a new task reached the runtime and cleared its draft after saving failed; a follow-up was sent, appended and cleared under the same condition; the first prompt reached the runtime before the accepted session ID was on disk. The failure fixture uses an invalid in-memory draft while retaining a valid encrypted file, without altering real records or credentials.

The ACP start path now saves a candidate snapshot before publishing its task or issuing start. Before the first prompt it saves the accepted session and current content. Follow-ups save a candidate message before changing visible state or issuing prompt. A failed checkpoint reports the problem and leaves the draft for correction or retry. Existing ambiguous-response handling and explicit user control remain in force; the app does not automatically resend.

## Validation and limits

The initial focused green run passed 37 tests with zero failures. A further regression covers failure after start accepted a session: prompt is not issued and the submitted draft is retained. The final application run passed 641 XCTest cases (7 opt-in cases skipped) and 36 Swift Testing cases with zero failures. Independent read-only review found no blocking P1/P2 issue; its requested second-checkpoint failure case is included. Upload preflight and project audit passed.

These are deterministic model/runtime-fixture checks. They do not establish installed-client or remote-host acceptance. No new build has been installed and no real task has been submitted.
