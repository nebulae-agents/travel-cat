#!/bin/sh
set -eu

fail() { echo "default-pet-installer: $1" >&2; exit 65; }

SELF=$0
[ ! -L "$SELF" ] || fail "installer entry must not be a symbolic link"
ENTRY_DIR_LOGICAL=$(CDPATH= cd -- "$(dirname -- "$SELF")" && pwd -L)
ENTRY_DIR=$(CDPATH= cd -- "$(dirname -- "$SELF")" && pwd -P)
[ "$ENTRY_DIR_LOGICAL" = "$ENTRY_DIR" ] || fail "installer entry ancestry must not contain symbolic links"
APP="$ENTRY_DIR/Travel Cat.app"
LAUNCHER="$APP/Contents/Resources/run-travelcatctl"
PLIST="$APP/Contents/Info.plist"

CHECK=$ENTRY_DIR
while [ "$CHECK" != / ]; do
    [ "$(/usr/bin/stat -f '%HT' "$CHECK")" != "Symbolic Link" ] || fail "installer entry ancestry is unsafe"
    CHECK=${CHECK%/*}
    [ -n "$CHECK" ] || CHECK=/
done
[ -d "$APP" ] && [ ! -L "$APP" ] || fail "adjacent Travel Cat.app is missing or unsafe"
[ -d "$APP/Contents" ] && [ ! -L "$APP/Contents" ] || fail "Contents is missing or unsafe"
[ -d "$APP/Contents/Resources" ] && [ ! -L "$APP/Contents/Resources" ] || fail "Resources is missing or unsafe"
[ -f "$PLIST" ] && [ ! -L "$PLIST" ] || fail "Info.plist is missing or unsafe"
[ -f "$LAUNCHER" ] && [ -x "$LAUNCHER" ] && [ ! -L "$LAUNCHER" ] || fail "signed launcher is missing or unsafe"
/usr/bin/codesign --verify --deep --strict "$APP" >/dev/null 2>&1 || fail "app signature is invalid"
BUNDLE_ID=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$PLIST" 2>/dev/null) || fail "bundle identifier is unreadable"
[ "$BUNDLE_ID" = "com.nebulae.travelcat" ] || fail "bundle identifier is unexpected"

exec "$LAUNCHER" install-default-pet
