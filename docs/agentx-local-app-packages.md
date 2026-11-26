# Local declarative application packages (v1)

This is the `app.yaml` configuration-install path. The existing SDK `AgentXAppLifecycleHost` / `AgentXOfflineAppLifecycle` code-upgrade path remains separate and unchanged. There is no Git/network installer, imported script execution, custom HTML/JS frontend, or runtime installation.

## Package layout

```
app.yaml
instances/<local-id>/config/agent.yaml
definitions/<local-id>.yaml
manifest.json                 # optional pair, only for declarative forms
payload/frontend.json         # optional pair, AppFrontendContract schema 1
```

`app.yaml` uses `AgentXApplication`: `id`, `name`, `kind: chat`, `enabled` (ignored: installation is always disabled), optional `runtime`, `modules`, optional `version`, `manifest`, `experience`, and `workflow`. `experience` uses the existing conversation/scene layout and published/draft configuration. No financial feed, autonomous branching engine, or other runtime is implied by scene presentation. Unknown top-level fields and payload files are rejected. YAML anchors, aliases, duplicate mapping keys, excessive depth, and YAML documents over 1 MiB are rejected.

The top-level `runtime` selects the application's text execution backend. An omitted value or `host-text` keeps the existing provider-based routing. Use `pi-agent-core` or `native-http` to select that adapter explicitly. When supplied, `manifest.requires.runtime` must match the selected value (use `host-text` with an omitted top-level value). Unknown or conflicting runtime declarations block installation and export. Installing or remapping a package preserves its declaration. Export preserves the selected backend and carries no runtime binaries or credentials.

An instance contains exactly `id`, `name`, `appID`, `definitionID`, `providerID`, `model`. A definition contains exactly `id`, `name`, `prompt`; its text must pass `AgentXDefinitionDocument.executionPrompt()` (no tools or unsupported runtime declarations). All definitions are bundled; external definition dependencies, definition file trees, revisions, credential profiles, variables, and conversation overrides are not imported.

Example instance:

```yaml
id: assistant
name: Assistant
appID: notes
definitionID: assistant
providerID: local
model: chosen-text-model
```

Example definition:

```yaml
id: assistant
name: Assistant
prompt: You are a helpful text conversation assistant.
```

The shared `AgentXLocalAppPackage.supportedBuiltinModules` list is `chat`, `history`, `runs`, `inbox`, `members`, `artifacts`, `settings`, `stage`, `world-state`, `npc-memory`, `director-intervention`. Scene modules refer to existing scene/context/member/backstage views, not new engines. The UI must route only those actual capabilities.

Optional forms require BOTH validated SDK `manifest.json` and `payload/frontend.json`: host API 1, data schema 1, kind `chat`, runtime `host-text` in the SDK manifest and legacy text routing in the application, canonical app paths, identical application/SDK/contract module lists, and only `form` modules. Unknown JSON fields are rejected. Form module IDs come from the validated contract rather than the built-in module list. ID overrides regenerate the SDK paths. Arbitrary payload files are rejected.

## Preview and install API

```swift
let lifecycle = AgentXApplicationLifecycle(repository: repository, requireIdle: hostBarrier)
let preview = try lifecycle.previewTemplate(.scene, appID: "tavern", providerID: selectedProviderID, model: selectedModelID)
// Alternatives:
let directoryPreview = try lifecycle.preview(directory: selectedURL, appIDOverride: "tavern-copy")
let zipPreview = try lifecycle.preview(zip: selectedZIP, appIDOverride: "tavern-copy")
// Display application metadata, instances, frontend, sourceDescription, sourceDigest,
// missingRequirements, and includedContent. Explicit confirmation submits this value:
try lifecycle.install(preview)
```

Preview never reads credentials or invokes inference. It reports absent/disabled providers or models and unsupported runtimes/modules/permissions. Permission support is limited to `files: [self]`, `network: [configured-provider]`, empty `secrets`, and `shell/schedule: false`. These are declarations; the trusted host validates and compiles them into narrowly scoped execution grants. Missing permissions deny the corresponding operation. Imported manifest strings are never interpolated into sandbox rules. The preview checks the declared runtime and configured models. Adapter availability, endpoint compatibility and usable credentials are checked at execution. Package definitions supply text prompts and cannot select a backend or grant tools.

