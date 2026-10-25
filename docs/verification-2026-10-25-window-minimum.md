# Utility-window minimum recovery verification — 2026-10-25

The installed workbench could shrink to only its title-bar controls. A real AppKit raw-frame resize reproduced content 75x7 despite a configured 760x600 minimum. Native acceptance also observed the mutable native minimum become 0x0 during a draft/disclosure interaction. The exact framework call clearing the property was not isolated.

The controller now owns the intended route minimum independently of that mutable property. It configures the policy before hosting-view replacement, repairs native-property resets under a scoped reentrancy guard, and bounds recovery geometry to the current visible display. Workbench 760x600 and generation 600x630 pass their custom minima through the controller API. Ordinary routes can still shrink normally, and the stored minimum is not reduced to fit a small display.

## Regression evidence

- Original controller baseline: 3 tests passed.
- Before the first correction, raw-frame and oversized-minimum regressions produced 4 expected assertion failures. The native-property-reset regression then produced 3 expected assertion failures on the property-only implementation.
- Final focused run: 10 window tests passed, including 7 focused minimum/geometry regressions. Cases cover native-property clearing, repeated screen-bounded recovery, preserving the configured route policy, an ordinary resize above the minimum, album-to-status shrink and corner containment.
- Existing retained-window verification derives the expected content size from the display's available content area, including title chrome.
- Preview bundle preparation: 2 Python tests passed.
- Independent frozen review passed with no actionable P1/P2 findings across both production files, tests and the offline fixture.

## Native acceptance

`Tests/ManualAgentWorkbench/WindowMinimumPreview.swift` uses the production utility controller and complete workbench view, an in-memory credential store, a rejecting runtime and an independent temporary data root. It starts no real task and uses no account, Keychain or production records.

The final native fixture passed complete 760x600 and 1000x740 window captures. After editing an exact two-line draft and expanding a thought, an external 75x39 frame request recovered 760x600; the draft and expanded thought remained intact. The actual system Window > Move & Resize > Top Left operation also retained a complete 760x600 viewport. Returning to 1000x740 and forcing another tiny frame preserved state and again recovered 760x600. The fixture's own geometry receipt confirmed the content sizes and complete screen containment. The sample draft was cleared, thought collapsed and both temporary fixture apps exited after acceptance.

Build the isolated fixture through the existing preview wrapper with `TRAVEL_CAT_PREVIEW_SOURCE=WindowMinimumPreview.swift`; choose a fresh preview root/identity for each run. Its acceptance menu provides default, minimum and external-frame actions without adding diagnostic controls to the product.

This native evidence belongs to the offline production-view fixture. It does not establish that the formally installed application has received this branch; installation and post-install acceptance are separate delivery steps.

## Final full regression

The final stored-policy implementation passed the complete Swift suite: XCTest 1545 cases with 17 existing skips and 0 failures; Swift Testing 36 cases passed. Suite counts: TravelUITests 489, TravelStorageTests 389, TravelCoreTests 38, TravelCatAppTests 629. The source/test hashes remained equal to the independently reviewed five-file freeze. This supersedes the earlier property-only full-suite result.
