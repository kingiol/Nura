#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
YTDL_PATH="${NURA_YTDL_PATH:-}"
STANDALONE_VERSION="2026.08.19"
STANDALONE_URL="https://github.com/yt-dlp/yt-dlp/releases/download/${STANDALONE_VERSION}/yt-dlp_macos"
STANDALONE_SHA256="0f192b7ec147ab6288885d6351d9ab67367640029b4377576ef46dd79cf7b202"

is_standalone() {
    [ -f "$1" ] || return 1
    file -b "$1" | grep -q "Mach-O"
}

if [ "${1:-}" = "--standalone" ]; then
    if [ -n "$YTDL_PATH" ] && is_standalone "$YTDL_PATH"; then
        printf '%s\n' "$YTDL_PATH"
        exit 0
    fi

    CACHE_DIR="$ROOT/build/tooling"
    CACHED_PATH="$CACHE_DIR/yt-dlp_macos-$STANDALONE_VERSION"
    mkdir -p "$CACHE_DIR"
    if ! is_standalone "$CACHED_PATH"; then
        curl -L --fail --silent --show-error "$STANDALONE_URL" -o "$CACHED_PATH"
    fi
    ACTUAL_SHA256="$(shasum -a 256 "$CACHED_PATH" | awk '{print $1}')"
    if [ "$ACTUAL_SHA256" != "$STANDALONE_SHA256" ]; then
        printf '%s\n' "yt-dlp standalone checksum mismatch" >&2
        exit 1
    fi
    chmod 755 "$CACHED_PATH"
    printf '%s\n' "$CACHED_PATH"
    exit 0
fi

if [ -z "$YTDL_PATH" ]; then
    YTDL_PATH="$(command -v yt-dlp 2>/dev/null || true)"
fi

if [ -z "$YTDL_PATH" ] || [ ! -f "$YTDL_PATH" ]; then
    printf '%s\n' "yt-dlp was not found. Run: brew bundle --file=\"$ROOT/Brewfile\"" >&2
    exit 1
fi

printf '%s\n' "$YTDL_PATH"
