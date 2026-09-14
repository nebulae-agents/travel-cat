#!/bin/zsh

set -eu

script_dir="$(cd -- "$(dirname -- "$0")" && pwd -P)"
if ! command -v python3 >/dev/null 2>&1; then
    print -u2 -r -- "Publish to GitHub requires Python 3."
    exit 69
fi
exec python3 "$script_dir/Scripts/publish_github.py" --repository "$script_dir" "$@"
