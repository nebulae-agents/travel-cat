#!/bin/sh

travel_cat_launcher_error() {
    echo "travel-cat: $1" >&2
    return 65
}

travel_cat_reject_linked_ancestors() {
    path=$1
    case "$path" in
        /tmp/*) path=/private/tmp/${path#/tmp/} ;;
        /var/*) path=/private/var/${path#/var/} ;;
    esac
    case "$path" in /*) ;; *) return 1 ;; esac
    while [ "$path" != "/" ]; do
        [ ! -L "$path" ] || return 1
        path=${path%/*}
        [ -n "$path" ] || path=/
    done
}

travel_cat_validate_app() {
    app=$1
    contents="$app/Contents"
    resources="$contents/Resources"
    launcher="$app/Contents/Resources/run-travelcatctl"
    plist="$app/Contents/Info.plist"

    [ -d "$app" ] && [ ! -L "$app" ] || return 1
    [ -d "$contents" ] && [ ! -L "$contents" ] || return 1
    [ -d "$resources" ] && [ ! -L "$resources" ] || return 1
    [ -f "$plist" ] && [ ! -L "$plist" ] || return 1
    [ -f "$launcher" ] && [ ! -L "$launcher" ] && [ -x "$launcher" ] || return 1
    /usr/bin/codesign --verify --deep --strict "$app" >/dev/null 2>&1 || return 1
    bundle_id=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$plist" 2>/dev/null) || return 1
    [ "$bundle_id" = "com.nebulae.travelcat" ] || return 1
    printf '%s\n' "$launcher"
}

travel_cat_find_launcher() {
    [ "$#" -eq 2 ] || { travel_cat_launcher_error "internal discovery arguments are invalid"; return; }
    user_apps=$1
    system_apps=$2
    found=
    count=0
    for directory in "$user_apps" "$system_apps"; do
        travel_cat_reject_linked_ancestors "$directory" || {
            travel_cat_launcher_error "Applications path has an unsafe linked ancestor"
            return
        }
        if [ -e "$directory" ] || [ -L "$directory" ]; then
            [ -d "$directory" ] && [ ! -L "$directory" ] || {
                travel_cat_launcher_error "Applications location is not a regular directory"
                return
            }
        fi
        candidate="$directory/Travel Cat.app"
        if launcher=$(travel_cat_validate_app "$candidate"); then
            found=$launcher
            count=$((count + 1))
        elif [ -e "$candidate" ] || [ -L "$candidate" ]; then
            travel_cat_launcher_error "Travel Cat.app is present but failed signature or identity validation"
            return
        fi
    done
    [ "$count" -eq 1 ] || {
        if [ "$count" -eq 0 ]; then
            travel_cat_launcher_error "install one signed Travel Cat.app in Applications"
        else
            travel_cat_launcher_error "multiple signed Travel Cat.app installations found; keep exactly one"
        fi
        return
    }
    printf '%s\n' "$found"
}

travel_cat_run_from_directories() {
    [ "$#" -eq 3 ] || { echo "travel-cat: expected exactly one command" >&2; return 64; }
    user_apps=$1
    system_apps=$2
    command=$3
    case "$command" in
        status|journal|pending-images|claim|validate-candidate|publish|mark-image) ;;
        *) echo "travel-cat: command is not allowlisted" >&2; return 64 ;;
    esac
    launcher=$(travel_cat_find_launcher "$user_apps" "$system_apps") || return
    exec "$launcher" "$command"
}
