#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)
SWIFT_WRAPPER="$PROJECT_ROOT/Scripts/travel-cat-swift.sh"
PROVENANCE="$PROJECT_ROOT/Automation/provenance/travelcatctl-release.provenance"

if [ ! -x "$SWIFT_WRAPPER" ] || [ -L "$SWIFT_WRAPPER" ]; then
    echo "build-scheduled-cli: Swift wrapper is missing or unsafe" >&2
    exit 65
fi
SCRATCH_PATH=$("$SWIFT_WRAPPER" scratch-path)
PINNED_ROOT="$SCRATCH_PATH/travelcatctl-pinned"

"$SWIFT_WRAPPER" build --disable-sandbox -c release --product travelcatctl
BIN_DIR=$("$SWIFT_WRAPPER" build --disable-sandbox -c release --show-bin-path)
if [ ! -d "$BIN_DIR" ] || [ -L "$BIN_DIR" ]; then
    echo "build-scheduled-cli: release bin directory is missing or unsafe" >&2
    exit 65
fi
BIN_DIR=$(CDPATH= cd -- "$BIN_DIR" && pwd -P)
case "$BIN_DIR/" in
    "$SCRATCH_PATH"/*) ;;
    *) echo "build-scheduled-cli: release bin directory escaped external scratch" >&2; exit 65 ;;
esac
CANONICAL="$BIN_DIR/travelcatctl"
if [ ! -f "$CANONICAL" ] || [ -L "$CANONICAL" ] || [ ! -x "$CANONICAL" ]; then
    echo "build-scheduled-cli: release CLI is missing or unsafe" >&2
    exit 65
fi

SOURCE_SHA=$("$PROJECT_ROOT/Scripts/travelcatctl-source-digest.sh" "$PROJECT_ROOT")
BINARY_SHA=$(/usr/bin/shasum -a 256 "$CANONICAL" | /usr/bin/awk '{print $1}')
ARTIFACT_ID="$BINARY_SHA/travelcatctl"
PINNED_BINARY=$("$PROJECT_ROOT/Scripts/publish-pinned-travelcatctl.sh" "$CANONICAL" "$PINNED_ROOT")
if [ "$PINNED_BINARY" != "$PINNED_ROOT/$ARTIFACT_ID" ]; then
    echo "build-scheduled-cli: publisher returned an unexpected pinned artifact" >&2
    exit 65
fi

/bin/mkdir -p -- "$(dirname -- "$PROVENANCE")"
TEMP=$(/usr/bin/mktemp "$PROVENANCE.tmp.XXXXXX")
cleanup_provenance() { /bin/rm -f -- "$TEMP"; }
trap cleanup_provenance EXIT HUP INT TERM
/usr/bin/printf '%s\n' \
    'format=travel-cat-cli-provenance-v3' \
    'product=travelcatctl' \
    'configuration=release' \
    "sourceTreeSHA256=$SOURCE_SHA" \
    "binarySHA256=$BINARY_SHA" \
    "binaryArtifactID=$ARTIFACT_ID" >"$TEMP"
/bin/chmod 0644 "$TEMP"
/bin/mv -f -- "$TEMP" "$PROVENANCE"
trap - EXIT HUP INT TERM

VERIFIED_BINARY=$("$PROJECT_ROOT/Scripts/verify-travelcatctl-release.sh" "$PROVENANCE" "$PROJECT_ROOT" "$PINNED_ROOT")
if [ "$VERIFIED_BINARY" != "$PINNED_BINARY" ]; then
    echo "build-scheduled-cli: verifier returned an unexpected pinned artifact" >&2
    exit 65
fi
/usr/bin/printf '%s\n' "$PINNED_BINARY"
