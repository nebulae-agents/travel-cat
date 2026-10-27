# Independent Native acceptance window follow-up (2026-10-25)

Status: the user confirmed the complete R14b window is visible. Automated UI capture, menu/Dock recovery, actual resize, fresh official login and active-turn interruption are still pending. This change does not alter or reinstall the production app delivered from main `8ade0c6a1339f2dc930b59cc0d352c53eaf570d4`.

## Observed boundary

The original R13 diagnostic fixture retained its own window and reported visible=true, not miniaturized, content 1000×781 and a complete frame inside the display. The application was not active and the window was not key. Native capture returned ScreenCaptureKit -3811 for both the fixture and Finder, including after resetting the UI tool. The earlier user report was that no independent window appeared. Neither the process existing nor the AppKit visible flag proves a user-visible foreground window.

The original direct NSWindow setup assigned its minimum before installing the hosting view. Its raw contentMinSize later read 0×0. A diagnostic assertion demanding a stable raw minimum failed. That assertion also fails with the production controller, whose existing contract deliberately repairs hosting resets when an actual resize occurs. The raw-property failure is retained as an observation; it is not accepted as proof of clipping or of the reported invisible window's root cause.

## Candidate change

Only the manual Native acceptance harness changes. It owns the same production TravelUtilityWindowController used by the installed workbench, presents the content after applicationDidFinishLaunching, and gives the existing window a Dock reopen handler and a menu entry. Window, menu and system quit requests preserve the bounded production sidecar shutdown/actual-exit observation path. The delegate and controller remain owned until the application run loop returns.

The harness continues to use a fresh empty workspace and independent encrypted store with an in-memory key. It never automatically connects, logs in or submits a task, and never copies an existing official profile or credentials. Every process restart requires a fresh fixture root because the in-memory store key is not persisted.

The existing metadata receipt now includes a weak own-window probe: launch completion, application/key/visible/minimized state, content/frame/raw minimum sizes and screen containment. No authentication URLs, tokens, prompt bodies or response bodies are added.

## Current validation

- Preview packaging: 2 tests passed; exact production Python resource copying and identity/overwrite rejection remain covered.
- Focused Swift: 14 tests passed, comprising 3 utility-window controller, 7 minimum-size and 4 sidecar-exit tests. These include actual NSWindow frame resizing, hosting minimum reset/recovery and exact-child termination observations. They do not drive the new Native harness UI.
- The corrected R14b standalone harness compiled successfully. A preceding candidate failed compilation on an AppKit termination enum spelling; it was not launched. No production source changed.
- Independent read-only review found no confirmed P1/P2. It explicitly left real visibility, foreground activation and quit with a setup sheet open unverified.
- R14b launch produced launchCompleted=true, visible=true, content 1000×781, frame 1000×813 at (470,36), within the screen. Application/key remained false and raw minimum remained 0×0. Native capture again returned -3811. The user subsequently confirmed the complete window is visible. This is a human observation, not an automated screenshot or proof of a single root cause; menu/Dock recovery has not yet been exercised.
- R13 was stopped by exact owned executable after confirming zero tasks and unauthenticated state; its files were preserved and its sidecar exit receipt remains false. R14b remains available for the official-login check. It had zero tasks, no models and authenticated=false at the diagnostic freeze.

Temporary local evidence: `/private/tmp/travelcat-native-window-r13/native-session/acceptance-metadata.json`, `/private/tmp/travelcat-native-window-r14b/native-session/acceptance-metadata.json`, `/private/tmp/travelcat-native-window-r14b-build.log` and `/private/tmp/travelcat-native-window-r14b-tests.log`. These files are not part of the public source and may be cleared by the operating system.

## Remaining acceptance

1. The user confirmed the complete R14b window is visible. Exercise its menu/Dock reopen and actual resize boundary; record resulting geometry rather than treating raw contentMinSize as an oracle.
2. Open the production official-login setup, check connection and open the official browser flow. The user completes password/OTP entry. Read back authentication and model availability from this independent profile.
3. In its empty workspace, submit the authorized bounded text-only task and interrupt only while actual task/thread/turn identifiers are active. Read the official interrupted terminal state and a fresh matching background count of zero. A request acknowledgement or a racing completed turn is insufficient.
4. Refresh metadata, close normally and verify actual sidecar exit before the existing ownership-receipt cleanup tool may stop only the owned daemon. Keep the official profile and diagnostic evidence.

The formal installed-app acceptance already recorded for PR #23 and older P0 account/interruption evidence are separate results and do not replace this fresh-profile acceptance.
