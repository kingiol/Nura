#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
APP=${1:?usage: package-libmpv-runtime.sh /path/to/Nura.app}
LOCK="$ROOT/runtime/macos-arm64.lock"
FFMPEG_LOCK="$ROOT/runtime/ffmpeg-macos-arm64.lock"
FRAMEWORKS="$APP/Contents/Frameworks"
RESOURCES="$APP/Contents/Resources"
MANIFEST="$RESOURCES/libmpv-runtime-manifest.tsv"
FFMPEG_MANIFEST="$RESOURCES/ffmpeg-runtime-manifest.tsv"
TOOLS="$RESOURCES/bin"
FFMPEG_LIBRARIES="libavdevice.63.1.101.dylib"

[ -d "$APP/Contents" ] || {
    printf '%s\n' "not a macOS app bundle: $APP" >&2
    exit 1
}
[ -f "$LOCK" ] || {
    printf '%s\n' "runtime lock is missing: $LOCK" >&2
    exit 1
}
[ -f "$FFMPEG_LOCK" ] || {
    printf '%s\n' "FFmpeg runtime lock is missing: $FFMPEG_LOCK" >&2
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

nura_resolve_ffmpeg_binary() {
    name=$1
    case "$name" in
        ffmpeg) source=${NURA_FFMPEG_BINARY:-} ;;
        ffprobe) source=${NURA_FFPROBE_BINARY:-} ;;
        *)
            printf '%s\n' "unsupported FFmpeg binary: $name" >&2
            return 1
            ;;
    esac

    if [ -z "$source" ]; then
        for candidate in \
            "/opt/homebrew/bin/$name" \
            "/usr/local/bin/$name" \
            "/opt/homebrew/opt/ffmpeg/bin/$name" \
            "/usr/local/opt/ffmpeg/bin/$name"; do
            if [ -f "$candidate" ]; then
                source=$candidate
                break
            fi
        done
    fi

    [ -f "$source" ] || {
        printf '%s\n' "$name was not found. Run: brew bundle --file=\"$ROOT/Brewfile\"" >&2
        return 1
    }
    nura_realpath "$source"
}

nura_resolve_ffmpeg_library() {
    filename=$1
    for candidate in \
        "/opt/homebrew/Cellar/ffmpeg/9.0.1_1/lib/$filename" \
        "/usr/local/Cellar/ffmpeg/9.0.1_1/lib/$filename"; do
        if [ -f "$candidate" ]; then
            printf '%s\n' "$(nura_realpath "$candidate")"
            return 0
        fi
    done

    printf '%s\n' "FFmpeg library $filename was not found. Run: brew bundle --file=\"$ROOT/Brewfile\"" >&2
    return 1
}

records=$(mktemp "${TMPDIR:-/tmp}/nura-libmpv-records.XXXXXX")
actual_lock=$(mktemp "${TMPDIR:-/tmp}/nura-libmpv-actual.XXXXXX")
dependencies=$(mktemp "${TMPDIR:-/tmp}/nura-libmpv-dependencies.XXXXXX")
bundled_dylibs=$(mktemp "${TMPDIR:-/tmp}/nura-libmpv-bundled.XXXXXX")
closure=$(mktemp "${TMPDIR:-/tmp}/nura-libmpv-closure.XXXXXX")
sorted_records=$(mktemp "${TMPDIR:-/tmp}/nura-libmpv-sorted-records.XXXXXX")
stale_filenames=$(mktemp "${TMPDIR:-/tmp}/nura-libmpv-stale.XXXXXX")
actual_ffmpeg_lock=$(mktemp "${TMPDIR:-/tmp}/nura-ffmpeg-actual.XXXXXX")
ffmpeg_dependencies=$(mktemp "${TMPDIR:-/tmp}/nura-ffmpeg-dependencies.XXXXXX")
trap 'rm -f "$records" "$actual_lock" "$dependencies" "$bundled_dylibs" "$closure" "$sorted_records" "$stale_filenames" "$actual_ffmpeg_lock" "$ffmpeg_dependencies"' EXIT HUP INT TERM

source=$(nura_resolve_mpv_source)
nura_ffmpeg=$(nura_resolve_ffmpeg_binary ffmpeg)
nura_ffprobe=$(nura_resolve_ffmpeg_binary ffprobe)
ffmpeg_library=$(nura_resolve_ffmpeg_library "$FFMPEG_LIBRARIES")
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

{
    printf '%s\n' '# filename	source_path	sha256	architectures'
    for ffmpeg_source in "$nura_ffmpeg" "$nura_ffprobe" "$ffmpeg_library"; do
        ffmpeg_filename=$(basename "$ffmpeg_source")
        ffmpeg_sha256=$(shasum -a 256 "$ffmpeg_source" | awk '{print $1}')
        ffmpeg_architectures=$(lipo -archs "$ffmpeg_source")
        printf '%s\t%s\t%s\t%s\n' "$ffmpeg_filename" "$ffmpeg_source" "$ffmpeg_sha256" "$ffmpeg_architectures"
    done
} > "$actual_ffmpeg_lock"

