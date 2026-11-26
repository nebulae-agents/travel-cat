#!/bin/zsh
set -euo pipefail
# Explicit integration gate: absence of the real bundled runtime is a failure,
# never an XCTest skip. It reads the bundle and uses disposable local data only.
if (( $# != 1 )); then
  print -u2 -- 'usage: run-agentx-permissions-acceptance.sh /path/to/Travel Cat.app'
  exit 64
fi
bundle="$(cd -- "$1" && pwd -P)"
node="$bundle/Contents/Helpers/PiAgent/node"
dependencies="$bundle/Contents/Resources/PiAgent/node_modules"
script_dir="$(cd -- "$(dirname -- "$0")" && pwd -P)"
project="$(cd -- "$script_dir/.." && pwd -P)"
[[ -x /usr/bin/sandbox-exec && -x "$node" && -d "$dependencies/@earendil-works/pi-agent-core" && -d "$dependencies/@earendil-works/pi-ai" ]] || {
  print -u2 -- 'M4 acceptance requires sandbox-exec and the real bundled Pi Node + dependencies.'
  exit 69
}
fixture="$(mktemp -d /private/tmp/agentx-m4-runtime.XXXXXX)"
trap 'rm -rf -- "$fixture"' EXIT
cp "$project/Runtime/PiAgent/runner.mjs" "$fixture/runner.mjs"
ln -s "$dependencies" "$fixture/node_modules"
export AGENTX_M4_ACCEPTANCE=1
export AGENTX_TEST_PI_NODE="$node"
export AGENTX_TEST_PI_RUNNER="$fixture/runner.mjs"
export AGENTX_PI_TEST_NODE="$node"
export AGENTX_PI_TEST_RUNNER="$fixture/runner.mjs"
cd "$project"
Scripts/travel-cat-swift.sh test --filter 'AgentXExecutionPolicyTests|AgentXPiSandboxTests|AgentXPiRuntimeTests|AgentXModelGatewayTests|AgentXHostGatewayTests|AgentXApplicationPolicyTests/testMissingNetworkPermissionBlocksNativeBeforeResponderAndPersistsEvent'
