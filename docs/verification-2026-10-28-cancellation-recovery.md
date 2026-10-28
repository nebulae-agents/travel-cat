# Automatic travel cancellation recovery — 2026-10-28

## Change

An independently thrown `CancellationError` previously returned before releasing the controller task, leaving automatic travel stuck as running. Current executions now clear running state and schedule a retry in 60 seconds. Disabled controllers remain paused. A UUID for each invocation isolates old completions and queued timer callbacks after pause, resume or settings changes.

Unexpected thrown errors now create a sanitized `AutomaticTravelFailure`. When a retry closure is available, manual recovery retries ordinary execution for controller-caught errors, since the worker may not yet have persisted failure state. Outcomes already containing a worker failure retain the dedicated retry path. Repeated refresh/retry requests coalesce during an active execution.

Initializer, persisted data and worker scheduling policy are unchanged. No live progress was added.

## Verification

Executed with `Scripts/travel-cat-swift.sh test` (one Swift process at a time):

- RED: `--filter AutomaticTravelControllerTests`: five tests, five failed assertions exposing cancellation cleanup and missing failure information.
- Integration RED: `--filter AutomaticTravelControllerTests.testUnexpectedErrorOffersSanitizedCoalescedManualRetry`: three failed assertions exposed incorrectly using the persisted-failure retry path for a controller-caught exception.
- GREEN: `--filter 'AutomaticTravelTests|AutomaticTravelLifecycleTests|AutomaticTravelControllerTests'`: **47 tests, zero failures**. Includes six new controller tests plus existing pause/resume, settings-change and dedicated failure-retry coverage.

New coverage checks independent cancellation, bounded retry date and no immediate loop, disabled completion, pause cancellation, stale cancellation while replacement is running, sanitized unexpected-error recovery with coalesced clicks, and an actual timer wake followed by pause invalidation. Tests terminate using bounded yields/deadlines; the 60-second cancellation retry is verified through its deadline rather than waiting a full minute.

## Limits

This is controller-level and existing worker regression evidence, not installed-app UI acceptance. No real data, provider calls, app installation, publishing or deployment was performed. Task cancellation remains cooperative: paused operations that ignore cancellation may finish later, but cannot finalize or schedule work for a newer controller execution.