if ! cmp -s "$FFMPEG_LOCK" "$actual_ffmpeg_lock"; then
    printf '%s\n' "FFmpeg runtime does not match $FFMPEG_LOCK. Review the binary upgrade and update the lock deliberately." >&2
    diff -u "$FFMPEG_LOCK" "$actual_ffmpeg_lock" >&2 || true
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
    temporary_copy=$(mktemp "$FRAMEWORKS/.nura-runtime.XXXXXX")
    cp -L "$source_path" "$temporary_copy"
    chmod 644 "$temporary_copy"
    mv -f "$temporary_copy" "$FRAMEWORKS/$filename"
done < "$actual_lock"

mkdir -p "$TOOLS"
for bundled_file in "$nura_ffmpeg:$TOOLS/ffmpeg" "$nura_ffprobe:$TOOLS/ffprobe" "$ffmpeg_library:$FRAMEWORKS/$FFMPEG_LIBRARIES"; do
    source_file=${bundled_file%%:*}
    target_file=${bundled_file#*:}
    temporary_copy=$(mktemp "$(dirname "$target_file")/.nura-runtime.XXXXXX")
    cp -L "$source_file" "$temporary_copy"
    chmod 644 "$temporary_copy"
    mv -f "$temporary_copy" "$target_file"
done
chmod 755 "$TOOLS/ffmpeg" "$TOOLS/ffprobe"

while IFS='	' read -r ffmpeg_filename ffmpeg_source sha256 architectures; do
    [ "$ffmpeg_filename" = '# filename' ] && continue
    case "$ffmpeg_filename" in
        ffmpeg|ffprobe) ffmpeg_path="$TOOLS/$ffmpeg_filename" ;;
        *) ffmpeg_path="$FRAMEWORKS/$ffmpeg_filename" ;;
    esac
    nura_dependency_references "$ffmpeg_source" > "$ffmpeg_dependencies"
    while IFS= read -r reference; do
        nura_is_system_dependency "$reference" && continue
        dependency_source=$(nura_resolve_dependency "$ffmpeg_source" "$reference")
        nura_is_system_dependency "$dependency_source" && continue
        dependency_filename=$(awk -F '\t' -v source="$dependency_source" '$2 == source { print $1; exit }' "$records")
        if [ -n "$dependency_filename" ]; then
            case "$ffmpeg_filename" in
                ffmpeg|ffprobe)
                    dependency_replacement="@loader_path/../../Frameworks/$dependency_filename"
                    ;;
                *)
                    dependency_replacement="@loader_path/$dependency_filename"
                    ;;
            esac
        else
            dependency_filename=$(awk -F '\t' -v source="$dependency_source" '$2 == source { print $1; exit }' "$actual_ffmpeg_lock")
            [ -n "$dependency_filename" ] || {
                printf '%s\n' "runtime lock has no bundled filename for $dependency_source" >&2
                exit 1
            }
            case "$ffmpeg_filename" in
                ffmpeg|ffprobe)
                    dependency_replacement="@loader_path/../../Frameworks/$dependency_filename"
                    ;;
                *)
                    dependency_replacement="@loader_path/$dependency_filename"
                    ;;
            esac
        fi
        nura_install_name_tool -change "$reference" "$dependency_replacement" "$ffmpeg_path"
    done < "$ffmpeg_dependencies"
done < "$actual_ffmpeg_lock"

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
        if [ -n "$dependency_filename" ]; then
            dependency_replacement="@loader_path/$dependency_filename"
        else
            dependency_filename=$(awk -F '	' -v source="$dependency_source" '$2 == source { print $1; exit }' "$actual_ffmpeg_lock")
            [ -n "$dependency_filename" ] || {
                printf '%s\n' "runtime lock has no bundled filename for $dependency_source" >&2
                exit 1
            }
            dependency_replacement="@loader_path/$dependency_filename"
        fi
        nura_install_name_tool -change "$reference" "$dependency_replacement" "$dylib"
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
                if [ "$reference" = "@rpath/$(basename "$dylib")" ]; then
                    continue
                fi
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
cp "$actual_ffmpeg_lock" "$FFMPEG_MANIFEST"

for tool in "$TOOLS/ffmpeg" "$TOOLS/ffprobe"; do
    nura_dependency_references "$tool" > "$ffmpeg_dependencies"
    while IFS= read -r reference; do
        case "$reference" in
            /opt/homebrew/*|/usr/local/*)
                printf '%s\n' "bundled FFmpeg binary still references Homebrew: $tool -> $reference" >&2
                exit 1
                ;;
            @loader_path/../../Frameworks/*)
                dependency_filename=${reference##*/}
                [ -f "$FRAMEWORKS/$dependency_filename" ] || {
                    printf '%s\n' "bundled FFmpeg dependency is missing: $tool -> $reference" >&2
                    exit 1
                }
                ;;
            @rpath/*|@executable_path/*|@loader_path/*)
                printf '%s\n' "unresolved bundled FFmpeg dependency: $tool -> $reference" >&2
                exit 1
                ;;
        esac
    done < "$ffmpeg_dependencies"
    file -b "$tool" | grep -q 'Mach-O 64-bit dynamically linked shared library arm64\|Mach-O 64-bit executable arm64'
    if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
        codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$tool"
        codesign --verify --strict "$tool"
    fi
done

printf '%s\n' "Bundled $(awk 'NR > 1 { count += 1 } END { print count + 0 }' "$actual_lock") verified libmpv runtime dylibs and FFmpeg tools into $APP"
