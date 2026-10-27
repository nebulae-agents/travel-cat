# Native executable discovery follow-up (2026-10-25)

This change depends on the independent-window harness in PR #24. Fresh official login and active-turn interruption remain acceptance requirements; the formal installed app has not been replaced by this candidate.

## Reproduced problem

The user confirmed the complete R14b window was visible, then reported that Next could not be clicked and the executable could not be entered manually. Its own fixture record contained an empty executable while the independent workspace existed. The basic-step Next gate rejects a configuration with no executable. This establishes the missing executable as a blocker; the exact reason for the user's inability to type was not observed because native capture still returned ScreenCaptureKit -3811.

The GUI discovery used common bin directories, the launch process PATH and the standalone Codex application layout. On this machine the actual shell command resolves to the official ChatGPT application layout, `/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex`, which is absent from a Finder-style PATH. That exact file is executable; its version command reported `codex-cli 0.163.0-alpha.10.2`. Previous P0 acceptance used 0.158.0 and is not evidence for this version's connection, authentication or control behavior.

## Change and safety boundary

A small Foundation discovery helper preserves common-bin and PATH precedence, then checks supported Codex and ChatGPT layouts under system and user Applications directories. It chooses only a path passing the existing executable-file check, invokes no shell/program and reads no account state. Configuration validation, official capability checks, login and task authorization are unchanged. The basic setup step now explains how to select a program in Advanced & Diagnostics when discovery returns empty.

The independent preview uses the same production new-instance factory, so the next fresh fixture can receive the discovered path without user text entry. It still creates no automatic connection, official login or task and never copies an existing profile.

## Validation

Before adding the ChatGPT layout, the extracted existing behavior ran four actual-filesystem tests: three passed; the Finder-style ChatGPT case failed its detected-path assertion and the production `validate(requireModel:false)` check. The earlier missing-helper compilation attempt is not counted as a behavioral reproduction.

With the supported layout added, 87 focused Swift tests passed, including all four discovery tests plus Native model/data, runtime discovery, production window bounds and actual sidecar-exit tests. The discovery fixture creates executable files with real permissions but never runs them, and scopes checks to its temporary root to exclude installed host programs. Independent review found no confirmed P1/P2. A review-identified weakness in relative-PATH coverage was corrected by separately recording probed candidates and asserting relative entries are never probed; the final serial focused run passed all 88 tests, including the five discovery cases.

R15 compiled successfully with the production helper and PR #24 window lifecycle. Its fresh fixture record contains the exact executable above; a filesystem read-back confirms that file is executable and its workspace exists. Its own window probe reports launchCompleted=true, visible=true, content 1000×781 and the complete frame inside the screen. A fresh metadata read remained unauthenticated with zero models and zero tasks. The UI tool waited about 1902 seconds before again returning ScreenCaptureKit -3811; this is tool latency, not measured application latency. No further native capture attempt is required while the same failure persists.

The old R14b process was stopped only after confirming no task, authentication, models or daemon-ownership receipt; its files and unconfirmed exit metadata were preserved. R15 remains open for the user to perform the official login. Current acceptance still requires the actual usable Next action, real official connection/login, active-turn interruption with fresh background-zero evidence, and normal sidecar exit. A compiled preview or an executable path alone does not establish those outcomes.

Temporary local evidence: `/private/tmp/travelcat-codex-discovery-behavior-red.log`, `/private/tmp/travelcat-codex-discovery-final-green.log`, `/private/tmp/travelcat-native-window-r15-build.log`, and R15 `native-session/fixture.json` plus `acceptance-metadata.json`. These records are not uploaded. At this freeze PR #24 head `0f4ea56e64c7d6f4db53d600142894a8d07d2d72` had both source-checks jobs completed with success; that is separate from this discovery revision and remaining client acceptance.