The reviewed snapshot is immutable. Installation rechecks the source digest and current requirements, then publishes that reviewed configuration, never rereading unchecked payload. Duplicate app IDs never overwrite; an override assigns new globally unique instance/definition IDs and remaps workflow, experience-member and SDK references. Global definitions are never overwritten. Built-in `blackcat`/`workbench` IDs are reserved. Install creates the app/instance data directories and configured members but starts no run and leaves selection unchanged.

Directory/ZIP limits: 256 entries and 8 MiB total bytes. ZIP supports single-volume ZIP32 stored/deflated regular files and directories only. It rejects unsafe paths, case/Unicode duplicates, inconsistent local/central headers, overlapping/hidden records, links/special files, encryption, ZIP64, unknown extra fields, oversized outputs and expansion ratios over 100 (1 KiB minimum allowance). Deflated entries use bounded `/usr/bin/tar -xOf` stdout from a private snapshot, with actual-byte, CRC and per-process time limits; never direct extraction into live paths. No Python is required at runtime. Inspection is synchronous; hosts should show a busy state for local file review.

## Export, remove, and recovery

```swift
try lifecycle.exportApplication(appID, to: newDirectoryOutsideRoot)
let receipt = try lifecycle.uninstall(appID)   // destructive API, exercise on test roots only during development
try lifecycle.restore(receipt)
```

Export contains application settings, current published text prompts/configuration, model identifiers and optional form declaration. If a pinned instance revision would produce a different prompt than the current published definition, export refuses before creating the destination; it never silently upgrades that instance. Flattened prompts use an empty outer frontmatter wrapper so a literal body beginning with YAML fences is not parsed a second time. It excludes runs, conversations, artifacts, frontend input values, credential/profile references, instance variables/overrides, shared user memory, definition/revision histories and unknown executable payload. Prompts and authored configuration are included and must be reviewed before sharing; the exporter cannot recognize secrets that a person manually wrote into ordinary prompt text. It does not copy credential storage. Export never overwrites a destination and must be outside the live root.

Uninstall requires a disabled app and an injected positive idle barrier, rejects canonical built-ins, copies the complete app tree (including empty directories) into `backups/local-app-<uuid>/app`, verifies its file/directory digest, then writes `receipt.json` before removal. It rechecks the live digest before mutation. Backup/restore bounds are 64 MiB and 4096 entries; unsafe or oversized trees fail before deletion. `audit/<app>` and all other app bytes remain untouched. Global definitions are retained because they may have other consumers; a new installation uses new namespaced IDs. Restore verifies the receipt, backup location and digest, refuses collisions, validates existing provider/definition references, and restores the disabled app. Legacy manifests without `enabled` retain their exact bytes; the receipt records their disabled root projection and restoration reapplies that projection. This cannot authorize a manifest explicitly declaring `enabled: true`. Recovery receipts remain local and can contain private full-app data.

All publication mutations run synchronously on `MainActor`. `requireIdle(appID)` MUST check the host's complete in-memory snapshot has no active internal writer/task and that the target's external runtime has positively stopped; a view checkbox or bare manifest flag is not evidence. Hold this barrier until the operation and controller reload finish. The parent host must reload immediately after success without allowing an old controller snapshot to save first. Missing requirements or a failed barrier cause no publication.

A private root transaction journal records canonical root identity, before/after settings, duplicate stage record, and each owned directory's device/inode/content digest. Recovery validates every path, ownership proof, destination occupation and settings state before the first deletion/move. Repository loading rolls interrupted operations back before enumerating apps; malformed or conflicting journals block loading instead of guessing. Publication commits by deleting the root journal. Unknown root settings use the repository's exact integer-preserving YAML constructor, including nested UInt64 values and quoted numeric strings. No existing SDK transaction format is interpreted by this path.


## M4 local execution boundary

Pi children launch through macOS `sandbox-exec` with a deny-default profile; a missing policy or failed sandbox launch never falls back to ordinary execution. Production Pi requests require the host-owned model gateway. The child gets the one dynamically bound IPv4 loopback TCP port, not general local-network or Internet access. Runtime executable, runner and pinned dependencies are read-only; their ancestor directories allow metadata lookup only. Runtime paths are host-controlled and resolved with `realpath`; they must not point into untrusted application data.

`files: [self]` grants read/write access to `apps/<id>/state` and `apps/<id>/artifacts`, and read-only access to `apps/<id>/payload`. It does not grant application manifests, runs, event journals, manager configuration, siblings or shared directories. Empty/missing `files` grants no application data access. Granted trees reject pre-existing symlinks, nonregular files and multiply linked files before launch. The host must retain ownership of ancestor directories and exclude concurrent import/rename/link mutations while a child is running. Descendants inherit the same OS sandbox.

