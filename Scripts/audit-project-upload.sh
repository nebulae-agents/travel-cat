#!/bin/zsh

set -euo pipefail

operational_error() {
    print -u2 -r -- "upload-audit: operational error: $*"
    exit 70
}

script_dir="$(cd -- "$(dirname -- "$0")" && pwd -P)"
project_root="$(cd -- "$script_dir/.." && pwd -P)"
cd -- "$project_root"

if [[ "$(git rev-parse --is-inside-work-tree 2>/dev/null || true)" != "true" ]]; then
    print -u2 -r -- "upload-audit: project root is not a Git worktree: $project_root"
    exit 69
fi

git_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$git_root" ]]; then
    print -u2 -r -- "upload-audit: could not resolve the Git worktree root"
    exit 69
fi
git_root="$(cd -- "$git_root" && pwd -P)"
if [[ "$git_root" != "$project_root" ]]; then
    print -u2 -r -- "upload-audit: script project root does not match the Git worktree root"
    exit 69
fi

threshold_text="${TRAVEL_CAT_UPLOAD_MAX_BYTES-5242880}"
if [[ ! "$threshold_text" =~ '^[0-9]+$' ]]; then
    print -u2 -r -- "upload-audit: TRAVEL_CAT_UPLOAD_MAX_BYTES must be a non-negative decimal integer"
    exit 64
fi

