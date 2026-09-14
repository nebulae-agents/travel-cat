#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
PLUGIN="$ROOT/Plugins/travel-cat"

[ -f "$PLUGIN/.codex-plugin/plugin.json" ]
[ ! -L "$PLUGIN/.codex-plugin/plugin.json" ]
/usr/bin/plutil -convert xml1 -o /dev/null "$PLUGIN/.codex-plugin/plugin.json"

for path in \
  skills/travel-cat-heartbeat/SKILL.md \
  skills/travel-cat-heartbeat/references/event-contract.md \
  skills/travel-cat-heartbeat/references/postcard-prompt.md \
  skills/travel-cat-heartbeat/references/event-candidate.schema.json \
  skills/travel-cat-heartbeat/references/image-result.schema.json \
  skills/travel-cat-journal/SKILL.md \
  skills/travel-cat-journal/references/runtime-contract.md \
  scripts/travel-cat-launcher-lib.sh \
  scripts/run-travelcatctl
do
  [ -f "$PLUGIN/$path" ]
  [ ! -L "$PLUGIN/$path" ]
done

[ -x "$PLUGIN/scripts/run-travelcatctl" ]
[ -x "$PLUGIN/scripts/travel-cat-launcher-lib.sh" ]

if /usr/bin/grep -R -n -E '临时测试|swift run|\.build/debug|TravelCatApp|PetTravelBubbleController' "$PLUGIN"; then
  echo "production plugin contains forbidden acceptance/runtime text" >&2
  exit 65
fi

/usr/bin/cmp -s \
  "$ROOT/.agents/skills/travel-cat-agent/references/event-contract.md" \
  "$PLUGIN/skills/travel-cat-heartbeat/references/event-contract.md"
/usr/bin/cmp -s \
  "$ROOT/.agents/skills/travel-cat-agent/references/postcard-prompt.md" \
  "$PLUGIN/skills/travel-cat-heartbeat/references/postcard-prompt.md"
for schema in event-candidate.schema.json image-result.schema.json
do
  /usr/bin/cmp -s "$ROOT/Automation/schemas/$schema" \
    "$ROOT/.agents/skills/travel-cat-agent/references/$schema"
  /usr/bin/cmp -s "$ROOT/Automation/schemas/$schema" \
    "$PLUGIN/skills/travel-cat-heartbeat/references/$schema"
done

AUTHOR_HOME_PREFIX='/'"Users"'/'
if /usr/bin/grep -R -n -E "$AUTHOR_HOME_PREFIX|[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}" "$PLUGIN" "$ROOT/docs/installation.md"; then
  echo "portable plugin contains an author-specific path or private task identity" >&2
  exit 65
fi
