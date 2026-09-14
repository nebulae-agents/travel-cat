#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/travel-cat-skill.XXXXXX")
trap 'rm -rf -- "$temporary_root"' EXIT INT TERM
mkdir -p "$temporary_root/clang-cache" "$temporary_root/swiftpm-cache"
export CLANG_MODULE_CACHE_PATH="$temporary_root/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$temporary_root/swiftpm-cache"

cd "$project_root"
swift_wrapper="$project_root/Scripts/travel-cat-swift.sh"
"$swift_wrapper" build --disable-sandbox --product travelcatctl >/dev/null
binary_dir=$("$swift_wrapper" build --disable-sandbox --show-bin-path)
travelcatctl="$binary_dir/travelcatctl"

export TRAVEL_CAT_MODE=fast

# Preparing: one claim, one validation, one publication, one-version advance.
export TRAVEL_CAT_DATA="$temporary_root/preparing"
export TRAVEL_CAT_NOW="2030-08-11T12:00:00Z"
preparing_before="$temporary_root/preparing-before.json"
preparing_claim="$temporary_root/preparing-claim.json"
preparing_validation="$temporary_root/preparing-validation.json"
preparing_ack="$temporary_root/preparing-ack.json"
preparing_after="$temporary_root/preparing-after.json"

"$travelcatctl" status > "$preparing_before"
"$travelcatctl" claim > "$preparing_claim"
jq -e '.due == true and .snapshot.stateVersion == 0 and .snapshot.phase == "resting"' "$preparing_claim" >/dev/null
"$travelcatctl" validate-candidate < Automation/fixtures/valid-kamakura-event.json > "$preparing_validation"
jq -e '.valid == true and .stateVersion == 0 and .publishEnvelope.next.stateVersion == 1' "$preparing_validation" >/dev/null
jq '.publishEnvelope' "$preparing_validation" | "$travelcatctl" publish > "$preparing_ack"
"$travelcatctl" status > "$preparing_after"
jq -e '.ok == true and .eventID == "10000000-0000-0000-0000-000000000001" and .stateVersion == 1' "$preparing_ack" >/dev/null
jq -e '.stateVersion == 1 and .lastEventID == "10000000-0000-0000-0000-000000000001"' "$preparing_after" >/dev/null
test "$(grep -cve '^[[:space:]]*$' "$TRAVEL_CAT_DATA/journal/events.jsonl")" -eq 1

# Postcard: materialize a coherent claimed state, then publish one pendingImage text event.
export TRAVEL_CAT_DATA="$temporary_root/postcard"
export TRAVEL_CAT_NOW="2030-08-12T09:30:00Z"
postcard_claim="$temporary_root/postcard-claim.json"
postcard_candidate="$temporary_root/postcard-candidate.json"
postcard_validation="$temporary_root/postcard-validation.json"
postcard_ack="$temporary_root/postcard-ack.json"
postcard_after="$temporary_root/postcard-after.json"

"$travelcatctl" status >/dev/null
jq '.snapshot' Automation/fixtures/claim-postcard.json > "$TRAVEL_CAT_DATA/state/current-trip.json"
jq -cn '
  {
    id: "20000000-0000-0000-0000-000000000001", tripID: "20000000-0000-0000-0000-000000000000",
    previousEventID: null, occurredAt: "2030-08-12T08:00:00Z", phase: "preparing",
    location: null, transport: null,
    summary: "黑猫收好车票和雨符，准备沿着镰仓的灯笼小径走向海边。",
    mood: {level: 0, label: "平静", quote: "先听一听清晨的风。"},
    continuityReferences: ["窗边的镰仓地图"], openHook: "Find the first lantern",
    consumedItemID: null, postcardStatus: "none", postcardRelativePath: null
  },
  {
    id: "20000000-0000-0000-0000-000000000002", tripID: "20000000-0000-0000-0000-000000000000",
    previousEventID: "20000000-0000-0000-0000-000000000001", occurredAt: "2030-08-12T08:40:00Z", phase: "transit",
    location: {country: "Japan", city: "Kamakura", place: "Kamakura Station"}, transport: "train",
    summary: "黑猫用掉车票抵达镰仓站，站前第一盏灯笼正朝小町通轻轻摇晃。",
    mood: {level: 1, label: "期待", quote: "第一盏灯已经出现了。"},
    continuityReferences: ["Find the first lantern"], openHook: "Follow the lantern into Komachi Street",
    consumedItemID: "train-ticket", postcardStatus: "none", postcardRelativePath: null
  },
  (input | .previousEvent)
