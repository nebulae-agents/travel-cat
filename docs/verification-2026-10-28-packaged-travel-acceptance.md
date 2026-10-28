# Packaged offline travel acceptance — 2026-10-28

## Change

The release `TravelCatApp` now has a fixed `--offline-packaged-acceptance` entry handled before SwiftUI constructs the normal application delegate. Acceptance-prefixed malformed or mixed arguments fail with a fixed JSON error. Unrelated ordinary launch arguments retain their previous path. Non-app executables are rejected before synthetic work.

The entry accepts no data-root, provider, executable or credential settings. It creates a new private temporary repository and uses an internal fixed execution closure in `CodexTravelContentGenerator`. Production construction still delegates to `CodexTravelExecutor`; resource copying and result decoding are shared. The acceptance checks all six generation assets inside the running app, including JSON structure and PNG decoding.

The real `AutomaticTravelWorker` advances synthetic time through normal narrative publication and a durable `pendingImage` postcard, then creates and validates a 1152 × 768 PNG. The same event becomes `ready`; every field is compared after normalizing only image status/path. A fresh repository and the production `PostcardImageLoader` / `PostcardImageDecoder` read the saved image back.

## Local verification

- Behavioral RED: 4 new Swift tests produced 15 expected assertion failures against the minimal API skeleton, before implementation. The earlier missing-symbol build was not used as behavioral evidence.
- Focused GREEN: 45 tests passed across `PackagedTravelAcceptanceTests`, `TravelGenerationResourceTests` and `AutomaticTravelLifecycleTests`.
- After strengthening complete event invariance, 21 tests passed across `PackagedTravelAcceptanceTests`, `TravelGenerationResourceTests` and `CodexTravelExecutorTests`.
- Python harness RED: 4 tests produced 10 expected failures for bounded execution, JSON parsing and incomplete results. The extra-field/privacy regression then produced one expected failure. Final GREEN: all 4 Python tests passed.
- `Scripts/package-app.sh` built and ad-hoc signed the actual release app in approximately 102 seconds. Its generated change to tracked CLI provenance was restored to the original bytes after packaging. The build retained two pre-existing warnings in unchanged code (`CodexPetCloseForwarder` unsafe bit cast and `TravelCatApp` weak capture); it was not warning-free.
- `python3 Scripts/run-packaged-travel-acceptance.py 'dist/Travel Cat.app'` passed using a relocated copy and unrelated working directory. Report: 6 packaged resources, 6 copied resources, 4 synthetic narrative calls, 1 image call, pending/ready/readback all true.
- All six assets were removed individually from a disposable app copy and the copy re-signed before execution: `narrative.schema.json`, `image.schema.json`, `front.png`, `side.png`, `sitting.png`, `identity.json`. Each produced nonzero exit and the fixed `missingResource` report while source/build-cache assets remained available.
- Three malformed argument combinations and a copied executable outside an app were rejected. The harness confirmed synthetic temporary work directories were removed. The original packaged app still passed strict signature verification; only this task's generated `dist/Travel Cat.app` was removed after verification, leaving other dist entries untouched.

The harness caps each probe at 45 seconds and each disposable-copy signing operation at 30 seconds. It never echoes raw subprocess output and accepts only the exact success-report fields. All test images and stories are synthetic; no real travel data or model credentials are loaded.

## CI and limits

A separate `packaged-acceptance` macOS job packages and runs this harness with a 20-minute job limit. The existing source-check job retains its 30-minute limit. CI uploads only the fixed structured acceptance report, not raw build/provider logs. The new remote CI job has not been observed in this local verification.

This verifies release packaging, owned generation resources, normal publication/image persistence and production readback. It does not verify a live provider, network image generation, Finder launch, visible native UI, installation or deployment. No application was installed and the normal application startup path was not launched for this acceptance.