`network: [configured-provider]` authorizes only the selected provider's scheme, normalized host and effective port. Native direct requests also enforce this permission before resolving credentials. The model gateway checks permission before credentials, budget reservation or upstream submission. Production HTTP clients disable system proxies and redirects; HTTPS keeps normal TLS hostname verification. This is origin authorization, not DNS/IP pinning or a general private-IP/SSRF firewall. Explicit loopback HTTP providers remain supported for local services. The native provider's trailing empty `#` exact-endpoint marker is retained; actual URL fragments are rejected.

Trusted host policy denials are written atomically and fsynced to `apps/<id>/events/permissions/<eventID>.json` before returning failure. Records include `kind: permission.denied`, `source: host_policy`, app ID, operation, timestamp and run ID when available; no credentials, request bodies or arbitrary child stderr are recorded. Invalid manifests, unauthorized upstream requests, unsafe granted file trees and scoped gateway mismatches use this path. Failure to persist a denial also fails closed.

Raw denied file/socket system calls inside a child are enforced by the OS, but they cannot all be reliably observed by the parent. A child can catch an error or suppress stderr. The persistent policy records therefore do **not** claim complete per-syscall audit coverage. The real-Node acceptance probes observe OS error codes independently; those observations are test evidence, not fabricated production permission events. An unscoped low-level runtime invocation has no trusted app identity and fails before launch without inventing an app event.

Tools and steps remain disabled. `shell: false` means no shell tool is exposed; this milestone does not promise a separate shell-execution/system-call allowlist. File and network confinement still applies to spawned descendants. A future trusted file/tool broker is required for complete action-by-action permission audit.

### Explicit integration acceptance

Ordinary unit tests do not require a personal installed Node. Run the mandatory real-runtime gate explicitly:

```sh
Scripts/run-agentx-permissions-acceptance.sh '/path/to/Travel Cat.app'
```

The gate checks the supplied bundled Node/Pi dependencies, copies the current runner into a disposable directory, references the existing dependencies read-only, and enables all integration tests. Missing runtime or unavailable OS sandbox is a failure. It covers actual confined file access, sibling/manager/event protection, read-only payloads, symlink/hardlink rejection, exact loopback port access, trusted denial event persistence before credential/budget access, real Pi workflow execution and lifecycle cancellation. It does not install, publish, mutate the supplied app bundle or run against production application data.

The desktop integration gate exercises the production writer with two explicitly authorized applications and `events-v1` storage:

```sh
python3 Scripts/run-agentx-permissions-desktop-acceptance.py '/path/to/Travel Cat.app' \
  --output /private/tmp/agentx-m4-desktop-new
```

Use `--products /path/to/pinned/debug` when testing an immutable build snapshot. The output directory must be new. This gate verifies concurrent Pi execution, stopping one application without interrupting the other, independent audit records, cross-app run rejection, restart readback, and network-permission revocation followed by a durable host-policy denial without another upstream call.

Local evidence on 2026-11-26: the explicit M4 gate passed 35 tests with no skips; the AgentX regression run reported 347 XCTest cases (343 passed, four conditional integration skips) and 64 Swift Testing cases (60 passed, four conditional real-Pi skips), with no failures; the SDK passed 14 tests, including its actual sandbox subprocess test. The separate desktop gate passed with two desktop starts, three successful provider calls and one persisted network denial after revocation; the provider-call count stayed at three. Its immutable binary SHA-256 was `8663e9666e2fd5e05b935cfdd8dc4cf9582d20031bf6f0f16fc92dc8120aff80`. An earlier desktop attempt stopped at a fixture-only JSON/YAML readback error. Independent review then tightened the upstream-call assertion and restored process-identity checks before interruption; the final unchanged-binary desktop run passed after those harness corrections. Earlier harness results are not substituted for this final gate. These results establish local automated/isolated-desktop behavior, not installation or remote publication.

New built-in and newly created host text applications now write the same explicit minimal text permissions as built-in templates, with empty secret grants and shell/schedule disabled. Existing or imported manifests without permissions are not silently upgraded. To revoke an existing permission, write an explicit empty list; the repository's source-preserving save behavior does not treat an omitted optional field as a deletion.
