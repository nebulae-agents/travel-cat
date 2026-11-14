#!/bin/sh
# Build-only downloads and dependencies stay in the existing private external cache.
set -eu
umask 077
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)
SOURCE="$PROJECT_ROOT/Runtime/PiAgent"
SCRATCH=$("$PROJECT_ROOT/Scripts/travel-cat-swift.sh" scratch-path)
CACHE="$SCRATCH/pi-agent"
[ ! -L "$CACHE" ] || { echo 'build-pi-runtime: unsafe cache' >&2; exit 1; }
mkdir -p "$CACHE"
[ "$(stat -f '%u' "$CACHE")" = "$(id -u)" ] || { echo 'build-pi-runtime: cache owner mismatch' >&2; exit 1; }
MODE=$(stat -f '%Lp' "$CACHE")
[ "$((0$MODE & 022))" = 0 ] || { echo 'build-pi-runtime: writable cache' >&2; exit 1; }
case "$(uname -m)" in
    arm64) ARCH=arm64; NODE_SHA=f8655beb4b86ff6588ed7e02c37f8574b58557bd3e880012814b1a4956fd9d88 ;;
    x86_64) ARCH=x64; NODE_SHA=b6a384bba1a7ec585e5a91a452b63f676b940584ff57b5c9cf0541c8db60023e ;;
    *) echo 'build-pi-runtime: unsupported architecture' >&2; exit 1 ;;
esac
NODE_VERSION=22.22.2
ARCHIVE="$CACHE/node-v$NODE_VERSION-darwin-$ARCH.tar.xz"
BUILD=$(mktemp -d "$CACHE/build.XXXXXXXX")
cleanup() { rm -rf -- "$BUILD"; }
trap cleanup EXIT HUP INT TERM
verify_sha() { [ "$(shasum -a 256 "$1" | awk '{print $1}')" = "$2" ]; }
[ ! -L "$ARCHIVE" ] || { echo 'build-pi-runtime: unsafe archive' >&2; exit 1; }
if [ ! -f "$ARCHIVE" ] || ! verify_sha "$ARCHIVE" "$NODE_SHA"; then
    curl --http1.1 --retry 2 --retry-delay 2 --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --connect-timeout 20 --max-time 600 \
        "https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-darwin-$ARCH.tar.xz" -o "$BUILD/node.tar.xz"
    verify_sha "$BUILD/node.tar.xz" "$NODE_SHA" || { echo 'build-pi-runtime: Node checksum mismatch' >&2; exit 1; }
    mv "$BUILD/node.tar.xz" "$ARCHIVE"
fi
mkdir "$BUILD/node"
tar -xf "$ARCHIVE" --strip-components=1 -C "$BUILD/node"
NODE="$BUILD/node/bin/node"
[ "$("$NODE" --version)" = "v$NODE_VERSION" ] || exit 1
/usr/bin/otool -L "$NODE" | /usr/bin/tail -n +2 | /usr/bin/awk '$1 !~ /^\/(usr\/lib|System\/Library)\// { bad=1 } END { exit bad }'
ARTIFACT="$BUILD/artifact"
RESOURCES="$ARTIFACT/Resources/PiAgent"
mkdir -p "$ARTIFACT/Helpers/PiAgent" "$RESOURCES" "$BUILD/npm-home"
install -m 755 "$NODE" "$ARTIFACT/Helpers/PiAgent/node"
cp "$SOURCE/package.json" "$SOURCE/package-lock.json" "$SOURCE/runner.mjs" "$RESOURCES/"
touch "$BUILD/npm-user.conf" "$BUILD/npm-global.conf"
# Use the pinned Node/npm pair, no user npm config, install hooks, or authentication.
env -i PATH="$BUILD/node/bin:/usr/bin:/bin" HOME="$BUILD/npm-home" \
    "$NODE" "$BUILD/node/lib/node_modules/npm/bin/npm-cli.js" ci --prefix "$RESOURCES" \
    --cache "$CACHE/npm-cache" --userconfig "$BUILD/npm-user.conf" --globalconfig "$BUILD/npm-global.conf" --registry https://registry.npmjs.org \
    --ignore-scripts --omit=dev --no-audit --no-fund >&2
mkdir "$RESOURCES/Licenses"
cp "$BUILD/node/LICENSE" "$RESOURCES/Licenses/Node-LICENSE.txt"
curl --http1.1 --retry 2 --retry-delay 2 --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --connect-timeout 20 --max-time 60 \
    https://raw.githubusercontent.com/earendil-works/pi/v1.5.0/LICENSE -o "$RESOURCES/Licenses/Pi-LICENSE.txt"
verify_sha "$RESOURCES/Licenses/Pi-LICENSE.txt" 0457f5bcec3b3b211605dfb5d1a49042fd638f3686a410fe099c24a25af13c48 || {
    echo 'build-pi-runtime: Pi license checksum mismatch' >&2; exit 1;
}
# Retain the dependency distributions and their original license files. Inventory all licenses.
"$NODE" --input-type=module - "$RESOURCES" <<'JS'
import fs from 'node:fs';
import path from 'node:path';
const root = process.argv[2];
const lock = JSON.parse(fs.readFileSync(path.join(root, 'package-lock.json')));
const lines = ['Pi runtime dependency notices', '', 'Pi packages: see Pi-LICENSE.txt. Node: see Node-LICENSE.txt.', 'Other dependency license files are preserved under node_modules.', ''];
for (const [location, pkg] of Object.entries(lock.packages)) {
  if (location) lines.push(`${location}: ${pkg.version} — ${pkg.license ?? 'See package distribution'}`);
}
fs.writeFileSync(path.join(root, 'Licenses', 'DEPENDENCIES.txt'), lines.join('\n') + '\n');
JS
# Exercise the shipped entry point without touching any model service.
RESULT=$(printf '%s' '{"version":0}' | env -i "$ARTIFACT/Helpers/PiAgent/node" "$RESOURCES/runner.mjs")
[ "$RESULT" = '{"version":1,"ok":false,"code":"invalid_request"}' ] || { echo 'build-pi-runtime: protocol smoke test failed' >&2; exit 1; }
# The cache remains private; copied app resources must be readable by app users.
chmod -R a+rX "$ARTIFACT"
rm -rf -- "$BUILD/node" "$BUILD/npm-home" "$BUILD/npm-user.conf" "$BUILD/npm-global.conf"
trap - EXIT HUP INT TERM
printf '%s\n' "$ARTIFACT"
