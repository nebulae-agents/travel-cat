# Export destination containment (2026-10-26)

## Problem and design

Audit priority 2: a destination beneath the live repository causes export staging to be created beneath the same repository. The character-tree copy includes hidden files, so it can enumerate staging and recursively copy it into itself, exhausting path or disk limits while the synchronous export blocks the UI.

Validate the destination before creating staging. Walk its resolved ancestry and compare filesystem device/inode identities with the repository root, rejecting the root and physical descendants, including symbolic-link and case aliases. Shared textual prefixes alone are not containment; sibling destinations and external symbolic-link parents remain valid. Existing no-overwrite and source-link checks remain in force. The settings UI gives a Chinese instruction to choose another location.

This is a stable-filesystem containment check, not protection against another process deliberately renaming directories between validation and export. No source tree or history is reset or moved.

## Safe reproduction

Six filesystem tests ran against the original code with ten failed assertions. A destination under postcards reproduced unwanted successful internal export without recursion, because the old postcard copy skips hidden staging. The characters/nested/symlink tests put a source-link sentinel in postcards, forcing old code to abort before reaching the recursive character copy; they require the new destination-specific rejection before any tree is read. This avoids executing the dangerous disk-filling behavior even if the guard regresses.

Tests also cover root rejection, case aliases on supported volumes, source bytes and staging cleanup, external destinations and a sibling with the same textual prefix. All fixtures use owned temporary directories; no real Travel Cat data is touched.

## Validation

The first full run found a bug in the new URL ancestry traversal: Foundation can extend the filesystem root into `/..` rather than terminate. A focused path probe reproduced it. The final implementation uses POSIX `realpath` on the nearest existing ancestor and terminating NSString path ancestry; no diagnostic output remains. The final full storage run passed 395 tests (1 opt-in skip) with zero failures, including the six destination tests and existing export/history/character/artwork coverage. Independent read-only review and upload preflight/audit passed. Installed-client and remote-host acceptance are not claimed; no application has been installed for this change.
