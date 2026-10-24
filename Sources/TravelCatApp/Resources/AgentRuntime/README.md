# Isolated ACP runtime

Host: Python 3.11+, Docker CLI and a reachable Docker engine. SSH mode additionally
requires a preconfigured trusted host alias (optionally `user@host`), Docker on that host, and existing
known-host verification. No automatic installation, image pull or login fallback. Optional
`instance.dockerContext` (and `discover.params.dockerContext`) selects a named
Docker context explicitly without changing the global default. Context names
allow letters, digits, dot, underscore and hyphen; arbitrary socket/CLI options
are not accepted. SSH applies that context on the selected remote host.

The selected image must contain Python 3.11+ and an installed ACP v1 adapter at the
configured executable argv. Specify `repository@sha256:<64 lowercase hex>`; mutable
tags are rejected. The Dockerfile is a base recipe, not a ready-to-run agent image.
Build a reviewed adapter image separately and configure its resolved digest.

Each task has an independent `/tmp/workspace` in a 256 MiB tmpfs. It starts empty
unless the user explicitly selects input files. There are no host directory mounts
or automatic repository imports. `start.files` accepts up to 32 flat files, 1 MiB
each / 4 MiB total, encoded as `{name,base64}`. Dot names, path separators and
credential-like names (key/secret/token/credential and private-key extensions) are
denied. Filename checks do not prove that arbitrary selected content is secret-free;
only user-selected bytes are transferred.

`artifacts {taskId}` lists regular files as `{files:[{path,size}]}` with depth 8,
200 files and 1,000 visited entries as hard bounds. `export {taskId,path}` returns
`{name,base64}` for one regular file up to 4 MiB. Both reject symlinks, hardlinks,
credential-like paths and out-of-workspace traversal. The host executes trusted
Python source via fixed argv and JSON stdin; descriptor-relative `O_NOFOLLOW`
operations protect every directory and final file. Python isolated mode disables
writable-directory imports and site hooks. No archive extraction is performed.
Files remain ephemeral and are lost on stop unless the user exports them.
Repository writeback, runtime installation/authentication flows and offline
continuation are not implemented.

The host launches a nonroot read-only container with no network, capabilities,
host mounts or Docker socket. CPU/memory/process limits and a one-hour host watchdog
are configured by the run plan. Image-declared volumes are rejected. The trusted relay source is read from bundled host resources and passed directly
to isolated Python via fixed `docker exec` argv. It listens on container loopback
only. No `docker cp`, tar transfer or container-writable script is used. Relay and
ACP adapter have independent `docker exec -i` stdio channels. SSH wraps these same
Docker operations with strict host-key checking; no credentials are copied remote.

The agent receives placeholder API keys, loopback service addresses and a logical
model alias. The host holds the real provider config only in process memory and
injects authentication into a fixed HTTPS route. Request model is overridden;
client headers are never forwarded; redirects and upstream error bodies are denied.
No proxy environment is consulted by HTTPSConnection. Successful model output is
untrusted conversation content; the model provider itself must be trusted with the
credential. Only bases ending in `/v1` or the origin root are supported.

Limits: 8 tasks, 4 model requests/task concurrently, 256 requests/task lifetime,
1 MiB HTTP body, 2 MiB stdio record, 8 MiB/10,000 cumulative ACP records per task,
32 MiB model response, 120-second model request
window (socket operations also have 30-second timeout), 1-hour task/turn lifetime.
Stop serializes with request admission and revokes further forwarding; an already-admitted
request may finish submission before stop acknowledges, and its upstream socket may take
up to its timeout to close. Network loss can prevent remote cleanup confirmation;
the UI reports unknown. `stop` returns `{stopped:false}` until Docker removal is
confirmed; the task remains tracked and another stop retries cleanup. Failed
startup error responses include `taskRetained` to distinguish confirmed cleanup
from a task still needing stop/retry. Failed startup also retains an unconfirmed container and reports its generated name for
manual cleanup if necessary. Only `{stopped:true}` confirms cleanup. The container sleeper is a fallback only: a hostile
adapter can interfere with a same-UID process. Remote termination is not guaranteed
while the host is unreachable; inspect/remove the named container on that host.

Host filesystem and terminal ACP callbacks are denied. Permissions require a
current connection-local opaque ID and a runtime-offered option; duplicate and
expired decisions fail. One sweep thread per task checks expirations. After 120 seconds the permission is removed, the adapter
receives a cancelled outcome, and the UI receives `permissionExpired {requestId}`. Cancellation only sends `session/cancel`; cancelled state
requires the prompt response's `stopReason: cancelled`. ACP disconnection fails
pending requests and destroys the associated container where reachable.

Run: `python3 sidecar.py` (newline JSON on stdin/stdout, no logs with secrets).
Commands: scan_local/discover/probe/probe_cleanup/start/prompt/cancel/permission/artifacts/export/stop.
`scan_local` reads fixed CLI names (`codex`, `claude`, `dsh`) from executable paths and
current-UID process names only; it does not run those CLIs or read their sessions or
credentials. It lists Docker contexts but only contacts local Unix-socket endpoints.
Each context has a bounded independent info/image/container query. Remote contexts
are never automatically contacted. CLI processes and existing containers are
informational, not attached sessions.

