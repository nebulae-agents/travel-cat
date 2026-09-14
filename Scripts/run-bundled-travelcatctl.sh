#!/bin/sh
set -eu

fail() {
    echo "bundled-launcher: $1" >&2
    exit 65
}

if [ "$#" -ne 1 ]; then
    echo "bundled-launcher: expected exactly one fixed CLI command" >&2
    exit 64
fi
COMMAND=$1
case "$COMMAND" in
    status|journal|pending-images|claim|validate-candidate|publish|mark-image|prepare-postcard|character|configure-character|install-default-pet) ;;
    *) echo "bundled-launcher: command is not allowlisted" >&2; exit 64 ;;
esac

SELF=$0
[ ! -L "$SELF" ] || fail "launcher must not be a symbolic link"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$SELF")" && pwd -P)
CONTENTS_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)
APP_ROOT=$(CDPATH= cd -- "$CONTENTS_DIR/.." && pwd -P)
PINNED_BINARY="$APP_ROOT/Contents/Helpers/travelcatctl"
PROVENANCE="$APP_ROOT/Contents/Resources/travelcatctl-release.provenance"
PLIST="$CONTENTS_DIR/Info.plist"

SELF_NAME=${SELF##*/}
[ "$SELF_NAME" = "run-travelcatctl" ] || fail "launcher path is not canonical"
[ -f "$SCRIPT_DIR/$SELF_NAME" ] || fail "launcher path is not canonical"
[ -f "$PLIST" ] && [ ! -L "$PLIST" ] || fail "Info.plist is missing or unsafe"
[ -f "$PINNED_BINARY" ] && [ ! -L "$PINNED_BINARY" ] && [ -x "$PINNED_BINARY" ] || fail "helper is missing or unsafe"
[ -f "$PROVENANCE" ] && [ ! -L "$PROVENANCE" ] || fail "provenance is missing or unsafe"
[ "$(/usr/bin/stat -f '%Lp' "$PINNED_BINARY")" = "555" ] || fail "helper permissions are unsafe"

/usr/bin/codesign --verify --deep --strict "$APP_ROOT" >/dev/null 2>&1 || fail "app signature is invalid"
BUNDLE_ID=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$PLIST" 2>/dev/null) || fail "bundle identifier is unreadable"
[ "$BUNDLE_ID" = "com.nebulae.travelcat" ] || fail "bundle identifier is unexpected"

[ "$(/usr/bin/wc -l < "$PROVENANCE" | /usr/bin/tr -d ' ')" = "6" ] || fail "provenance line count is invalid"
FORMAT=$(/usr/bin/sed -n '1p' "$PROVENANCE")
PRODUCT=$(/usr/bin/sed -n '2p' "$PROVENANCE")
CONFIGURATION=$(/usr/bin/sed -n '3p' "$PROVENANCE")
SOURCE_LINE=$(/usr/bin/sed -n '4p' "$PROVENANCE")
BINARY_LINE=$(/usr/bin/sed -n '5p' "$PROVENANCE")
ARTIFACT_LINE=$(/usr/bin/sed -n '6p' "$PROVENANCE")
[ "$FORMAT" = "format=travel-cat-cli-provenance-v3" ] || fail "provenance format is invalid"
[ "$PRODUCT" = "product=travelcatctl" ] || fail "provenance product is invalid"
[ "$CONFIGURATION" = "configuration=release" ] || fail "provenance configuration is invalid"
case "$SOURCE_LINE" in sourceTreeSHA256=????????????????????????????????????????????????????????????????) ;; *) fail "source digest is invalid" ;; esac
case "$BINARY_LINE" in binarySHA256=????????????????????????????????????????????????????????????????) ;; *) fail "binary digest is invalid" ;; esac
EXPECTED_SOURCE=${SOURCE_LINE#sourceTreeSHA256=}
EXPECTED_SHA=${BINARY_LINE#binarySHA256=}
for DIGEST in "$EXPECTED_SOURCE" "$EXPECTED_SHA"; do
    case "$DIGEST" in *[!0-9a-f]*) fail "provenance digest is invalid" ;; esac
done
EXPECTED_ARTIFACT_ID="$EXPECTED_SHA/travelcatctl"
[ "$ARTIFACT_LINE" = "binaryArtifactID=$EXPECTED_ARTIFACT_ID" ] || fail "artifact ID does not match binary digest"
ACTUAL_SHA=$(/usr/bin/shasum -a 256 "$PINNED_BINARY" | /usr/bin/awk '{print $1}')
[ "$ACTUAL_SHA" = "$EXPECTED_SHA" ] || fail "helper digest does not match provenance"

BUNDLED_RESOURCES_ROOT="$APP_ROOT/Contents/Resources/TravelCat_TravelUI.bundle"

if [ "$COMMAND" = "install-default-pet" ]; then
    if [ "${CODEX_HOME+x}" = x ]; then
        CODEX_ROOT=$CODEX_HOME
        TRIMMED_CODEX_ROOT=$(printf '%s' "$CODEX_ROOT" | /usr/bin/sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        [ "$CODEX_ROOT" = "$TRIMMED_CODEX_ROOT" ] || fail "CODEX_HOME must not have surrounding whitespace"
        case "$CODEX_ROOT" in /*) ;; *) fail "CODEX_HOME must be a non-empty absolute path" ;; esac
    else
        PORTABLE_HOME=${HOME-}
        case "$PORTABLE_HOME" in /*) ;; *) fail "HOME must be a non-empty absolute path" ;; esac
        CODEX_ROOT="$PORTABLE_HOME/.codex"
    fi
    exec /usr/bin/env -i \
        PATH=/usr/bin:/bin \
        LANG=en_US.UTF-8 \
        TRAVEL_CAT_DEFAULT_PET_RESOURCES_ROOT="$BUNDLED_RESOURCES_ROOT" \
        TRAVEL_CAT_DEFAULT_PETS_ROOT="$CODEX_ROOT/pets" \
        "$PINNED_BINARY" "$COMMAND"
fi

if /usr/bin/plutil -extract TravelCatDataRoot xml1 -o /dev/null "$PLIST" 2>/dev/null; then
    DATA_ROOT=$(/usr/bin/plutil -extract TravelCatDataRoot raw -expect string -o - "$PLIST" 2>/dev/null) ||
        fail "TravelCatDataRoot is not a string"
    TRIMMED_ROOT=$(printf '%s' "$DATA_ROOT" | /usr/bin/sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [ "$DATA_ROOT" = "$TRIMMED_ROOT" ] || fail "TravelCatDataRoot must not have surrounding whitespace"
    case "$DATA_ROOT" in
        /*) ;;
        *) fail "TravelCatDataRoot must be a non-empty absolute path" ;;
    esac
else
    PORTABLE_HOME=${HOME-}
    case "$PORTABLE_HOME" in
        /*) ;;
        *) fail "HOME must be a non-empty absolute path when TravelCatDataRoot is absent" ;;
    esac
    DATA_ROOT="$PORTABLE_HOME/Library/Application Support/TravelCat/TravelPetData"
fi

exec /usr/bin/env -i \
    PATH=/usr/bin:/bin \
    LANG=en_US.UTF-8 \
    TRAVEL_CAT_DATA="$DATA_ROOT" \
    TRAVEL_CAT_BUNDLED_RESOURCES_ROOT="$BUNDLED_RESOURCES_ROOT" \
    "$PINNED_BINARY" "$COMMAND"
