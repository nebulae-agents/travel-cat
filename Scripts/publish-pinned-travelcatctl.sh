#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
    echo "pinned-publisher: expected canonical binary and pinned root" >&2
    exit 64
fi
CANONICAL=$1
PINNED_ROOT=$2
case "$CANONICAL:$PINNED_ROOT" in
    /*:/*) ;;
    *) echo "pinned-publisher: all paths must be absolute" >&2; exit 64 ;;
esac
if [ ! -f "$CANONICAL" ] || [ -L "$CANONICAL" ] || [ ! -x "$CANONICAL" ]; then
    echo "pinned-publisher: canonical release CLI is missing or unsafe" >&2
    exit 65
fi
if [ -L "$PINNED_ROOT" ] || { [ -e "$PINNED_ROOT" ] && [ ! -d "$PINNED_ROOT" ]; }; then
    echo "pinned-publisher: pinned artifact root is unsafe" >&2
    exit 65
fi
/bin/mkdir -p -- "$PINNED_ROOT"

BINARY_SHA=$(/usr/bin/shasum -a 256 "$CANONICAL" | /usr/bin/awk '{print $1}')
PINNED_DIR="$PINNED_ROOT/$BINARY_SHA"
PINNED_BINARY="$PINNED_DIR/travelcatctl"
if [ -e "$PINNED_DIR" ] || [ -L "$PINNED_DIR" ]; then
    if [ ! -d "$PINNED_DIR" ] || [ -L "$PINNED_DIR" ] ||
        [ ! -f "$PINNED_BINARY" ] || [ -L "$PINNED_BINARY" ] || [ ! -x "$PINNED_BINARY" ]; then
        echo "pinned-publisher: existing pinned artifact is unsafe" >&2
        exit 65
    fi
    EXISTING_SHA=$(/usr/bin/shasum -a 256 "$PINNED_BINARY" | /usr/bin/awk '{print $1}')
    if [ "$EXISTING_SHA" != "$BINARY_SHA" ] ||
        [ "$(/usr/bin/stat -f '%Lp' "$PINNED_BINARY")" != 555 ] ||
        [ "$(/usr/bin/stat -f '%Lp' "$PINNED_DIR")" != 555 ]; then
        echo "pinned-publisher: existing pinned artifact does not match immutable bytes" >&2
        exit 65
    fi
else
    STAGING="$PINNED_ROOT/.staging.$BINARY_SHA.$$"
    cleanup() { /bin/rm -rf -- "$STAGING"; }
    trap cleanup EXIT HUP INT TERM
    /bin/mkdir -m 0700 -- "$STAGING"
    /usr/bin/install -m 0555 "$CANONICAL" "$STAGING/travelcatctl"
    STAGED_SHA=$(/usr/bin/shasum -a 256 "$STAGING/travelcatctl" | /usr/bin/awk '{print $1}')
    if [ "$STAGED_SHA" != "$BINARY_SHA" ]; then
        echo "pinned-publisher: staged artifact hash mismatch" >&2
        exit 65
    fi
    /bin/chmod 0555 "$STAGING"
    /bin/mv -n -- "$STAGING" "$PINNED_DIR"
    cleanup
    trap - EXIT HUP INT TERM
    if [ ! -f "$PINNED_BINARY" ] || [ -L "$PINNED_BINARY" ]; then
        echo "pinned-publisher: immutable artifact publication failed" >&2
        exit 65
    fi
fi

# Recheck the final name even after atomic publication. This also catches a
# concurrent creator that won the content-addressed directory name.
FINAL_SHA=$(/usr/bin/shasum -a 256 "$PINNED_BINARY" | /usr/bin/awk '{print $1}')
if [ "$FINAL_SHA" != "$BINARY_SHA" ] ||
    [ "$(/usr/bin/stat -f '%Lp' "$PINNED_BINARY")" != 555 ] ||
    [ "$(/usr/bin/stat -f '%Lp' "$PINNED_DIR")" != 555 ]; then
    echo "pinned-publisher: published artifact does not match immutable bytes" >&2
    exit 65
fi

/usr/bin/printf '%s\n' "$PINNED_BINARY"
