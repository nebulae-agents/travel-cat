# Automatic travel progress and recorded publication time — 2026-10-28

## Compatibility revalidation — 2026-10-30

Updated onto main `4c9257c88a5ae3e0dfeb809f1bfbdf7fdc235144` through its predecessor PR without rewriting history. PR #42 supplies exact timestamp coding; the obsolete worker comparison workaround is absent. The focused controller/lifecycle/envelope/date and available package/render selection passed 91 tests with zero failures on this adapted tree. The original records below retain their historical scope; no installed app, real provider or formal travel data was used in this adaptation.

Automatic travel settings now show the active narrative, image, validation or publication stage and retain concrete waiting reasons between operations. Progress callbacks belong to one worker invocation. The controller accepts only its currently active execution's callback, so paused, replaced and completed operations cannot overwrite a newer status.

The scheduling cache has an optional `lastSuccessDate`. It records host time after acknowledged ordinary or supplemental narrative publication or ready-image persistence, before later reconciliation. Waiting, generation failure, invalid content and failed-image results do not advance it. Existing cache files without the field remain readable. Application initialization restores it without starting generation; shared-worker manual-image completion refreshes it even while automatic travel is paused, without forwarding unrelated stages. Unknown metadata is labeled “暂无已记录的成功发布时间”.

## Verification

- Baseline: 47 controller/worker tests passed.
- Publication-time RED: a real published narrative lacked the expected persisted timestamp (one expected failure). The same test passed after the worker change.
- Progress negative control: temporarily disconnecting the callback's assignment produced two expected stage assertion failures; the assignment was restored before final tests and packaging.
- Final relevant suite: **58 tests passed**, comprising 7 controller, 43 lifecycle, 3 basic automatic-travel, 1 native rendering and 4 packaged-acceptance unit tests. Coverage includes stale progress, ordinary and supplemental publication/image times, paused manual image success, failure and waiting preservation, restart, old JSON, and successful publication followed by reconciliation failure.
- The submicrosecond host-clock fixtures compare persisted times with a 1 µs tolerance, matching their existing event-date assertions; JSON date round-trip precision is not exact binary identity.
- A further native rendering test passed after adding a dedicated long Chinese failure view. The actual `AutomaticTravelStatusView` was hosted in an isolated 480-point grouped settings form. Running, long waiting and failure states rendered with success/failure timestamps; inspected images showed no clipping. This does not claim installed Settings acceptance or full application interaction.
- Actual release-package acceptance passed after `Scripts/package-app.sh` and `python3 Scripts/run-packaged-travel-acceptance.py 'dist/Travel Cat.app'`: 6 packaged and copied resources, 4 synthetic narrative calls, 1 image call, pending/ready/readback all true. All six missing-resource cases, three malformed arguments and an unbundled binary were rejected; synthetic data was removed. Strict signature verification passed. Generated tracked provenance was restored byte-for-byte (SHA-256 `497f9970f312c30881e7ef358c159386c5aa85793e7d05435a86ba1ddcabddcb`), and only this run's newly generated app bundle was removed.

## Limits

Publication and timestamp-cache persistence are separate writes. If publication succeeds but the timestamp cache cannot be saved, the repository can already contain the new event or image while the displayed timestamp remains older or unknown. A subsequent error is not a rollback. The controller preserves its last known timestamp on exceptions or absent metadata.

Tests and package acceptance use synthetic temporary data and fixed generators. No live provider, installed application, normal startup path, production travel data, deployment or remote delivery was exercised. The build retains existing warnings in unrelated code; warning-free and full-suite verification are not claimed.
