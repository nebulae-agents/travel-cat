#!/bin/zsh

set -euo pipefail

source_dir="${1:-${HOME}/.codex/pets/cute-black-cat}"
source_manifest="${source_dir}/pet.json"
source_sheet="${source_dir}/spritesheet.webp"

repository_root="${0:A:h:h}"
destination_dir="${repository_root}/Sources/TravelUI/Resources"
destination_manifest="${destination_dir}/pet.json"
destination_sheet="${destination_dir}/cute-black-cat-spritesheet.webp"

if [[ ! -f "${source_manifest}" || -L "${source_manifest}" ]]; then
    print -u2 "Pet manifest must be a regular non-symlink file: ${source_manifest}"
    exit 1
fi

if [[ ! -f "${source_sheet}" || -L "${source_sheet}" ]]; then
    print -u2 "Pet spritesheet must be a regular non-symlink file: ${source_sheet}"
    exit 1
fi

preflight_destination() {
    if [[ -L "${destination_dir}" || ( -e "${destination_dir}" && ! -d "${destination_dir}" ) ]]; then
        print -u2 "Resource destination must be a real directory: ${destination_dir}"
        exit 1
    fi

    if [[ -d "${destination_dir}" ]]; then
        if [[ -L "${destination_manifest}" || ( -e "${destination_manifest}" && ! -f "${destination_manifest}" ) ]]; then
            print -u2 "Existing manifest destination must be a regular non-symlink file."
            exit 1
        fi

        if [[ -L "${destination_sheet}" || ( -e "${destination_sheet}" && ! -f "${destination_sheet}" ) ]]; then
            print -u2 "Existing spritesheet destination must be a regular non-symlink file."
            exit 1
        fi
    fi
}

preflight_destination

external_staging_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/travel-cat-pet-import.XXXXXX")"
commit_staging_dir=""
destination_created=0
commit_started=0
commit_complete=0
had_manifest=0
had_sheet=0

cleanup() {
    exit_status=$?
    set +e

    if [[ -n "${commit_staging_dir}" ]] && (( commit_started == 1 && commit_complete == 0 )); then
        if (( had_manifest == 1 )); then
            /bin/mv -f "${commit_staging_dir}/original-pet.json" "${destination_manifest}"
        else
            /bin/rm -f "${destination_manifest}"
        fi

        if (( had_sheet == 1 )); then
            /bin/mv -f "${commit_staging_dir}/original-spritesheet.webp" "${destination_sheet}"
        else
            /bin/rm -f "${destination_sheet}"
        fi
    fi

    if [[ -n "${commit_staging_dir}" ]]; then
        /bin/rm -rf "${commit_staging_dir}"
    fi
    /bin/rm -rf "${external_staging_dir}"

    if (( destination_created == 1 && commit_complete == 0 )); then
        /bin/rmdir "${destination_dir}" 2>/dev/null
    fi

    exit "${exit_status}"
}
trap cleanup EXIT

validated_manifest="${external_staging_dir}/pet.json"
validated_sheet="${external_staging_dir}/cute-black-cat-spritesheet.webp"
/bin/cp "${source_manifest}" "${validated_manifest}"
/bin/cp "${source_sheet}" "${validated_sheet}"

manifest_xml="$(/usr/bin/plutil -convert xml1 -o - "${validated_manifest}")"
manifest_is_authorized="$(
    print -r -- "${manifest_xml}" | /usr/bin/xmllint --xpath '
        boolean(
            count(/plist/dict/key) = 4
            and count(/plist/dict/key[. = "displayName"]) = 1
            and count(/plist/dict/key[. = "description"]) = 1
            and count(/plist/dict/key[. = "spriteVersionNumber"]) = 1
            and count(/plist/dict/key[. = "spritesheetPath"]) = 1
            and /plist/dict/key[. = "displayName"]
                /following-sibling::*[1][self::string and . = "Cute Black Cat"]
            and /plist/dict/key[. = "description"]
                /following-sibling::*[1][self::string and . = "A calm golden-eyed black cat with a subtle violet glow."]
            and /plist/dict/key[. = "spriteVersionNumber"]
                /following-sibling::*[1][self::integer and . = "2"]
            and /plist/dict/key[. = "spritesheetPath"]
                /following-sibling::*[1][self::string and . = "spritesheet.webp"]
        )
    ' -
)"

if [[ "${manifest_is_authorized}" != "true" ]]; then
    print -u2 "Pet manifest does not exactly match the authorized Cute Black Cat manifest."
    exit 1
fi

image_properties="$(/usr/bin/sips -g format -g pixelWidth -g pixelHeight "${validated_sheet}")"
image_format="$(print -r -- "${image_properties}" | /usr/bin/awk '/format:/ { print $2 }')"
pixel_width="$(print -r -- "${image_properties}" | /usr/bin/awk '/pixelWidth:/ { print $2 }')"
pixel_height="$(print -r -- "${image_properties}" | /usr/bin/awk '/pixelHeight:/ { print $2 }')"

if [[ "${image_format}" != "webp" || "${pixel_width}" != "1536" || "${pixel_height}" != "2288" ]]; then
    print -u2 "Unexpected spritesheet: format=${image_format} dimensions=${pixel_width}x${pixel_height}"
    exit 1
fi

preflight_destination
if [[ ! -e "${destination_dir}" ]]; then
    /bin/mkdir -p "${destination_dir}"
    destination_created=1
fi
preflight_destination

commit_staging_dir="$(/usr/bin/mktemp -d "${destination_dir}/.pet-import.XXXXXX")"
staged_manifest="${commit_staging_dir}/pet.json"
staged_sheet="${commit_staging_dir}/cute-black-cat-spritesheet.webp"
/bin/cp "${validated_manifest}" "${staged_manifest}"
/bin/cp "${validated_sheet}" "${staged_sheet}"

if ! /usr/bin/cmp -s "${validated_manifest}" "${staged_manifest}"; then
    print -u2 "Commit-stage manifest differs from the validated manifest."
    exit 1
fi

if ! /usr/bin/cmp -s "${validated_sheet}" "${staged_sheet}"; then
    print -u2 "Commit-stage spritesheet differs from the validated spritesheet."
    exit 1
fi

if [[ -f "${destination_manifest}" ]]; then
    /bin/cp -p "${destination_manifest}" "${commit_staging_dir}/original-pet.json"
    had_manifest=1
fi

if [[ -f "${destination_sheet}" ]]; then
    /bin/cp -p "${destination_sheet}" "${commit_staging_dir}/original-spritesheet.webp"
    had_sheet=1
fi

commit_started=1
/bin/mv -f "${staged_manifest}" "${destination_manifest}"
/bin/mv -f "${staged_sheet}" "${destination_sheet}"
commit_complete=1

print "Imported Cute Black Cat sprite resources."
