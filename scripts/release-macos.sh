#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_DIR=${NURA_OUTPUT_DIR:-"$ROOT/dist"}
PUBLISH=${NURA_PUBLISH:-0}
SIGNING_IDENTITY=${NURA_SIGNING_IDENTITY:-}
NOTARY_PROFILE=${NURA_NOTARY_PROFILE:-}
SKIP_SIGNING=${NURA_SKIP_SIGNING:-0}
SKIP_NOTARIZATION=${NURA_SKIP_NOTARIZATION:-0}

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        printf '%s\n' "required command not found: $1" >&2
        exit 1
    }
}

for command_name in xcodebuild codesign ditto hdiutil shasum /usr/libexec/PlistBuddy; do
    require_command "$command_name"
done

if [ "$PUBLISH" = "1" ]; then
    [ -n "$SIGNING_IDENTITY" ] || {
        printf '%s\n' 'NURA_SIGNING_IDENTITY is required when NURA_PUBLISH=1' >&2
        exit 1
    }
    [ -n "$NOTARY_PROFILE" ] || {
        printf '%s\n' 'NURA_NOTARY_PROFILE is required when NURA_PUBLISH=1' >&2
        exit 1
    }
    [ "$SKIP_SIGNING" = "0" ] || {
        printf '%s\n' 'NURA_SKIP_SIGNING is not allowed in publish mode' >&2
        exit 1
    }
    [ "$SKIP_NOTARIZATION" = "0" ] || {
        printf '%s\n' 'NURA_SKIP_NOTARIZATION is not allowed in publish mode' >&2
        exit 1
    }
    for command_name in xcrun spctl; do
        require_command "$command_name"
    done
else
    case "$SKIP_SIGNING" in
        0|1) ;;
        *) printf '%s\n' 'NURA_SKIP_SIGNING must be 0 or 1' >&2; exit 1 ;;
    esac
fi

mkdir -p "$OUTPUT_DIR"
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/nura-release.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT HUP INT TERM

"$ROOT/scripts/build-macos-app.sh" >/dev/null
APP="$ROOT/build/Nura.app"
[ -d "$APP/Contents" ] || {
    printf '%s\n' "missing built app: $APP" >&2
    exit 1
}
[ -f "$APP/Contents/Resources/libmpv-runtime-manifest.tsv" ] || {
    printf '%s\n' 'bundled libmpv runtime manifest is missing' >&2
    exit 1
}
"$ROOT/scripts/test-libmpv-runtime.sh" >/dev/null

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
[ -n "$VERSION" ] || {
    printf '%s\n' 'CFBundleShortVersionString is empty' >&2
    exit 1
}

if [ "$PUBLISH" = "1" ] || { [ -n "$SIGNING_IDENTITY" ] && [ "$SKIP_SIGNING" = "0" ]; }; then
    find "$APP/Contents/Frameworks" -type f -name '*.dylib' -exec \
        codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" {} \;
    if [ -x "$APP/Contents/Resources/bin/yt-dlp" ]; then
        codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" \
            "$APP/Contents/Resources/bin/yt-dlp"
    fi
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
    codesign --verify --deep --strict --verbose=2 "$APP"
fi

SUFFIX=
if [ "$PUBLISH" != "1" ]; then
    SUFFIX=-local
fi
BASENAME="Nura-$VERSION-arm64$SUFFIX"
DMG="$OUTPUT_DIR/$BASENAME.dmg"
ZIP="$OUTPUT_DIR/$BASENAME.zip"
rm -f "$DMG" "$ZIP" "$DMG.sha256" "$ZIP.sha256"

DMG_ROOT="$STAGING/dmg-root"
mkdir -p "$DMG_ROOT"
ditto --norsrc --noextattr --noqtn "$APP" "$DMG_ROOT/Nura.app"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create -volname "Nura $VERSION" -srcfolder "$DMG_ROOT" -format UDZO -ov "$DMG" >/dev/null

ZIP_ROOT="$STAGING/zip-root"
mkdir -p "$ZIP_ROOT"
ditto --norsrc --noextattr --noqtn "$APP" "$ZIP_ROOT/Nura.app"
ditto -c -k --keepParent --norsrc --noextattr --noqtn "$ZIP_ROOT/Nura.app" "$ZIP"

if [ "$PUBLISH" = "1" ]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    spctl -a -vv --type open "$DMG"
    ZIP_CHECK="$STAGING/zip-check"
    mkdir -p "$ZIP_CHECK"
    ditto -x -k "$ZIP" "$ZIP_CHECK"
    codesign --verify --deep --strict --verbose=2 "$ZIP_CHECK/Nura.app"
fi

shasum -a 256 "$DMG" > "$DMG.sha256"
shasum -a 256 "$ZIP" > "$ZIP.sha256"
printf '%s\n' "$DMG" "$ZIP"
