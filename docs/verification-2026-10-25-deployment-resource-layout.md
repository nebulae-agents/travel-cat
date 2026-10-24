# Deployment resource layout correction - 2026-10-25

## Observed boundary

PRs #12-#21 were merged in dependency order; merged main `865fd1052451e11def8e6d4e051847a0a222271a` has exactly the reviewed PR21 file tree. A real local deployment completed its release builds but stopped before publication because `Runtime.verify_app` looked for `TravelCat_TravelUI.bundle/pet.json`. The native SwiftPM bundle places that file under `Contents/Resources`. The packager already supports both bundle layouts; the deployment verifier only supported the flat layout.

The installed app digest, all 76 pre-existing data-file hashes and the previous complete deployment receipt remained unchanged after the failed attempt. No installation result is claimed for that attempt.

## Correction and regression

The verifier selects the native bundle's `Contents/Resources` when present and otherwise retains flat-layout compatibility. Existing whole-tree link checks, signatures, exact source asset bytes, helper provenance, publication and rollback remain in force. Assets and user data are unchanged.

The original 56 deployment tests passed. Two new test methods first failed at three subcase assertions: native deployment was rejected, corrupt native assets produced the wrong failure, and valid flat shadows hid corrupt native assets. The first test runs the deployment transaction through the existing fake OS/build boundary using real nested files and checks complete stages and installed bytes. The second checks rejection of corrupt active native bytes with and without flat shadows. The implementation adds only the three resource-directory selection lines.

Root owns final regression runs, independent review, PR delivery and real installation reattempt. The earlier failed attempt and red test logs are retained separately; successful tests do not substitute for an actual installed-app result.
