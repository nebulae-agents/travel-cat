#!/bin/sh
set -eu

if [ "$#" -ne 3 ]; then
    echo "release-verifier: expected provenance, project root, and external pinned root" >&2
    exit 64
fi

PROVENANCE=$1
PROJECT_ROOT=$2
PINNED_ROOT=$3
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
case "$PROVENANCE:$PROJECT_ROOT:$PINNED_ROOT" in
    /*:/*:/*) ;;
    *) echo "release-verifier: all paths must be absolute" >&2; exit 64 ;;
esac

if [ ! -f "$PROVENANCE" ] || [ -L "$PROVENANCE" ]; then
    echo "release-verifier: provenance is missing or unsafe" >&2
    exit 65
fi
if [ ! -d "$PROJECT_ROOT" ] || [ -L "$PROJECT_ROOT" ]; then
    echo "release-verifier: project root is missing or unsafe" >&2
    exit 65
fi
if [ ! -d "$PINNED_ROOT" ] || [ -L "$PINNED_ROOT" ]; then
    echo "release-verifier: pinned root is missing or unsafe" >&2
    exit 65
fi
PINNED_ROOT_OWNER=$(/usr/bin/stat -f '%u' "$PINNED_ROOT" 2>/dev/null || true)
PINNED_ROOT_MODE=$(/usr/bin/stat -f '%Lp' "$PINNED_ROOT" 2>/dev/null || true)
if [ -z "$PINNED_ROOT_OWNER" ] || [ "$PINNED_ROOT_OWNER" != "$(/usr/bin/id -u)" ]; then
    echo "release-verifier: pinned root must be owned by the current user" >&2
    exit 65
fi
case "$PINNED_ROOT_MODE" in
    ''|*[!0-7]*) echo "release-verifier: pinned root permissions are unreadable" >&2; exit 65 ;;
esac
if [ $((0$PINNED_ROOT_MODE & 022)) -ne 0 ]; then
    echo "release-verifier: pinned root must not be group- or world-writable" >&2
    exit 65
fi
PROJECT_ROOT=$(CDPATH= cd -- "$PROJECT_ROOT" && pwd -P)
PINNED_ROOT=$(CDPATH= cd -- "$PINNED_ROOT" && pwd -P)
case "$PINNED_ROOT/" in
    "$PROJECT_ROOT"/*) echo "release-verifier: pinned root must be outside the project" >&2; exit 65 ;;
esac

LINE_COUNT=$(/usr/bin/wc -l <"$PROVENANCE" | /usr/bin/tr -d ' ')
FORMAT=$(/usr/bin/sed -n '1p' "$PROVENANCE")
PRODUCT=$(/usr/bin/sed -n '2p' "$PROVENANCE")
CONFIGURATION=$(/usr/bin/sed -n '3p' "$PROVENANCE")
SOURCE_LINE=$(/usr/bin/sed -n '4p' "$PROVENANCE")
BINARY_LINE=$(/usr/bin/sed -n '5p' "$PROVENANCE")
ARTIFACT_LINE=$(/usr/bin/sed -n '6p' "$PROVENANCE")
if [ "$LINE_COUNT" -ne 6 ] ||
    [ "$FORMAT" != "format=travel-cat-cli-provenance-v3" ] ||
    [ "$PRODUCT" != "product=travelcatctl" ] ||
    [ "$CONFIGURATION" != "configuration=release" ]; then
    echo "release-verifier: malformed provenance" >&2
    exit 65
fi
case "$SOURCE_LINE" in sourceTreeSHA256=*) ;;
    *) echo "release-verifier: malformed source provenance" >&2; exit 65 ;;
esac
case "$BINARY_LINE" in binarySHA256=*) ;;
    *) echo "release-verifier: malformed binary provenance" >&2; exit 65 ;;
esac
case "$ARTIFACT_LINE" in binaryArtifactID=*) ;;
    *) echo "release-verifier: malformed artifact provenance" >&2; exit 65 ;;
esac

EXPECTED_SOURCE=${SOURCE_LINE#sourceTreeSHA256=}
EXPECTED_BINARY=${BINARY_LINE#binarySHA256=}
ARTIFACT_ID=${ARTIFACT_LINE#binaryArtifactID=}
for DIGEST in "$EXPECTED_SOURCE" "$EXPECTED_BINARY"; do
    if [ "${#DIGEST}" -ne 64 ]; then
        echo "release-verifier: malformed SHA-256" >&2
        exit 65
    fi
    case "$DIGEST" in *[!0-9a-f]*) echo "release-verifier: malformed SHA-256" >&2; exit 65 ;; esac
done
if [ "$ARTIFACT_ID" != "$EXPECTED_BINARY/travelcatctl" ]; then
    echo "release-verifier: artifact ID does not match the binary hash" >&2
    exit 65
fi

PINNED_DIR="$PINNED_ROOT/$EXPECTED_BINARY"
PINNED_BINARY="$PINNED_ROOT/$ARTIFACT_ID"
if [ ! -d "$PINNED_DIR" ] || [ -L "$PINNED_DIR" ] ||
    [ ! -f "$PINNED_BINARY" ] || [ -L "$PINNED_BINARY" ] || [ ! -x "$PINNED_BINARY" ]; then
    echo "release-verifier: pinned release CLI is missing or unsafe" >&2
    exit 65
fi
if [ "$(/usr/bin/stat -f '%Lp' "$PINNED_DIR")" != 555 ] ||
    [ "$(/usr/bin/stat -f '%Lp' "$PINNED_BINARY")" != 555 ]; then
    echo "release-verifier: pinned release CLI is not immutable" >&2
    exit 65
fi
if [ ! -x "$SCRIPT_DIR/travelcatctl-source-digest.sh" ] || [ -L "$SCRIPT_DIR/travelcatctl-source-digest.sh" ]; then
    echo "release-verifier: source digest tool is missing or unsafe" >&2
    exit 65
fi

ACTUAL_SOURCE=$("$SCRIPT_DIR/travelcatctl-source-digest.sh" "$PROJECT_ROOT")
ACTUAL_BINARY=$(/usr/bin/shasum -a 256 "$PINNED_BINARY" | /usr/bin/awk '{print $1}')
if [ "$ACTUAL_SOURCE" != "$EXPECTED_SOURCE" ]; then
    echo "release-verifier: CLI source inputs drifted" >&2
    exit 65
fi
if [ "$ACTUAL_BINARY" != "$EXPECTED_BINARY" ]; then
    echo "release-verifier: pinned release CLI hash mismatch" >&2
    exit 65
fi

/usr/bin/printf '%s\n' "$PINNED_BINARY"
