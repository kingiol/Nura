#!/bin/sh
# Shared helpers for locking and packaging the Homebrew-provided libmpv runtime.

nura_runtime_root() {
    CDPATH= cd -- "$(dirname -- "$0")/.." && pwd
}

nura_realpath() {
    path=$1
    case "$path" in
        /*) ;;
        *) path="$(pwd)/$path" ;;
    esac

    while [ -L "$path" ]; do
        target=$(readlink "$path")
        case "$target" in
            /*) path=$target ;;
            *) path="$(dirname "$path")/$target" ;;
        esac
    done

    directory=$(CDPATH= cd -- "$(dirname "$path")" && pwd -P)
    printf '%s/%s\n' "$directory" "$(basename "$path")"
}

nura_resolve_mpv_source() {
    root=$(nura_runtime_root)
    if [ -n "${NURA_MPV_LIBRARY:-}" ]; then
        source=$NURA_MPV_LIBRARY
    else
        source=$("$root/scripts/check-mpv.sh")
    fi

    [ -f "$source" ] || {
        printf '%s\n' "libmpv source was not found: $source" >&2
        return 1
    }

    nura_realpath "$source"
}

nura_is_system_dependency() {
    case "$1" in
        /System/Library/*|/usr/lib/*) return 0 ;;
        *) return 1 ;;
    esac
}

nura_dependency_references() {
    otool -L "$1" |
        sed '1,2d' |
        sed 's/^[[:space:]]*//' |
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            printf '%s\n' "${line%% *}"
        done
}

nura_loader_rpaths() {
    otool -l "$1" |
        awk '
            $1 == "cmd" && $2 == "LC_RPATH" { want_path = 1; next }
            want_path && $1 == "path" { print $2; want_path = 0 }
        '
}

nura_expand_loader_token() {
    value=$1
    loader=$2
    executable=${3:-}

    case "$value" in
        @loader_path/*)
            printf '%s/%s\n' "$(dirname "$loader")" "${value#@loader_path/}"
            ;;
        @executable_path/*)
            [ -n "$executable" ] || {
                printf '%s\n' "cannot resolve $value without NURA_RUNTIME_EXECUTABLE" >&2
                return 1
            }
            printf '%s/%s\n' "$(dirname "$executable")" "${value#@executable_path/}"
            ;;
        *)
            printf '%s\n' "$value"
            ;;
    esac
}

nura_resolve_dependency() {
    loader=$1
    reference=$2
    executable=${NURA_RUNTIME_EXECUTABLE:-}

    case "$reference" in
        /*)
            candidate=$reference
            ;;
        @loader_path/*|@executable_path/*)
            candidate=$(nura_expand_loader_token "$reference" "$loader" "$executable") || return 1
            ;;
        @rpath/*)
            suffix=${reference#@rpath/}
            rpaths=$(nura_loader_rpaths "$loader")
            old_ifs=$IFS
            IFS='
'
            for rpath in $rpaths; do
                IFS=$old_ifs
                expanded=$(nura_expand_loader_token "$rpath" "$loader" "$executable") || return 1
                candidate="$expanded/$suffix"
                if [ -e "$candidate" ]; then
                    nura_realpath "$candidate"
                    return 0
                fi
                IFS='
'
            done
            IFS=$old_ifs
            printf '%s\n' "cannot resolve $reference referenced by $loader" >&2
            return 1
            ;;
        *)
            printf '%s\n' "unsupported dylib reference $reference in $loader" >&2
            return 1
            ;;
    esac

    [ -e "$candidate" ] || {
        printf '%s\n' "missing dependency $reference resolved from $loader" >&2
        return 1
    }
    nura_realpath "$candidate"
}

nura_collect_runtime_closure() (
    root_source=$(nura_realpath "$1") || return 1
    workdir=$(mktemp -d "${TMPDIR:-/tmp}/nura-libmpv.XXXXXX") || return 1
    queue="$workdir/queue"
    seen="$workdir/seen"
    closure="$workdir/closure"
    dependencies="$workdir/dependencies"

    printf '%s\n' "$root_source" > "$queue"
    : > "$seen"
    : > "$closure"

    while IFS= read -r source; do
        [ -n "$source" ] || continue
        source=$(nura_realpath "$source") || {
            rm -rf "$workdir"
            return 1
        }
        grep -Fqx "$source" "$seen" && continue

        filename=$(basename "$source")
        existing=$(awk -F '\t' -v filename="$filename" '$2 == filename { print $1; exit }' "$closure")
        if [ -n "$existing" ] && [ "$existing" != "$source" ]; then
            printf '%s\n' "dylib basename collision: $filename ($existing and $source)" >&2
            rm -rf "$workdir"
            return 1
        fi

        printf '%s\n' "$source" >> "$seen"
        printf '%s\t%s\n' "$source" "$filename" >> "$closure"

        nura_dependency_references "$source" > "$dependencies"
        while IFS= read -r reference; do
            nura_is_system_dependency "$reference" && continue
            dependency=$(nura_resolve_dependency "$source" "$reference") || {
                rm -rf "$workdir"
                return 1
            }
            nura_is_system_dependency "$dependency" && continue
            printf '%s\n' "$dependency" >> "$queue"
        done < "$dependencies"
    done < "$queue"

    awk -F '\t' '
        {
            if (seen[$1]++) next
            print
        }
    ' "$closure" | LC_ALL=C sort -t '	' -k2,2

    rm -rf "$workdir"
)
