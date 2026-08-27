#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LOCK="$ROOT/runtime/macos-arm64.lock"

[ -f "$LOCK" ] || {
    printf '%s\n' "runtime lock is missing: $LOCK" >&2
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

find "$app/Contents/Frameworks" -maxdepth 1 -type f -name '*.dylib' -print |
    LC_ALL=C sort > "$temporary/dylibs"
while IFS= read -r dylib; do
    file -b "$dylib" | grep -q 'Mach-O 64-bit dynamically linked shared library arm64'
    ! otool -L "$dylib" | grep -Eq '/(opt/homebrew|usr/local)/'
done < "$temporary/dylibs"

printf '%s\n' "Verified $(wc -l < "$temporary/dylibs" | tr -d ' ') bundled libmpv runtime dylibs."
