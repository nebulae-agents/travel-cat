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
# Use a process-lifetime lock: even SIGKILL or a restart releases it. Perl is
# already required by the system shasum above. Keep the descriptor across exec.
LOCK="$PINNED_ROOT/.publish-lock.$BINARY_SHA"
exec /usr/bin/perl -MFcntl=:DEFAULT,:flock -e '
    my ($path, @command) = @ARGV;
    sysopen(my $lock, $path, O_CREAT | O_RDWR | O_NOFOLLOW, 0600)
        or die "pinned-publisher: cannot open publication lock\n";
    if (!flock($lock, LOCK_EX | LOCK_NB)) {
        print STDERR "pinned-publisher: publication is busy; retry later\n";
        exit 75;
    }
    fcntl($lock, F_SETFD, 0) or die "pinned-publisher: cannot retain lock\n";
    exec @command;
    die "pinned-publisher: cannot start publisher\n";
' "$LOCK" /bin/sh -s -- "$CANONICAL" "$PINNED_ROOT" "$BINARY_SHA" <<'LOCKED_PUBLISH'
set -eu
CANONICAL=$1
PINNED_ROOT=$2
BINARY_SHA=$3
PINNED_DIR="$PINNED_ROOT/$BINARY_SHA"
PINNED_BINARY="$PINNED_DIR/travelcatctl"
STAGING=""
STAGING_ID=""
cleanup() {
    if [ -n "$STAGING" ] && [ -d "$STAGING" ] && [ ! -L "$STAGING" ]; then
        /bin/chmod 0700 "$STAGING"
        /bin/rm -rf -- "$STAGING"
    elif [ -n "$STAGING_ID" ] && [ ! -L "$PINNED_DIR" ] &&
        [ "$(/usr/bin/stat -f '%d:%i' "$PINNED_DIR" 2>/dev/null)" = "$STAGING_ID" ]; then
        # A signal can arrive after rename but before sealing. Only repair the
        # directory this invocation created, never a preexisting artifact.
        /bin/chmod 0555 "$PINNED_DIR"
    fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
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
    /bin/mkdir -m 0700 -- "$STAGING"
    STAGING_ID=$(/usr/bin/stat -f '%d:%i' "$STAGING")
    /usr/bin/install -m 0555 "$CANONICAL" "$STAGING/travelcatctl"
    STAGED_SHA=$(/usr/bin/shasum -a 256 "$STAGING/travelcatctl" | /usr/bin/awk '{print $1}')
    if [ "$STAGED_SHA" != "$BINARY_SHA" ]; then
        echo "pinned-publisher: staged artifact hash mismatch" >&2
        exit 65
    fi
    # macOS 15 requires a writable source directory for this rename. Keep it
    # private until moved, then seal it before releasing the lock or returning.
    /bin/mv -n -- "$STAGING" "$PINNED_DIR"
    if [ -e "$STAGING" ]; then
        echo "pinned-publisher: destination changed during publication" >&2
        exit 65
    fi
    /bin/chmod 0555 "$PINNED_DIR"
    STAGING=""
    STAGING_ID=""
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
LOCKED_PUBLISH