' Automation/fixtures/claim-postcard.json > "$TRAVEL_CAT_DATA/journal/events.jsonl"
"$travelcatctl" claim > "$postcard_claim"
jq -e '.due == true and .snapshot.stateVersion == 3 and .snapshot.phase == "exploring" and .previousEvent.id == .snapshot.lastEventID' "$postcard_claim" >/dev/null
postcard_events_before=$(grep -cve '^[[:space:]]*$' "$TRAVEL_CAT_DATA/journal/events.jsonl")
test "$postcard_events_before" -eq 3
jq '{
  eventId: "20000000-0000-0000-0000-000000000004",
  tripId: .snapshot.tripID,
  previousEventId: .snapshot.lastEventID,
  occurredAt: "2030-08-12T09:30:00Z",
  phase: "postcardReady",
  location: {country: "Japan", city: "Kamakura", place: "Yuigahama Beach"},
  transport: "on foot",
  summary: "黑猫循着灯笼小径走到由比滨海岸，用雨符挡住细雨，并在潮声中拍下这一站的纪念照。",
  mood: {level: 0, label: "安定", quote: "雨符和潮声让我找回了方向。"},
  continuityReferences: [.snapshot.openHook, "carried rain-charm"],
  openHook: "Find where the last lantern points after sunset",
  consumedItemId: .snapshot.carriedItemID,
  postcard: {required: true, scenePrompt: "Rainy seaside selfie at Yuigahama Beach after following a lantern trail"}
}' "$postcard_claim" > "$postcard_candidate"
"$travelcatctl" validate-candidate < "$postcard_candidate" > "$postcard_validation"
jq -e '.valid == true and .stateVersion == 3 and .publishEnvelope.next.stateVersion == 4 and .publishEnvelope.event.postcardStatus == "pendingImage"' "$postcard_validation" >/dev/null
jq '.publishEnvelope' "$postcard_validation" | "$travelcatctl" publish > "$postcard_ack"
"$travelcatctl" status > "$postcard_after"
jq -e '.ok == true and .eventID == "20000000-0000-0000-0000-000000000004" and .stateVersion == 4' "$postcard_ack" >/dev/null
jq -e '.stateVersion == 4 and .lastEventID == "20000000-0000-0000-0000-000000000004"' "$postcard_after" >/dev/null
postcard_events_after=$(grep -cve '^[[:space:]]*$' "$TRAVEL_CAT_DATA/journal/events.jsonl")
test "$postcard_events_after" -eq "$((postcard_events_before + 1))"
jq -sce '.[-1].postcardStatus == "pendingImage" and .[-1].summary == "黑猫循着灯笼小径走到由比滨海岸，用雨符挡住细雨，并在潮声中拍下这一站的纪念照。"' "$TRAVEL_CAT_DATA/journal/events.jsonl" >/dev/null
postcard_file_count=$(find "$TRAVEL_CAT_DATA/postcards" -type f -print | wc -l | tr -d '[:space:]')
test "$postcard_file_count" -eq 0

# Due false: claim is read-only and produces no repository change.
export TRAVEL_CAT_DATA="$temporary_root/preparing"
export TRAVEL_CAT_NOW="2030-08-11T12:00:01Z"
due_false_before=$(cksum "$TRAVEL_CAT_DATA/state/current-trip.json" "$TRAVEL_CAT_DATA/journal/events.jsonl")
due_false_claim="$temporary_root/due-false-claim.json"
"$travelcatctl" claim > "$due_false_claim"
jq -e '.due == false and .snapshot.stateVersion == 1' "$due_false_claim" >/dev/null
due_false_after=$(cksum "$TRAVEL_CAT_DATA/state/current-trip.json" "$TRAVEL_CAT_DATA/journal/events.jsonl")
test "$due_false_before" = "$due_false_after"

jq -n \
  --arg preparingEvent "$(jq -r '.eventID' "$preparing_ack")" \
  --argjson preparingVersion "$(jq -r '.stateVersion' "$preparing_ack")" \
  --arg postcardEvent "$(jq -r '.eventID' "$postcard_ack")" \
  --argjson postcardVersion "$(jq -r '.stateVersion' "$postcard_ack")" \
  --argjson postcardFiles "$postcard_file_count" \
  '{preparing: {eventID: $preparingEvent, stateVersion: $preparingVersion, publishedEvents: 1}, postcard: {eventID: $postcardEvent, stateVersion: $postcardVersion, publishedEvents: 1, postcardStatus: "pendingImage", postcardFiles: $postcardFiles}, dueFalse: {repositoryChanged: false}}'