threshold_digits="${threshold_text#"${threshold_text%%[!0]*}"}"
[[ -n "$threshold_digits" ]] || threshold_digits="0"
if (( ${#threshold_digits} > 19 )) || \
   { (( ${#threshold_digits} == 19 )) && [[ "$threshold_digits" > "9223372036854775807" ]]; }; then
    print -u2 -r -- "upload-audit: TRAVEL_CAT_UPLOAD_MAX_BYTES exceeds the supported 64-bit range"
    exit 64
fi

typeset -i threshold=$(( 10#$threshold_digits ))
typeset -i physical_bytes=0
typeset -i tracked_bytes=0
typeset -i staged_bytes=0
typeset -i failures=0
typeset -i preflight_enforced=0

tracked_list_file=""
staged_list_file=""
index_entry_file=""
bulk_list_file=""
cleanup_audit_temp() {
    [[ -z "$tracked_list_file" ]] || rm -f -- "$tracked_list_file" || true
    [[ -z "$staged_list_file" ]] || rm -f -- "$staged_list_file" || true
    [[ -z "$index_entry_file" ]] || rm -f -- "$index_entry_file" || true
    [[ -z "$bulk_list_file" ]] || rm -f -- "$bulk_list_file" || true
}
trap cleanup_audit_temp EXIT

umask 077
tracked_list_file="$(mktemp /tmp/travel-cat-upload-tracked.XXXXXX)" || operational_error "could not create tracked-file list"
staged_list_file="$(mktemp /tmp/travel-cat-upload-staged.XXXXXX)" || operational_error "could not create staged-file list"
index_entry_file="$(mktemp /tmp/travel-cat-upload-index.XXXXXX)" || operational_error "could not create index-entry file"
bulk_list_file="$(mktemp /tmp/travel-cat-upload-bulk.XXXXXX)" || operational_error "could not create bulk-path list"

github_preflight="$project_root/Scripts/github_preflight.py"
if [[ -f "$github_preflight" ]]; then
    if ! command -v python3 >/dev/null 2>&1; then
        operational_error "python3 is required for the public-source preflight"
    fi
    preflight_enforced=1
    preflight_status=0
    python3 "$github_preflight" --repository "$project_root" --max-bytes "$threshold" || preflight_status=$?
    if (( preflight_status == 65 )); then
        (( failures += 1 )) || true
    elif (( preflight_status != 0 )); then
        operational_error "public-source preflight returned $preflight_status"
    fi
fi

if ! du_output="$(du -sk .)"; then
    operational_error "could not measure project size"
fi
physical_kilobytes="${du_output%%[[:space:]]*}"
physical_bytes=$(( physical_kilobytes * 1024 ))

if ! git ls-files -z > "$tracked_list_file"; then
    operational_error "git ls-files failed"
fi
while IFS= read -r -d $'\0' tracked_path; do
    if [[ -f "./$tracked_path" || -L "./$tracked_path" ]]; then
        if ! tracked_size="$(stat -f '%z' "./$tracked_path")"; then
            operational_error "could not measure tracked path: ${(q)tracked_path}"
        fi
        (( tracked_bytes += tracked_size )) || true
    fi
done < "$tracked_list_file"

if ! find . \
    -iname .git -prune -o \
    \( \
        -iname .build -o \
        -iname .worktrees -o \
        -iname dist -o \
        -iname .swiftpm -o \
        -iname DerivedData -o \
        \( -iname brainstorm -a -ipath '*/.superpowers/brainstorm' \) \
    \) -print0 -prune > "$bulk_list_file"; then
    operational_error "could not enumerate local bulk paths"
fi
while IFS= read -r -d $'\0' bulk_path; do
    bulk_path="${bulk_path#./}"
    print -r -- "upload-audit: local bulk path exists: ${(q)bulk_path}"
    (( failures += 1 )) || true
done < "$bulk_list_file"

if ! git diff --cached --name-only --diff-filter=ACMRT -z > "$staged_list_file"; then
    operational_error "git diff --cached failed"
fi
while IFS= read -r -d $'\0' staged_path; do
    prohibited=0
    normalized_path="${staged_path:l}"
    case "/$normalized_path/" in
        */.build/*|*/.worktrees/*|*/dist/*|*/.swiftpm/*|*/deriveddata/*|*/travelpetdata/*|*/.superpowers/*)
            prohibited=1
            ;;
        */*.xcresult/*|*/*.dsym/*|*/*.app/*)
            prohibited=1
            ;;
    esac
    case "$normalized_path" in
        *.dsym.zip|*.pkg|*.dmg)
            prohibited=1
            ;;
        *.log|*.out|*.err)
            case "$staged_path" in
                Assets/*|Fixtures/*|Tests/Fixtures/*|Sources/TravelUI/Resources/*) ;;
                *) prohibited=1 ;;
            esac
            ;;
    esac

    if ! git --literal-pathspecs ls-files --stage -z -- "$staged_path" > "$index_entry_file"; then
        operational_error "git ls-files --stage failed for ${(q)staged_path}"
    fi
    index_entry=""
    if ! IFS= read -r -d $'\0' index_entry < "$index_entry_file"; then
        operational_error "staged path is missing from the index: ${(q)staged_path}"
    fi
    index_metadata="${index_entry%%$'\t'*}"
    index_mode="${index_metadata%% *}"
    display_path="${(q)staged_path}"
    if [[ "$index_mode" == "120000" ]]; then
        print -r -- "upload-audit: prohibited staged symlink: $display_path"
        (( failures += 1 )) || true
        continue
    fi

    index_remainder="${index_metadata#* }"
    index_object="${index_remainder%% *}"
    staged_size=0
    if [[ "$index_mode" == 100* ]]; then
        if ! staged_size="$(git cat-file -s "$index_object")"; then
            operational_error "could not measure staged blob: $display_path"
        fi
        (( staged_bytes += staged_size )) || true
    fi

    if (( prohibited )); then
        print -r -- "upload-audit: prohibited staged path: $display_path"
        (( failures += 1 )) || true
    fi
    if (( ! preflight_enforced )) && [[ "$index_mode" == 100* ]] && (( staged_size > threshold )); then
        print -r -- "upload-audit: staged file exceeds limit: path=$display_path bytes=$staged_size limit=$threshold"
        (( failures += 1 )) || true
    fi
done < "$staged_list_file"

print -r -- "upload-audit: physical_bytes=$physical_bytes"
print -r -- "upload-audit: tracked_bytes=$tracked_bytes"
print -r -- "upload-audit: staged_bytes=$staged_bytes"

if (( failures > 0 )); then
    print -r -- "upload-audit: status=blocked failures=$failures"
    exit 65
fi

print -r -- "upload-audit: status=ok"
