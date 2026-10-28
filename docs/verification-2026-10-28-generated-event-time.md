# Generated event timestamp verification — 2026-10-28

## Defect and scope

The automatic worker creates event timestamps from its own clock, then encodes and strictly decodes the candidate before validation. The fixed sample `Date(timeIntervalSinceReferenceDate: 814003706.03560197)` decodes slightly later after RFC 3339 serialization. Comparing that decoded event against the original timestamp incorrectly produces `occurredAtAfterNow`.

Both normal publication and historical supplemental publication now use the decoded representation of that same host-generated timestamp as the internal validation time. Structural validation, continuity checks, the external envelope validator, and repository publication checks are unchanged. This does not introduce a future-time tolerance for external input.

## Verification

- Final regression tests were run against the original comparison expressions: **2 tests failed**, with 10 failed assertions. Normal postcard publication and supplemental publication both reported generation failure.
- With the fix: `Scripts/travel-cat-swift.sh test --filter 'AutomaticTravelLifecycleTests|AgentEnvelopeTests'` passed **60 tests** (32 lifecycle and 28 envelope tests), with zero failures.
- Each worker regression fixes the host timestamp at the reproducing value and models persistence one second later. Both verify a pending postcard is published and the next eligible wake after worker restart completes its image. The supplemental regression also verifies the original journal bytes and journey snapshot remain unchanged.
- An external envelope exactly one floating-point step ahead of the supplied current time is still rejected with only `occurredAtAfterNow` and no publish envelope.
- `git diff --check` passed.
- The full `Scripts/travel-cat-swift.sh test` run was interrupted (exit 130) after the UI handwriting-verifier section stopped producing output for several minutes. No full-suite pass is claimed; the relevant 60-test run above completed independently.

All generation used local test doubles and temporary repositories. No production travel data, model service, installed application, remote branch, or published release was changed by this implementation work.
