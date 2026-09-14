#!/bin/sh
set -eu

fail() {
    echo "travel-cat-installer: $1" >&2
    exit 65
}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)
SOURCE=${1:-"$PROJECT_ROOT/dist/Travel Cat.app"}
REPLACE_EXISTING=0
if [ "$#" -gt 2 ]; then
    echo "usage: install-travel-cat-app.sh [source-app] [--replace-existing]" >&2
    exit 64
fi
if [ "$#" -eq 2 ]; then
    [ "$2" = "--replace-existing" ] || {
        echo "travel-cat-installer: unsupported option" >&2
        exit 64
    }
    REPLACE_EXISTING=1
fi

[ -n "${HOME:-}" ] || fail "HOME is unavailable"
[ -d "$HOME" ] && [ ! -L "$HOME" ] || fail "HOME is missing or unsafe"
HOME_ROOT=$(CDPATH= cd -- "$HOME" && pwd -P)
DESTINATION="$HOME_ROOT/Applications/Travel Cat.app"
APPLICATIONS=$(dirname -- "$DESTINATION")
STAGING="$APPLICATIONS/.Travel Cat.app.staging.$$"

[ -d "$SOURCE" ] && [ ! -L "$SOURCE" ] || fail "source app is missing or unsafe"
SOURCE_PARENT=$(CDPATH= cd -- "$(dirname -- "$SOURCE")" && pwd -P)
SOURCE_APP="$SOURCE_PARENT/$(basename -- "$SOURCE")"
[ "$(basename -- "$SOURCE_APP")" = "Travel Cat.app" ] || fail "source app name is unexpected"
/usr/bin/codesign --verify --deep --strict "$SOURCE_APP" >/dev/null 2>&1 || fail "source app signature is invalid"
SOURCE_ID=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$SOURCE_APP/Contents/Info.plist" 2>/dev/null) ||
    fail "source bundle identifier is unreadable"
[ "$SOURCE_ID" = "com.nebulae.travelcat" ] || fail "source is not Travel Cat"

if [ -e "$APPLICATIONS" ] || [ -L "$APPLICATIONS" ]; then
    [ -d "$APPLICATIONS" ] && [ ! -L "$APPLICATIONS" ] || fail "Applications directory is unsafe"
else
    /bin/mkdir -m 755 "$APPLICATIONS"
fi
[ ! -e "$STAGING" ] && [ ! -L "$STAGING" ] || fail "staging path already exists"

cleanup() {
    if [ -e "$STAGING" ] || [ -L "$STAGING" ]; then
        /bin/rm -rf -- "$STAGING"
    fi
}
trap cleanup EXIT HUP INT TERM

/usr/bin/ditto --noqtn "$SOURCE_APP" "$STAGING"
[ -d "$STAGING" ] && [ ! -L "$STAGING" ] || fail "staged app is unsafe"
/usr/bin/codesign --verify --deep --strict "$STAGING" >/dev/null 2>&1 || fail "staged app signature is invalid"
STAGED_ID=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$STAGING/Contents/Info.plist" 2>/dev/null) ||
    fail "staged bundle identifier is unreadable"
[ "$STAGED_ID" = "com.nebulae.travelcat" ] || fail "staged app is not Travel Cat"

if [ -L "$DESTINATION" ]; then
    fail "destination must not be a symbolic link"
fi
if [ ! -e "$DESTINATION" ]; then
    /bin/mv "$STAGING" "$DESTINATION"
    trap - EXIT HUP INT TERM
    /bin/sync
    echo "$DESTINATION"
    exit 0
fi
[ -d "$DESTINATION" ] || fail "destination is not an app directory"
/usr/bin/codesign --verify --deep --strict "$DESTINATION" >/dev/null 2>&1 ||
    fail "existing destination signature is invalid"
EXISTING_ID=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$DESTINATION/Contents/Info.plist" 2>/dev/null) ||
    fail "existing bundle identifier is unreadable"
[ "$EXISTING_ID" = "com.nebulae.travelcat" ] || fail "existing destination is not Travel Cat"

if /usr/bin/diff -qr "$DESTINATION" "$STAGING" >/dev/null 2>&1; then
    cleanup
    trap - EXIT HUP INT TERM
    echo "$DESTINATION"
    exit 0
fi
[ "$REPLACE_EXISTING" -eq 1 ] || fail "a different Travel Cat app is already installed"

BACKUP="$APPLICATIONS/.Travel Cat.app.backup.$(/bin/date -u +%Y%m%dT%H%M%SZ).$$"
[ ! -e "$BACKUP" ] && [ ! -L "$BACKUP" ] || fail "backup path already exists"
/bin/mv "$DESTINATION" "$BACKUP"
if ! /bin/mv "$STAGING" "$DESTINATION"; then
    /bin/mv "$BACKUP" "$DESTINATION" || true
    fail "publication failed; the prior app was restored"
fi
trap - EXIT HUP INT TERM
/usr/bin/codesign --verify --deep --strict "$DESTINATION" >/dev/null 2>&1 || {
    /bin/mv "$DESTINATION" "$STAGING.failed.$$" || true
    /bin/mv "$BACKUP" "$DESTINATION" || true
    fail "published app failed verification; the prior app was restored"
}
/bin/sync
echo "$DESTINATION"
echo "travel-cat-installer: prior app preserved at $BACKUP" >&2
