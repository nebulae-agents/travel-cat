#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/travelcat-agent-contract.XXXXXX")
lock_pid=""
cleanup() {
    if [[ -n "$lock_pid" ]]; then kill "$lock_pid" 2>/dev/null || true; wait "$lock_pid" 2>/dev/null || true; fi
    rm -rf -- "$temporary_root"
}
trap cleanup EXIT INT TERM

cd "$project_root"
swift_wrapper="$project_root/Scripts/travel-cat-swift.sh"
"$swift_wrapper" build --disable-sandbox --product travelcatctl >/dev/null
binary_dir=$("$swift_wrapper" build --disable-sandbox --show-bin-path)
travelcatctl="$binary_dir/travelcatctl"
jq empty Automation/schemas/event-candidate.schema.json
node Automation/tests/event-candidate-quote-schema.mjs Automation/schemas/event-candidate.schema.json >/dev/null
timestamp_pattern=$(jq -r '.properties.occurredAt.pattern' Automation/schemas/event-candidate.schema.json)
jq -ne --arg pattern "$timestamp_pattern" '"2028-02-29t12:00:00.125z" | test($pattern)' >/dev/null
jq -ne --arg pattern "$timestamp_pattern" '"0001-01-01T00:00:00Z" | test($pattern)' >/dev/null
jq -ne --arg pattern "$timestamp_pattern" '"0000-01-01T00:00:00Z" | (test($pattern) | not)' >/dev/null
jq -ne --arg pattern "$timestamp_pattern" '"2028-02-29T12:00:60Z" | (test($pattern) | not)' >/dev/null

export TRAVEL_CAT_DATA="$temporary_root/data"
export TRAVEL_CAT_MODE=fast
export TRAVEL_CAT_NOW="2030-08-11T12:00:00Z"

before="$temporary_root/before.json"
valid="$temporary_root/valid.json"
invalid="$temporary_root/invalid.json"
structural="$temporary_root/structural.json"
published="$temporary_root/published.json"
collision="$temporary_root/collision.json"
busy="$temporary_root/busy.json"
quiet="$temporary_root/quiet.txt"
duplicate="$temporary_root/duplicate.json"
oversized="$temporary_root/oversized.json"
after="$temporary_root/after.json"

"$travelcatctl" status > "$before"
jq -e '.stateVersion == 0' "$before" >/dev/null

lock_ready="$temporary_root/lock-ready"
python3 -c 'import fcntl,sys,time,pathlib; f=open(sys.argv[1],"a"); fcntl.flock(f,fcntl.LOCK_EX); pathlib.Path(sys.argv[2]).touch(); time.sleep(30)' \
    "$TRAVEL_CAT_DATA/.repository.lock" "$lock_ready" &
lock_pid=$!
while [[ ! -f "$lock_ready" ]]; do sleep 0.01; done
set +e
"$travelcatctl" validate-candidate < Automation/fixtures/valid-kamakura-event.json > "$busy"
busy_status=$?
"$travelcatctl" claim > "$quiet"
claim_status=$?
set -e
kill "$lock_pid" 2>/dev/null || true
wait "$lock_pid" 2>/dev/null || true
lock_pid=""
test "$busy_status" -eq 75
jq -e '.valid == false and .stateVersion == -1 and .violations == ["repositoryBusy"] and (.publishEnvelope == null)' "$busy" >/dev/null
test "$claim_status" -eq 0
test ! -s "$quiet"

set +e
sed 's/"phase": "preparing"/"phase": "preparing", "ph\\u0061se": "preparing"/' \
    Automation/fixtures/valid-kamakura-event.json \
    | "$travelcatctl" validate-candidate > "$duplicate"
duplicate_status=$?
dd if=/dev/zero bs=1048577 count=1 2>/dev/null \
    | "$travelcatctl" validate-candidate > "$oversized"
oversized_status=$?
set -e
test "$duplicate_status" -eq 65
jq -e '.valid == false and .stateVersion == 0 and .violations == ["duplicateKey:phase"]' "$duplicate" >/dev/null
test "$oversized_status" -eq 65
jq -e '.valid == false and .stateVersion == 0 and .violations == ["tooLarge"]' "$oversized" >/dev/null

"$travelcatctl" validate-candidate < Automation/fixtures/valid-kamakura-event.json > "$valid"
jq -e '.valid == true and .stateVersion == 0 and .violations == [] and (.publishEnvelope.event.id != null) and (.publishEnvelope.next.stateVersion == 1)' "$valid" >/dev/null

"$travelcatctl" status > "$after"
jq -e '.stateVersion == 0' "$after" >/dev/null

set +e
"$travelcatctl" validate-candidate < Automation/fixtures/invalid-mood-jump.json > "$invalid"
invalid_status=$?
set -e
test "$invalid_status" -eq 66
jq -e '.valid == false and .stateVersion == 0 and .violations == ["moodJump"] and (.publishEnvelope == null)' "$invalid" >/dev/null

set +e
jq '.unexpected = true' Automation/fixtures/valid-kamakura-event.json \
    | "$travelcatctl" validate-candidate > "$structural"
structural_status=$?
set -e
test "$structural_status" -eq 65
jq -e '.valid == false and .stateVersion == 0 and .violations == ["unknownKey:unexpected"] and (.publishEnvelope == null)' "$structural" >/dev/null

"$travelcatctl" status > "$after"
jq -e '.stateVersion == 0' "$after" >/dev/null

jq '.publishEnvelope' "$valid" | "$travelcatctl" publish > "$published"
jq -e '.ok == true and .stateVersion == 1' "$published" >/dev/null

export TRAVEL_CAT_NOW="2030-08-11T12:02:00Z"
set +e
jq '.previousEventId = .eventId | .phase = "transit" | .occurredAt = "2030-08-11T12:02:00Z"' \
    Automation/fixtures/valid-kamakura-event.json \
    | "$travelcatctl" validate-candidate > "$collision"
collision_status=$?
set -e
test "$collision_status" -eq 66
jq -e '.valid == false and .stateVersion == 1 and .violations == ["duplicateEventID"] and (.publishEnvelope == null)' "$collision" >/dev/null

"$travelcatctl" status > "$after"
jq -e '.stateVersion == 1' "$after" >/dev/null

echo "agent contract verified"
