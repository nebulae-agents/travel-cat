#!/bin/sh
set -eu

DATA_ROOT=
case "$#" in
    0) ;;
    2)
        [ "$1" = "--data-root" ] || {
            echo "package-app: usage: $0 [--data-root /absolute/path]" >&2
            exit 64
        }
        DATA_ROOT=$2
        TRIMMED_ROOT=$(printf '%s' "$DATA_ROOT" | /usr/bin/sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        [ "$DATA_ROOT" = "$TRIMMED_ROOT" ] || {
            echo "package-app: --data-root must not have surrounding whitespace" >&2
            exit 64
        }
        case "$DATA_ROOT" in
            /*) ;;
            *) echo "package-app: --data-root must be a non-empty absolute path" >&2; exit 64 ;;
        esac
        ;;
    *)
        echo "package-app: usage: $0 [--data-root /absolute/path]" >&2
        exit 64
        ;;
esac

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
DIST_DIR="$PROJECT_ROOT/dist"
APP="$DIST_DIR/Travel Cat.app"
STAGING="$DIST_DIR/.Travel Cat.app.staging.$$"
PLIST="$PROJECT_ROOT/packaging/Info.plist"
SWIFT_WRAPPER="$PROJECT_ROOT/Scripts/travel-cat-swift.sh"

swift_build() {
    if [ -n "${TRAVEL_CAT_PACKAGE_SDK:-}" ]; then
        "$SWIFT_WRAPPER" build --sdk "$TRAVEL_CAT_PACKAGE_SDK" "$@"
    else
        "$SWIFT_WRAPPER" build "$@"
    fi
}

if [ ! -f "$PROJECT_ROOT/Package.swift" ] || [ ! -f "$PLIST" ]; then
    echo "package-app: expected Travel Cat project files are missing" >&2
    exit 1
fi
case "$APP" in
    "$PROJECT_ROOT"/dist/Travel\ Cat.app) ;;
    *) echo "package-app: refusing unexpected app destination" >&2; exit 1 ;;
esac

# Packaging also refreshes the exact release CLI and provenance used by the
# standalone scheduled launcher. The executable remains an untracked build artifact.
"$PROJECT_ROOT/Scripts/build-scheduled-travelcatctl.sh"
PROVENANCE="$PROJECT_ROOT/Automation/provenance/travelcatctl-release.provenance"
SCRATCH_PATH=$("$SWIFT_WRAPPER" scratch-path)
PINNED_ROOT="$SCRATCH_PATH/travelcatctl-pinned"
ARTIFACT_ID=$(/usr/bin/sed -n '6s/^binaryArtifactID=//p' "$PROVENANCE")
case "$ARTIFACT_ID" in
    [0-9a-f][0-9a-f]*/travelcatctl) ;;
    *) echo "package-app: scheduled CLI provenance has an unsafe binaryArtifactID=" >&2; exit 1 ;;
esac
PINNED_CLI=$("$PROJECT_ROOT/Scripts/verify-travelcatctl-release.sh" "$PROVENANCE" "$PROJECT_ROOT" "$PINNED_ROOT")
BUNDLED_LAUNCHER="$PROJECT_ROOT/Scripts/run-bundled-travelcatctl.sh"

swift_build --disable-sandbox -c release --product TravelCatApp
BIN_DIR=$(swift_build --disable-sandbox -c release --show-bin-path)
if [ ! -d "$BIN_DIR" ] || [ -L "$BIN_DIR" ]; then
    echo "package-app: release bin directory is missing or unsafe" >&2
    exit 1
