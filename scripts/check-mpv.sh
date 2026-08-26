#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
MPV_LIBRARY="${NURA_MPV_LIBRARY:-}"

if [ -z "$MPV_LIBRARY" ]; then
    for candidate in /opt/homebrew/lib/libmpv.2.dylib /usr/local/lib/libmpv.2.dylib; do
        if [ -f "$candidate" ]; then
            MPV_LIBRARY="$candidate"
            break
        fi
    done
fi

if [ -z "$MPV_LIBRARY" ] || [ ! -f "$MPV_LIBRARY" ]; then
    printf '%s\n' "libmpv.2.dylib was not found. Run: brew bundle --file=\"$ROOT/Brewfile\"" >&2
    exit 1
fi

printf '%s\n' "$MPV_LIBRARY"
