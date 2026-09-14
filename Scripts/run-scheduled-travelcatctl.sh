#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
PORTABLE_LAUNCHER="$ROOT/Plugins/travel-cat/scripts/run-travelcatctl"

if [ "$#" -ne 1 ]; then
    echo "scheduled-launcher: expected exactly one fixed CLI command" >&2
    exit 64
fi
COMMAND=$1
case "$COMMAND" in
    status|journal|pending-images|claim|validate-candidate|publish|mark-image) ;;
    *) echo "scheduled-launcher: command is not allowlisted" >&2; exit 64 ;;
esac

if [ ! -f "$PORTABLE_LAUNCHER" ] || [ -L "$PORTABLE_LAUNCHER" ] || [ ! -x "$PORTABLE_LAUNCHER" ]; then
    echo "scheduled-launcher: portable plugin launcher is missing or unsafe" >&2
    exit 65
fi

# The installed launcher verifies the signed app, bundled helper, provenance,
# fixed data root, and inherited stdin before it executes the command.
exec "$PORTABLE_LAUNCHER" "$COMMAND"
