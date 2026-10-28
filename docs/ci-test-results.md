# Sanitized Swift test results

CI invokes `Scripts/swift_test_report.py` for the full UTC suite and the Asia/Shanghai prompt suite. Each invocation still runs `Scripts/travel-cat-swift.sh test`, preserves its exit status and leaves build products outside the checkout.

The `swift-test-results-<run>-<attempt>` artifact retains JSON reports for seven days, including failed runs when the runner can finish the upload step. Reports contain only:

- The actual checkout revision, dirty flag, Swift version, platform, architecture, timezone and selection.
- Public test suite/method identifiers found in `Tests/**/*.swift`, fixed outcomes and numeric duration (at most 5,000 records).
- XCTest counts and an aggregate Swift Testing count/outcome across targets.
- The process exit code, duration, truncation flag and fixed report status.

Compiler output, assertion text, test attachments, model replies, credentials, paths and arbitrary environment variables are neither echoed nor saved by this adapter. Oversized lines and identities absent from public test source are dropped. Swift Testing display names and parameter values are omitted; only its run aggregates are indexed. This is a bounded result index, not a complete log.

`testsRecorded` means some structured results were collected, not that tests passed: inspect `exitCode`, failed counts and truncation. `resultsUnavailable` means no recognized results were emitted (for example an early build failure or a format change); it must not be described as passing coverage. Timeout returns 124 and terminates the owned process group, including descendants after the group leader exits. Interrupted runs remain nonzero. Report write failure preserves an existing test failure, or returns 73 when tests otherwise passed; the adapter removes a previous report before starting. A hard runner loss can prevent report publication entirely.

The revision is the tested checkout, which may be GitHub's synthetic PR merge commit. Check the PR head and its matching checks separately. Do not infer installed behavior from these reports.

For local diagnosis use the wrapper with the public test identifier or rerun a complete suite. The initial PR #28 failure was not diagnosed; later unchanged success did not establish its cause, and this change does not claim to fix that earlier failure.
