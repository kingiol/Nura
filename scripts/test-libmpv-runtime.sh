#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LOCK="$ROOT/runtime/macos-arm64.lock"
FFMPEG_LOCK="$ROOT/runtime/ffmpeg-macos-arm64.lock"

[ -f "$LOCK" ] || {
    printf '%s\n' "runtime lock is missing: $LOCK" >&2
    exit 1
}
[ -f "$FFMPEG_LOCK" ] || {
    printf '%s\n' "FFmpeg runtime lock is missing: $FFMPEG_LOCK" >&2
    exit 1
}

temporary=$(mktemp -d "${TMPDIR:-/tmp}/nura-libmpv-test.XXXXXX")
trap 'rm -rf "$temporary"' EXIT HUP INT TERM

app="$temporary/Nura.app"
mkdir -p "$app/Contents/Resources"
"$ROOT/scripts/package-libmpv-runtime.sh" "$app"

test -f "$app/Contents/Frameworks/libmpv.2.dylib"
test -f "$app/Contents/Resources/libmpv-runtime-manifest.tsv"
cmp -s "$LOCK" "$app/Contents/Resources/libmpv-runtime-manifest.tsv"
test -x "$app/Contents/Resources/bin/ffmpeg"
test -x "$app/Contents/Resources/bin/ffprobe"
cmp -s "$FFMPEG_LOCK" "$app/Contents/Resources/ffmpeg-runtime-manifest.tsv"
test -f "$app/Contents/Frameworks/libavdevice.63.1.101.dylib"

find "$app/Contents/Frameworks" -maxdepth 1 -type f -name '*.dylib' -print |
    LC_ALL=C sort > "$temporary/dylibs"
while IFS= read -r dylib; do
    file -b "$dylib" | grep -q 'Mach-O 64-bit dynamically linked shared library arm64'
    ! otool -L "$dylib" | grep -Eq '/(opt/homebrew|usr/local)/'
done < "$temporary/dylibs"

for tool in "$app/Contents/Resources/bin/ffmpeg" "$app/Contents/Resources/bin/ffprobe"; do
    file -b "$tool" | grep -q 'Mach-O 64-bit executable arm64'
    ! otool -L "$tool" | grep -Eq '/(opt/homebrew|usr/local)/'
done

media="$ROOT/test-fixtures/media/oceans.mp4"
[ -f "$media" ] || {
    printf '%s\n' "skipping FFmpeg conversion smoke test: $media is missing" >&2
    exit 0
}
"$app/Contents/Resources/bin/ffprobe" \
    -v error -print_format json \
    -show_entries format=duration:stream=index,codec_type,disposition \
    -select_streams a \
    "$media" > "$temporary/probe.json"
"$app/Contents/Resources/bin/ffmpeg" \
    -hide_banner -loglevel error -y \
    -i "$media" \
    -ss 0.000 -t 1.000 \
    -map 0:1 \
    -vn -sn -dn \
    -ac 1 -ar 16000 -c:a aac -b:a 64k \
    -movflags +faststart \
    "$temporary/chunk.m4a"
test -s "$temporary/chunk.m4a"
"$app/Contents/Resources/bin/ffprobe" \
    -v error -print_format json \
    -show_entries stream=codec_name,sample_rate,channels \
    "$temporary/chunk.m4a" > "$temporary/chunk-probe.json"
printf '%s\n' "Verified $(wc -l < "$temporary/dylibs" | tr -d ' ') bundled libmpv runtime dylibs, FFmpeg tools, and a real audio extraction smoke test."
