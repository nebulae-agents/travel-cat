# Automatic travel failure diagnostics verification — 2026-10-28

## Compatibility revalidation — 2026-10-30

Updated onto main `4c9257c88a5ae3e0dfeb809f1bfbdf7fdc235144` through its predecessor PR without rewriting history. PR #42 supplies exact timestamp coding; the obsolete worker comparison workaround is absent. The focused controller/lifecycle/envelope/date and available package/render selection passed 71 tests with zero failures on this adapted tree. The original records below retain their historical scope; no installed app, real provider or formal travel data was used in this adaptation.

## Scope and behavior

`AutomaticTravelFailure` retains its category values and adds optional fixed-enum `code` and `stage` fields. Old failure JSON without those fields continues to decode. Repository diagnostics distinguish lock contention, recovery needs, state conflicts, invalid output, unsafe paths and lock I/O failures. Atomic writer failures are storage/I/O failures. Structural and continuity envelope errors now report invalid output with distinct fixed codes.

The worker records the actual outer-catch operation: loading/planning, narrative generation, validation, publication or image handling. Chinese messages combine this phase with a fixed next action. Neither messages nor serialized failure payloads copy associated strings, UUIDs, error descriptions, provider bodies, credentials or private paths.

Retry delays, model cooldowns, controller cancellation and image retry behavior are unchanged. Errors consumed inside image handling continue through the existing image result workflow. State loading before the outer catch and errors while saving the failure state still throw; this change does not claim diagnostics for those paths. Publication-stage errors can happen after a journal write; the message does not claim the event was rolled back. Unrecognized errors retain the conservative generic category.

## Evidence

- Baseline: `Scripts/travel-cat-swift.sh test --filter 'AutomaticTravelLifecycleTests|AgentEnvelopeTests'` passed **60 tests** (32 lifecycle, 28 envelope).
- RED: the three added tests ran before production changes. Two tests failed with **20 assertions** for missing code/stage and incorrect envelope classification; the old-record compatibility test already passed.
- Additional RED: atomic-writer error injection failed **2 assertions**, demonstrating its missing storage/I/O classification before that mapping was added.
- Final GREEN: the same lifecycle/envelope command passed **63 tests** (35 lifecycle, 28 envelope), zero failures. Build output contained no warning/error lines.
- The allowlist regression covers every current RepositoryError case, both AgentEnvelopeError cases and AtomicFileWriterError, with malicious associated strings and UUID checks against serialized JSON and user messages.
- Real worker generation and structural-validation failures persist distinct stages, expose fixed phase text and preserve the prior snapshot, decoded journal events and exact journal bytes.
- `git diff --check` passed.

Independent specification and quality reviews found no blocking issues. GitHub preflight and public upload audit passed. Full-suite remote checks and installed-app/provider acceptance are separate evidence; no production data or installed app was changed. Generation used local test doubles and temporary repositories. Loading, publication and image stage fault injection remain additional coverage opportunities.
