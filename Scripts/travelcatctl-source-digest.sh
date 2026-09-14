#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "source-digest: expected one absolute project root" >&2
    exit 64
fi

PROJECT_ROOT=$1
case "$PROJECT_ROOT" in
    /*) ;;
    *) echo "source-digest: project root must be absolute" >&2; exit 64 ;;
esac
if [ ! -d "$PROJECT_ROOT" ] || [ -L "$PROJECT_ROOT" ]; then
    echo "source-digest: project root is missing or unsafe" >&2
    exit 65
fi
for INPUT in Package.swift Sources/TravelCore Sources/TravelStorage Sources/TravelCatCLI; do
    if [ ! -e "$PROJECT_ROOT/$INPUT" ] || [ -L "$PROJECT_ROOT/$INPUT" ]; then
        echo "source-digest: required input is missing or unsafe" >&2
        exit 65
    fi
done

MANIFEST=$(/usr/bin/mktemp -t travel-cat-source-digest)
cleanup() { /bin/rm -f -- "$MANIFEST"; }
trap cleanup EXIT HUP INT TERM

(
    cd "$PROJECT_ROOT"
    LC_ALL=C /usr/bin/find -P Package.swift Sources/TravelCore Sources/TravelStorage Sources/TravelCatCLI -type f -print |
        LC_ALL=C /usr/bin/sort |
        while IFS= read -r FILE; do
            if [ -L "$FILE" ]; then
                echo "source-digest: symlinked source input" >&2
                exit 65
            fi
            HASH=$(/usr/bin/shasum -a 256 "$FILE" | /usr/bin/awk '{print $1}')
            /usr/bin/printf '%s  %s\n' "$HASH" "$FILE"
        done
) >"$MANIFEST"

if [ ! -s "$MANIFEST" ]; then
    echo "source-digest: source input set is empty" >&2
    exit 65
fi
/usr/bin/shasum -a 256 "$MANIFEST" | /usr/bin/awk '{print $1}'
