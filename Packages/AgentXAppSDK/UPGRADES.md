# Trusted host application upgrades

`AppUpgradeManager` is a synchronous host service, independent of Travel Cat. It does not load or execute application/plugin code. Before each operation the host must stop application writes and exclusively control directory mutations under the root and package source. Filesystem scanning plus Foundation copy/rename is not a defense against a hostile process concurrently renaming directories. Apply the process sandbox separately.

An update package contains exactly `manifest.json` (SDK `AppManifest` JSON) and `payload/` (regular files and directories only). The installed application is `apps/<id>/`, with the same manifest and payload layout. This format is separate from the manager's YAML configuration; a host adapter must explicitly map the two before using this API in production.

Upgrade validates identity, host API compatibility, data paths, and links before mutation. It copies the complete old application into `backups/apps/<id>/<transaction>/before`, stages another complete copy, replaces only its manifest and payload, then publishes that staged app. User state, artifacts, instances, runs, and other app-owned files are retained. Snapshot copies are compared to their sources. Sibling applications, shared files and platform configuration are not modified.

Schema changes require a host-supplied `TrustedMigration` closure. The closure receives the staged app directory and both manifests, and must operate only on that staged directory. It is trusted Swift code with the host's authority, not untrusted package code. Manifest path changes are rejected; path relocation needs a separate contract. After migration the staged manifest must still match the update and the full tree must contain no symlinks, hardlinks or special files. A failed migration leaves the live app unchanged and retains transaction files for diagnosis/recovery.

```swift
let updates = try AppUpgradeManager(root: selectedRoot, hostAPIMajor: 1)
try updates.recover(appID: "notes") // before reopening or upgrading an app
let receipt = try updates.upgrade(appID: "notes", package: verifiedPackage)
// Explicit user/host rollback action, while app writes remain stopped:
try updates.rollback(receipt)
```

Rollback accepts the host-issued receipt, requires the live manifest to match its installed version, snapshots the current app (including post-upgrade writes), and restores the old complete snapshot. Receipts hold relative paths and remain usable after root relocation. Receipts are Codable host records. Their JSON is not a signature or an authorization grant; only the trusted host may choose an approved receipt for rollback. The repository host persists successful upgrade receipts, while automatic backup retention/deletion is not supplied.

A persistent `pending.json` marker is written before the live directory is moved. Call `recover(appID:)` on startup before opening an app: if publication was interrupted with no live app, it restores the completed old snapshot; if a valid old/new live app exists, it retains it and clears the marker. New updates refuse an unresolved marker. This handles process termination between filesystem operations, not power-loss durability; no fsync protocol is claimed. Recovery and all updates require the same exclusive host ownership. Backups are retained; this service never deletes user snapshots automatically.


## Repository host adapter

`AgentXAppLifecycleHost` in the host target bridges the existing `app.yaml` identity (`id`, `name`, `kind`) to the SDK's `manifest.json`. It preserves unknown YAML fields during upgrade and stores independent version/schema/runtime/module declarations in the manifest. It currently supports the repository's existing `blackcat`, `chat`, and `workbench` kinds and standard app-relative data paths; unsupported kinds/paths fail closed.

Use `register(appID:manifest:)` once for a pre-existing app without a manifest. The caller must supply the real baseline version and schema; neither is inferred from the manager version. Export includes only manifest and payload, never app user data or host YAML configuration. Import creates a new app with empty state/artifact/instance/run directories and refuses existing IDs. Upgrade requires an existing baseline, updates YAML inside SDK staging, and returns a rollback receipt. `inspectPackage` is read-only; `prepareStaging` is a trusted host metadata hook, not a schema migration bypass or package entrypoint.

The adapter checks both `writersHaveStopped()` and persisted running/cancelling records on every operation. The caller must acquire and hold the actual execution/write barrier; passing a Boolean closure alone does not stop workers. Invoke recovery before repository reopen, and reload repository state after import, upgrade or rollback before allowing a subsequent save. `AgentXAppLifecycleView` queues these actions rather than executing them while the host is active. `AgentXOfflineAppLifecycle` saves requests beside the root locator and binds a clean-exit receipt to the request ID and previous host PID. The next startup requires that PID to be absent and the startup writer gate to be closed before applying the action. An `applying` phase prevents automatic replay after an interrupted operation. Result/receipt history is retained beside the locator. Root migration and app lifecycle requests must not be pending together.

The UI distinguishes code-package export from full-state backup. Full backup copies the complete app directory, including private user data, without changing the original. It is not accepted as an installable code package. The UI offers baseline registration, new-ID code import, upgrade, last-upgrade rollback, and both export types. An imported manifest or empty payload does not establish an independently executable application; runtime activation/unknown-plugin loading is not performed by this adapter.
