#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
APP=${1:?usage: package-libmpv-runtime.sh /path/to/Nura.app}
LOCK="$ROOT/runtime/macos-arm64.lock"
FRAMEWORKS="$APP/Contents/Frameworks"
RESOURCES="$APP/Contents/Resources"
MANIFEST="$RESOURCES/libmpv-runtime-manifest.tsv"

[ -d "$APP/Contents" ] || {
    printf '%s\n' "not a macOS app bundle: $APP" >&2
    exit 1
}
[ -f "$LOCK" ] || {
    printf '%s\n' "runtime lock is missing: $LOCK" >&2
    exit 1
}

. "$ROOT/scripts/libmpv-runtime.sh"

nura_install_name_tool() {
    stderr_file=$(mktemp "${TMPDIR:-/tmp}/nura-install-name-tool.XXXXXX")
    if ! install_name_tool "$@" 2>"$stderr_file"; then
        cat "$stderr_file" >&2
        rm -f "$stderr_file"
        return 1
    fi
    grep -v 'warning: changes being made to the file will invalidate the code signature' \
        "$stderr_file" >&2 || true
    rm -f "$stderr_file"
}

records=$(mktemp "${TMPDIR:-/tmp}/nura-libmpv-records.XXXXXX")
actual_lock=$(mktemp "${TMPDIR:-/tmp}/nura-libmpv-actual.XXXXXX")
dependencies=$(mktemp "${TMPDIR:-/tmp}/nura-libmpv-dependencies.XXXXXX")
bundled_dylibs=$(mktemp "${TMPDIR:-/tmp}/nura-libmpv-bundled.XXXXXX")
closure=$(mktemp "${TMPDIR:-/tmp}/nura-libmpv-closure.XXXXXX")
sorted_records=$(mktemp "${TMPDIR:-/tmp}/nura-libmpv-sorted-records.XXXXXX")
stale_filenames=$(mktemp "${TMPDIR:-/tmp}/nura-libmpv-stale.XXXXXX")
trap 'rm -f "$records" "$actual_lock" "$dependencies" "$bundled_dylibs" "$closure" "$sorted_records" "$stale_filenames"' EXIT HUP INT TERM

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
} > "$actual_lock"

if ! cmp -s "$LOCK" "$actual_lock"; then
    printf '%s\n' "libmpv runtime does not match $LOCK. Run scripts/update-libmpv-runtime-lock.sh, review the diff, and commit the approved runtime upgrade." >&2
    diff -u "$LOCK" "$actual_lock" >&2 || true
    exit 1
fi

mkdir -p "$FRAMEWORKS" "$RESOURCES"
if [ -f "$MANIFEST" ]; then
    awk -F '	' 'NR > 1 { print $1 }' "$MANIFEST" > "$stale_filenames"
    while IFS= read -r filename; do
        case "$filename" in
            *[!A-Za-z0-9._-]*|'')
                printf '%s\n' "unsafe runtime manifest filename: $filename" >&2
                exit 1
                ;;
        esac
        rm -f "$FRAMEWORKS/$filename"
    done < "$stale_filenames"
fi

while IFS='	' read -r filename source_path sha256 architectures; do
    [ "$filename" = '# filename' ] && continue
    cp -L "$source_path" "$FRAMEWORKS/$filename"
done < "$actual_lock"

while IFS='	' read -r filename source_path sha256 architectures; do
    [ "$filename" = '# filename' ] && continue
    dylib="$FRAMEWORKS/$filename"
    nura_install_name_tool -id "@rpath/$filename" "$dylib"

    nura_dependency_references "$source_path" > "$dependencies"
    while IFS= read -r reference; do
        nura_is_system_dependency "$reference" && continue
        dependency_source=$(nura_resolve_dependency "$source_path" "$reference")
        nura_is_system_dependency "$dependency_source" && continue
        dependency_filename=$(awk -F '	' -v source="$dependency_source" '$2 == source { print $1; exit }' "$records")
        [ -n "$dependency_filename" ] || {
            printf '%s\n' "runtime lock has no bundled filename for $dependency_source" >&2
            exit 1
        }
        nura_install_name_tool -change "$reference" "@loader_path/$dependency_filename" "$dylib"
    done < "$dependencies"
done < "$actual_lock"

find "$FRAMEWORKS" -maxdepth 1 -type f -name '*.dylib' -print |
    LC_ALL=C sort > "$bundled_dylibs"
while IFS= read -r dylib; do
    nura_dependency_references "$dylib" > "$dependencies"
    while IFS= read -r reference; do
        case "$reference" in
            /opt/homebrew/*|/usr/local/*)
                printf '%s\n' "bundled dependency still references Homebrew: $dylib -> $reference" >&2
                exit 1
                ;;
            @loader_path/*)
                dependency_filename=${reference#@loader_path/}
                [ -f "$FRAMEWORKS/$dependency_filename" ] || {
                    printf '%s\n' "bundled dependency is missing: $dylib -> $reference" >&2
                    exit 1
                }
                ;;
            @rpath/*|@executable_path/*)
                printf '%s\n' "unresolved bundled dependency: $dylib -> $reference" >&2
                exit 1
                ;;
        esac
    done < "$dependencies"

    if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
        codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$dylib"
        codesign --verify --strict "$dylib"
    fi
done < "$bundled_dylibs"

cp "$actual_lock" "$MANIFEST"
printf '%s\n' "Bundled $(awk 'NR > 1 { count += 1 } END { print count + 0 }' "$actual_lock") verified libmpv runtime dylibs into $APP"
