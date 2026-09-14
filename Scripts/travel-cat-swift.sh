#!/bin/zsh

set -euo pipefail

usage_error() {
    print -u2 -r -- "travel-cat-swift: expected one of: test, build, run, scratch-path"
    print -u2 -r -- "usage: travel-cat-swift.sh run <executable> [program arguments...]"
    print -u2 -r -- "usage: travel-cat-swift.sh scratch-path"
    exit 64
}

run_usage_error() {
    print -u2 -r -- "travel-cat-swift: run requires a non-empty executable that does not begin with '-'"
    print -u2 -r -- "usage: travel-cat-swift.sh run <executable> [program arguments...]"
    print -u2 -r -- "travel-cat-swift: run supports only the default configuration; build release first, then execute the build artifact directly"
    exit 64
}

(( $# > 0 )) || usage_error
subcommand="$1"
shift

case "$subcommand" in
    test|build|run|scratch-path) ;;
    *) usage_error ;;
esac

forwarded_arguments=("$@")
if [[ "$subcommand" == "scratch-path" ]]; then
    (( $# == 0 )) || usage_error
elif [[ "$subcommand" == "run" ]]; then
    (( $# > 0 )) || run_usage_error
    [[ -n "$1" && "$1" != -* ]] || run_usage_error
else
    for argument in "$@"; do
        case "$argument" in
            --scratch-path|--scratch-path=*)
                print -u2 -r -- "travel-cat-swift: caller-provided --scratch-path is not allowed"
                exit 64
                ;;
        esac
    done
fi

script_dir="$(cd -- "$(dirname -- "$0")" && pwd -P)"
project_root="$(cd -- "$script_dir/.." && pwd -P)"
cache_id="$(print -rn -- "$project_root" | shasum -a 256 | cut -c 1-16)"

scratch_root="${TRAVEL_CAT_SCRATCH_ROOT:-${TMPDIR:-/tmp}/travel-cat-swiftpm}"
scratch_root="${scratch_root:A}"
if [[ "$scratch_root" == "$project_root" || "$scratch_root" == "$project_root"/* ]]; then
    print -u2 -r -- "travel-cat-swift: scratch root must be outside the project: $scratch_root"
    exit 73
fi
if ! (umask 077; mkdir -p "$scratch_root"); then
    print -u2 -r -- "travel-cat-swift: could not create scratch root: $scratch_root"
    exit 73
fi
scratch_root="$(cd -- "$scratch_root" && pwd -P)"
if [[ "$scratch_root" == "$project_root" || "$scratch_root" == "$project_root"/* ]]; then
    print -u2 -r -- "travel-cat-swift: scratch root must be outside the project: $scratch_root"
    exit 73
fi
scratch_root_owner="$(stat -f '%u' "$scratch_root" 2>/dev/null || true)"
scratch_root_mode="$(stat -f '%Lp' "$scratch_root" 2>/dev/null || true)"
if [[ -z "$scratch_root_owner" || "$scratch_root_owner" != "$(id -u)" ]]; then
    print -u2 -r -- "travel-cat-swift: scratch root must be owned by the current user: $scratch_root"
    exit 73
fi
if [[ -z "$scratch_root_mode" ]] || (( (8#$scratch_root_mode & 8#022) != 0 )); then
    print -u2 -r -- "travel-cat-swift: scratch root must not be group- or world-writable: $scratch_root"
    exit 73
fi

scratch_node="$scratch_root/$cache_id"
if [[ -L "$scratch_node" ]]; then
    print -u2 -r -- "travel-cat-swift: scratch path must not be a symlink: $scratch_node"
    exit 73
fi
(umask 077; mkdir -p "$scratch_node") || {
    print -u2 -r -- "travel-cat-swift: could not create scratch path: $scratch_node"
    exit 73
}
if [[ -L "$scratch_node" ]]; then
    print -u2 -r -- "travel-cat-swift: scratch path must not be a symlink: $scratch_node"
    exit 73
fi
scratch_path="$(cd -- "$scratch_node" && pwd -P)"
if [[ "$scratch_path" != "$scratch_root"/* || "$scratch_path" == "$project_root" || "$scratch_path" == "$project_root"/* ]]; then
    print -u2 -r -- "travel-cat-swift: scratch path must remain outside the project: $scratch_path"
    exit 73
fi
scratch_owner="$(stat -f '%u' "$scratch_path" 2>/dev/null || true)"
if [[ -z "$scratch_owner" || "$scratch_owner" != "$(id -u)" ]]; then
    print -u2 -r -- "travel-cat-swift: scratch path must be owned by the current user: $scratch_path"
    exit 73
fi
if ! chmod 700 "$scratch_path" || [[ "$(stat -f '%Lp' "$scratch_path" 2>/dev/null || true)" != "700" ]]; then
    print -u2 -r -- "travel-cat-swift: scratch path permissions must be 700: $scratch_path"
    exit 73
fi
write_probe="$(mktemp "$scratch_path/.travel-cat-swift-write-test.XXXXXX" 2>/dev/null || true)"
if [[ -z "$write_probe" ]]; then
    print -u2 -r -- "travel-cat-swift: scratch path is not writable: $scratch_path"
    exit 73
fi
rm -f -- "$write_probe"

if [[ "$subcommand" == "scratch-path" ]]; then
    print -r -- "$scratch_path"
    exit 0
fi

swift_bin="${TRAVEL_CAT_SWIFT_BIN:-}"
if [[ -z "$swift_bin" ]]; then
    swift_bin="$(command -v swift 2>/dev/null || true)"
fi
[[ -z "$swift_bin" ]] || swift_bin="${swift_bin:A}"
if [[ -z "$swift_bin" || ! -x "$swift_bin" ]]; then
    print -u2 -r -- "travel-cat-swift: Swift executable was not found or is not executable"
    exit 69
fi

cd -- "$project_root"
if [[ "$subcommand" == "run" ]]; then
    exec "$swift_bin" run --scratch-path "$scratch_path" -- "${forwarded_arguments[@]}"
fi
exec "$swift_bin" "$subcommand" --scratch-path "$scratch_path" "${forwarded_arguments[@]}"
