#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LOCK="$ROOT/runtime/macos-arm64.lock"
TMP_LOCK="${LOCK}.tmp"

. "$ROOT/scripts/libmpv-runtime.sh"

mkdir -p "$(dirname "$LOCK")"
records=$(mktemp "${TMPDIR:-/tmp}/nura-libmpv-lock.XXXXXX")
closure=$(mktemp "${TMPDIR:-/tmp}/nura-libmpv-closure.XXXXXX")
sorted_records=$(mktemp "${TMPDIR:-/tmp}/nura-libmpv-sorted-lock.XXXXXX")
trap 'rm -f "$records" "$closure" "$sorted_records" "$TMP_LOCK"' EXIT HUP INT TERM

source=$(nura_resolve_mpv_source)
nura_collect_runtime_closure "$source" > "$closure"
while IFS='	' read -r source_path filename; do
    sha256=$(shasum -a 256 "$source_path" | awk '{print $1}')
    architectures=$(lipo -archs "$source_path")
    printf '%s\t%s\t%s\t%s\n' "$filename" "$source_path" "$sha256" "$architectures"
done < "$closure" > "$records"
LC_ALL=C sort -t '	' -k1,1 "$records" > "$sorted_records"

{
    printf '%s\n' '# filename	source_path	sha256	architectures'
    cat "$sorted_records"
} > "$TMP_LOCK"

mv "$TMP_LOCK" "$LOCK"
printf '%s\n' "Updated $LOCK. Review and commit this lock before accepting a runtime upgrade."