`probe` takes one listed local context, pinned image and structured adapter argv.
It checks the candidate again, creates a nonroot read-only, network-disabled container,
performs ACP `initialize` and `session/new` with placeholder model values, and never
sends a prompt. `compatible:true` requires both handshake success and confirmed
container removal. An unconfirmed removal retains a probe ID and container name for
`probe_cleanup`; EOF also retries removal. The native host records probe request and
result in its encrypted management audit before accepting a compatibility proof.
The proof is limited to the selected context, digest and command and is not evidence
that an existing CLI session can be adopted or that paid model calls work.
Control records allow 6 MiB for base64 file transfer; ACP records retain the lower limit. See the Swift client for the
UI contract. EOF stops all tasks. Do not terminate with SIGKILL if cleanup is needed.

Tests: `python3 -m unittest discover -s Tests/AgentRuntimeTests -v` from repository.
Unit and process tests do not establish Docker isolation or compatibility with any
specific Codex, Claude or DSH release. Real engine, SSH and provider integration
acceptance remain mandatory before making those claims.

## Model audit and consent (first supported slice)

Production requires the native encrypted audit journal. Every `audit` event carries
`taskId`, `data.receiptId` and `data.record` with `eventId`, `taskId`, `kind`,
ISO-8601 `timestamp`, and model `callId`. The native host must durably save the
record before sending `audit_ack {receiptId, accepted:true}`. Rejection or a
30-second receipt timeout latches the broker unavailable; restart only after the
journal problem is repaired. A forwarding audit failure also stops and cleans
up its owned runtime; unconfirmed container removal remains retryable through
stop. No plaintext Python journal is created. Receipt and
model permission commands bypass the ordinary 24 worker slots.

`start.modelPolicy` defaults to `review`. After a persisted `model.request`,
`modelApproval {callId,requestHash,destination,model}` asks for one exact call;
`model_permission {taskId,callId,requestHash,allow}` expires after 120 seconds and
cannot be reused. During approval, buffered upstream work and each audit receipt
wait, the host sends control-only keepalives every 10 seconds. These reset the
relay 125-second idle wait without releasing HTTP headers or body. Approval,
upstream, receipt and overall task deadlines remain enforced independently.
Explicit `task` policy records a task-scoped destination grant
and skips individual dialogs, but still persists every request and decision.
This grant covers selected file content and task execution context; it does not
promise complete input provenance. Stop revokes admission immediately.

Requests are transformed to the fixed configured model, serialized once as
canonical UTF-8 JSON and SHA-256 hashed; the exact immutable bytes are submitted.
`model.request` stores sanitized `body`, `destination`, `model`, `api`,
`requestHash`, `bodyRedacted` and byte count. A true `bodyRedacted` means the
displayed body was scrubbed and cannot be used to recompute the hash of the
actual submitted bytes. Provider keys/auth headers are excluded. Opaque
file IDs, remote image/file URLs (including Anthropic image/document URL
sources), previous-response/conversation references and
hosted external tools are rejected in this first slice; supply inline content.
`model.decision` records `allow`, `policy` and `requestHash` before submission.
`model.response` records sanitized UTF-8 text in ordered ≤16 KiB fragments;
`model.completed` includes `status`, `complete` and provider-reported `usage`;
`model.failed` records a bounded safe reason. Known provider-key redaction spans
network chunk boundaries, including escaped JSON forms. The same sanitized text
fragments are persisted before being returned to the container; raw upstream
chunks are never forwarded. Responses (including SSE) are buffered up to the
existing 32 MiB limit before release. Decoded string deltas are checked across
events, including Chat Completions content/tool arguments, Responses text/tool
argument deltas and Anthropic text/partial-JSON deltas. A reconstructed provider
key withholds the entire body and records failure. This deliberately delays all
response delivery until the upstream response completes. Protection is limited
to the known provider key in exact/JSON-escaped form; it does not claim to block
arbitrary encodings or detect all user secrets.

Usage exposes `totalInput`, `output`, `cacheRead`, `cacheWrite`, `source`
(`reported` or `unknown`) and `rawUsage`; missing values are null, never zero
estimates. JSON and SSE usage are recognized. No prices, exchange rates, costs
or monetary hard caps are inferred. Request bodies are bounded to 1 MiB and
serialized audit records to 2 MiB. ACP tool permission requests persist their request token, offered options and
reported toolCall details (recursively scrubbed for the known provider key)
before UI presentation. Failed persistence stops the task. Export requests
include the relative artifact path, without file contents. These reported ACP
operations are not full syscall monitoring. Start, tool permission, stop, cancel, input
import and output export audit records describe operation requests, not a claim
that the operation completed. Input import records contain each selected file name, decoded byte count and
SHA-256, without its base64 body. Start records include the pinned image, adapter
argv, host/context and fixed sandbox boundaries. Model requests and approval
prompts identify the final HTTPS URL including the configured API route; task
grants explicitly identify their fixed-base/API scope. File bytes and exported
content are not duplicated in these operation metadata records.

Configurable retention, deletion/export of journal history, price budgets,
complete hosted-tool supervision and broader provider payload support remain
future extensions. Existing conversation storage is separate from this new
journal and is not retroactively encrypted by this change.