fi
BIN_DIR=$(CDPATH= cd -- "$BIN_DIR" && pwd -P)
case "$BIN_DIR/" in
    "$SCRATCH_PATH"/*) ;;
    *) echo "package-app: release bin directory escaped external scratch" >&2; exit 1 ;;
esac
EXECUTABLE="$BIN_DIR/TravelCatApp"
RESOURCE_BUNDLE="$BIN_DIR/TravelCat_TravelUI.bundle"
GENERATION_BUNDLE="$BIN_DIR/TravelCat_TravelCatApp.bundle"
bundle_resources() {
    if [ -d "$1/Contents/Resources" ]; then
        printf '%s/Contents/Resources\n' "$1"
    else
        printf '%s\n' "$1"
    fi
}
RESOURCE_FILES=$(bundle_resources "$RESOURCE_BUNDLE")
GENERATION_FILES=$(bundle_resources "$GENERATION_BUNDLE")
for mailbox_asset in pet-mailbox.png; do
    test -f "$RESOURCE_FILES/$mailbox_asset" || {
        echo "package-app: missing mailbox resource: $mailbox_asset" >&2
        exit 1
    }
done
for agent_asset in sidecar.py container_relay.py audit_runtime.py audit_payload.py workspace_io.py runtime_discovery.py codex_native.py codex_native_transport.py; do
    test -f "$GENERATION_FILES/AgentRuntime/$agent_asset" || {
        echo "package-app: missing agent resource: $agent_asset" >&2
        exit 1
    }
done
for generation_asset in narrative.schema.json image.schema.json front.png side.png sitting.png identity.json; do
    test -f "$GENERATION_FILES/Generation/$generation_asset" || {
        echo "package-app: missing generation resource: $generation_asset" >&2
        exit 1
    }
done
if [ ! -x "$EXECUTABLE" ] || [ ! -d "$RESOURCE_BUNDLE" ] || [ ! -f "$RESOURCE_FILES/cute-black-cat-spritesheet.webp" ] ||
    [ ! -x "$PINNED_CLI" ] || [ -L "$PINNED_CLI" ] || [ ! -x "$BUNDLED_LAUNCHER" ] || [ -L "$BUNDLED_LAUNCHER" ]; then
    echo "package-app: release executable or TravelUI resources are missing" >&2
    exit 1
fi
for preview_asset in \
    preview-kamakura-coast.png \
    preview-kyoto-lanterns.png \
    preview-dali-lake.png \
    preview-iceland-aurora.png \
    preview-hangzhou-garden.png \
    preview-paris-dusk.png; do
    test -f "$RESOURCE_FILES/$preview_asset" || {
        echo "package-app: missing preview postcard asset: $preview_asset" >&2
        exit 1
    }
done
for cat_asset in \
    preview-cat-front.png \
    preview-cat-side.png \
    preview-cat-sitting.png; do
    test -f "$RESOURCE_FILES/$cat_asset" || {
        echo "package-app: missing preview cat asset: $cat_asset" >&2
        exit 1
    }
done
plutil -lint "$PLIST" >/dev/null

cleanup() { rm -rf -- "$STAGING"; }
trap cleanup EXIT HUP INT TERM
mkdir -p "$DIST_DIR"
rm -rf -- "$STAGING"
mkdir -p "$STAGING/Contents/MacOS" "$STAGING/Contents/Helpers" "$STAGING/Contents/Resources"
install -m 755 "$EXECUTABLE" "$STAGING/Contents/MacOS/TravelCatApp"
install -m 555 "$BUNDLED_LAUNCHER" "$STAGING/Contents/Resources/run-travelcatctl"
install -m 555 "$PINNED_CLI" "$STAGING/Contents/Helpers/travelcatctl"
install -m 444 "$PROVENANCE" "$STAGING/Contents/Resources/travelcatctl-release.provenance"
install -m 644 "$PLIST" "$STAGING/Contents/Info.plist"
/usr/bin/plutil -insert TravelCatBuildTimestamp -string "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" "$STAGING/Contents/Info.plist"
if [ -n "$DATA_ROOT" ]; then
    /usr/bin/plutil -insert TravelCatDataRoot -string "$DATA_ROOT" "$STAGING/Contents/Info.plist"
fi
cp -R "$RESOURCE_BUNDLE" "$STAGING/Contents/Resources/TravelCat_TravelUI.bundle"
cp -R "$GENERATION_BUNDLE" "$STAGING/Contents/Resources/TravelCat_TravelCatApp.bundle"
STAGED_RESOURCE_FILES=$(bundle_resources "$STAGING/Contents/Resources/TravelCat_TravelUI.bundle")
STAGED_GENERATION_FILES=$(bundle_resources "$STAGING/Contents/Resources/TravelCat_TravelCatApp.bundle")
# Python import caches are generated state and can change after signing.
# Keep only source resources inside the sealed app.
find "$STAGED_GENERATION_FILES/AgentRuntime" -type f -name "*.pyc" -delete
find "$STAGED_GENERATION_FILES/AgentRuntime" -type d -name __pycache__ -empty -delete

test -x "$STAGING/Contents/MacOS/TravelCatApp"
test -x "$STAGING/Contents/Resources/run-travelcatctl"
test -x "$STAGING/Contents/Helpers/travelcatctl"
test -f "$STAGING/Contents/Resources/travelcatctl-release.provenance"
test -f "$STAGING/Contents/Info.plist"
test -f "$STAGED_RESOURCE_FILES/cute-black-cat-spritesheet.webp"
test -f "$STAGED_RESOURCE_FILES/pet-mailbox.png"
for agent_asset in sidecar.py container_relay.py audit_runtime.py audit_payload.py workspace_io.py runtime_discovery.py codex_native.py codex_native_transport.py; do
    test -f "$STAGED_GENERATION_FILES/AgentRuntime/$agent_asset"
done
for preview_asset in \
    preview-kamakura-coast.png \
    preview-kyoto-lanterns.png \
    preview-dali-lake.png \
    preview-iceland-aurora.png \
    preview-hangzhou-garden.png \
    preview-paris-dusk.png; do
    test -f "$STAGED_RESOURCE_FILES/$preview_asset" || {
        echo "package-app: staged preview postcard asset is missing: $preview_asset" >&2
        exit 1
    }
done
for cat_asset in \
    preview-cat-front.png \
    preview-cat-side.png \
    preview-cat-sitting.png; do
    test -f "$STAGED_RESOURCE_FILES/$cat_asset" || {
        echo "package-app: staged preview cat asset is missing: $cat_asset" >&2
        exit 1
    }
done
codesign --force --sign - "$STAGING"
codesign --verify --deep --strict "$STAGING"

rm -rf -- "$APP"
mv "$STAGING" "$APP"
trap - EXIT HUP INT TERM
codesign --verify --deep --strict "$APP"
# dist is temporary packaging output. After installation verification it must
# be removed so the repository upload audit returns to a clean state.
echo "$APP"
