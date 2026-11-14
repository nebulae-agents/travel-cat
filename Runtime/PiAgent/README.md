# AgentX Pi text runtime

The host starts one bundled Node process for each turn. The process reconstructs an
official `@earendil-works/pi-agent-core` Agent from the host's system/user/assistant
snapshot and the currently selected model. It streams through the official
`@earendil-works/pi-ai/api/openai-completions` adapter. No built-in model directory,
CLI session, environment credentials, or executable tools are used.

## Protocol

A single JSON request (at most 1 MiB) is sent over stdin:

```json
{"version":1,"baseURL":"https://openrouter.ai/api/v1","model":"vendor/model","secret":"<pipe-only credential>","messages":[{"role":"user","content":"Hello"}],"metadata":{"contextLength":131072}}
```

Stdout contains one JSON response, bounded to 128 KiB:

```json
{"version":1,"ok":true,"text":"Complete reply"}
```

Failures return only a fixed code: `invalid_request`, `missing_credential`,
`provider_error`, `runtime_error`, `tools_disabled`, `timeout`, or `cancelled`.
Partial, truncated, tool, malformed, and oversized replies are not accepted.
The supported remote endpoint is OpenRouter HTTPS. Explicit numeric loopback HTTP
URLs are allowed for local fixtures. Redirects and retries are disabled.

## Build and verify

Run `Scripts/build-pi-runtime.sh` from the repository. The script downloads Node
22.22.2 from nodejs.org with fixed architecture-specific SHA-256 values, runs
`npm ci --ignore-scripts --omit=dev` from the committed lockfile, and prints an
external artifact directory. It uses the existing private Swift build cache;
there is no `node_modules`, downloaded binary, or runtime artifact in the source
tree. Original dependency license files, dependency notices, the pinned Pi MIT
license, and Node's license accompany the runtime.

`Scripts/package-app.sh` copies `Helpers/PiAgent/node` and `Resources/PiAgent`
from that artifact into the application and signs Node before the outer app.
The Swift production bridge resolves only these bundled paths.

Run protocol tests against an artifact (all network traffic is local):

```sh
AGENTX_PI_RUNNER="$artifact/Resources/PiAgent/runner.mjs" \
  "$artifact/Helpers/PiAgent/node" --test Runtime/PiAgent/runner.test.mjs
```

Run Swift process tests plus the real bundled Pi/SSE integration:

```sh
AGENTX_PI_TEST_NODE="$artifact/Helpers/PiAgent/node" \
AGENTX_PI_TEST_RUNNER="$artifact/Resources/PiAgent/runner.mjs" \
  Scripts/travel-cat-swift.sh test --filter AgentXPiRuntimeTests
```

Without both explicit test paths, the integration test is skipped; process fixture
tests still run. The production bridge never reads these test environment values.
