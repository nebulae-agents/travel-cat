# Travel Cat contributor guidance

- Use `Scripts/travel-cat-swift.sh test` and the same wrapper for Swift builds so caches remain outside the checkout. Run only one Swift process at a time.
- Keep any Git worktrees outside the repository. Preserve unrelated changes and do not rewrite existing history.
- `.local/` contains private deployment configuration, backups and receipts. Never stage, publish, export, print its contents in issue reports, or delete it as build cleanup.
- `TravelPetData` is user state. Do not delete, migrate, reset, stage or move it without an explicit request for that exact operation.
- Keep original `Assets`, `Fixtures`, `Tests/Fixtures` and `Sources/TravelUI/Resources` unchanged unless asset changes are specifically requested. Files ending in `.log`, `.out` or `.err` in those trees may be intentional fixtures.
- Before committing or publishing, run `python3 Scripts/github_preflight.py` and `Scripts/audit-project-upload.sh`. Do not globally raise the file-size limit or bypass a blocked audit. Original large resources require the exact reviewed path, size and digest in the public asset policy.
- `dist` is rebuildable packaging output. Remove only the known output after installation verification; keep deployment backups and real data.
- Local deployment and GitHub publication are separate actions. Do not upload, create remotes, modify Codex caches, enable generation or change the selected pet as a side effect of an unrelated task.
- Do not change the public license status without the author's explicit choice. Preserve third-party font notices.
