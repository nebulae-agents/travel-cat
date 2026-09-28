#!/bin/sh
set -eu
SCRIPT_DIRECTORY=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
PROJECT_DIRECTORY=$(CDPATH= cd -- "$SCRIPT_DIRECTORY/.." && pwd -P)
APP="$PROJECT_DIRECTORY/dist/Travel Cat.app"
[ -d "$APP" ] || { echo '请先运行 scripts/package-app.sh' >&2; exit 65; }
/usr/bin/codesign --verify --deep --strict "$APP"
VERSION=$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")
ARCHITECTURE=$(/usr/bin/uname -m)
OUTPUT=${1:-"${TMPDIR:-/tmp}/TravelCat-$VERSION-$ARCHITECTURE.zip"}
case "$OUTPUT" in /*.zip) ;; *) echo '输出必须为绝对 .zip 路径' >&2; exit 64;; esac
[ ! -e "$OUTPUT" ] || { echo '输出文件已存在，拒绝覆盖' >&2; exit 65; }
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/travelcat-distribution.XXXXXX")
trap 'rm -rf -- "$STAGING"' EXIT HUP INT TERM
PACKAGE="$STAGING/TravelCat-$VERSION"
mkdir "$PACKAGE"
/usr/bin/ditto "$APP" "$PACKAGE/Travel Cat.app"
install -m 755 "$PROJECT_DIRECTORY/packaging/Install.command" "$PACKAGE/Install.command"
install -m 755 "$SCRIPT_DIRECTORY/install-travel-cat-app.sh" "$PACKAGE/install-travel-cat-app.sh"
install -m 644 "$PROJECT_DIRECTORY/packaging/READ-ME.txt" "$PACKAGE/READ-ME.txt"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$PACKAGE" "$OUTPUT"
printf '%s\n' "$OUTPUT"
