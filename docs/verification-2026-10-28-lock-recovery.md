# Repository lock contention recovery verification — 2026-10-28

## Change

`AutomaticTravelWorker` treats only `RepositoryError.lockUnavailable` as transient contention. It persists a separate `repositoryLockRetryAt` deadline: 15 seconds in fast mode or 60 seconds in daily mode. Early wakes (including restarted workers) return that deadline without invoking a model. The deadline does not grow after repeated contention.

Contention does not increment generation failure count, overwrite the existing generation retry deadline, or replace its persisted diagnostic. If a model action had started, its completion-based cooldown is still saved. A fresh lock collision returns a wait without a retryable failure; if a genuine failure was already pending, that same diagnostic remains in the outcome and saved state. Existing state files decode without the new optional field.

The nonblocking repository flock, single-worker lock, journal publication, image retry limits, and normal generation failure path are unchanged. There is no sleeping or polling loop.

## Verification

All Swift invocations used `Scripts/travel-cat-swift.sh` serially.

- RED: `test --filter 'AutomaticTravelLifecycleTests.testRepositoryLock'` ran 3 tests with 28 expected assertion failures before the production change. Repeated contention increased failure counts/backoff and replaced prior retry state.
- GREEN: the same 3 regression tests passed.
- Diagnostic review RED: asserting no retryable failure for fresh contention and preserving an existing generation failure produced 9 expected assertion failures; the final 66-test run passed after aligning lock outcomes with wait semantics.
- Lifecycle regression: 38 `AutomaticTravelLifecycleTests` passed, including existing ready-intent recovery, manual retry cooldown, and generation/validation failure cases.
- Envelope regression: `test --filter AgentEnvelopeTests` passed 28 tests, including future timestamp rejection and structural validation.
- `git diff --check` passed.

The initial lifecycle run used the filter `AutomaticTravelLifecycleTests|AgentEventEnvelopeTests`; the second class name matched no tests. The separately executed `AgentEnvelopeTests` run above supplies the actual 28-test envelope evidence. Final combined verification used `test --filter 'AutomaticTravelLifecycleTests|AgentEnvelopeTests'`: 66 distinct lifecycle and envelope cases.

## Regression scenarios

1. Hold the real `.repository.lock` using a separate open file descriptor, wake/recreate the worker four times in both modes, verify fixed 15/60-second waits, zero narrative/image calls, zero generation failures, and absent generation retry deadline. Release the lock and verify one event is published.
2. Produce four genuine narrative failures with 15/30/60/120-second exponential backoff. Encounter a real repository lock while that backoff is pending. Verify failure count, diagnostic, and original deadline survive; release the lock, verify no early narrative call, then verify recovery at the original deadline.
3. Acquire the repository lock after narrative generation while advancing the clock by 100 seconds. Verify the retry is 15 seconds after completion, no publication occurs while locked, and a restarted early wake invokes no model. Release the lock and retry at the deadline; verify exactly one new event, unique IDs, and unchanged prior events.

## Image recovery and limits

`completeImage` still retains the generated target file after handing a ready result to `markImage`; it does not turn a publication error into a failed image result. `markReadyImage` persists terminal ready intent before journal writing, and repository reconciliation recovers that intent. The existing `testReadyIntentSurvivesJournalWriteFailureAndWorkerRestart` passed.

A lock collision before ready intent is persisted is not equivalent to a durable completed image. Likewise, a narrative that could not be published is not cached by this change: the post-generation contention test explicitly expects another narrative call after cooldown. This change does not promise to eliminate repeated model work for unpersisted results.

Verification used isolated temporary repositories and a controlled clock on macOS. No installed-app acceptance, production travel-data mutation, remote publication, or full-package test run is claimed here.
