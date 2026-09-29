#!/bin/sh
set -eu
PACKAGE_DIRECTORY=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
# Quit only the installed Travel Cat application before replacing its executable.
/usr/bin/osascript -e 'if application id "com.nebulae.travelcat" is running then tell application id "com.nebulae.travelcat" to quit' >/dev/null 2>&1 || true
"$PACKAGE_DIRECTORY/install-travel-cat-app.sh" "$PACKAGE_DIRECTORY/Travel Cat.app" --replace-existing
/usr/bin/open "$HOME/Applications/Travel Cat.app"
printf '%s\n' 'Travel Cat 已安装并打开。请从“模型与连接”完成首次配置。历史相册会保留。'
