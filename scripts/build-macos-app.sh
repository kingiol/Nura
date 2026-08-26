#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cargo build -p nura-ffi --release

DERIVED_DATA="$ROOT/build/NuraDerivedData"
xcodebuild \
  -project "$ROOT/macos/NuraMac/NuraMac.xcodeproj" \
  -scheme NuraMac \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build >/dev/null

APP="$ROOT/build/Nura.app"
rm -rf "$APP"
cp -R "$DERIVED_DATA/Build/Products/Release/Nura.app" "$APP"

YTDL_PATH="$($ROOT/scripts/check-ytdlp.sh --standalone)"
mkdir -p "$APP/Contents/Resources/bin"
cp "$YTDL_PATH" "$APP/Contents/Resources/bin/yt-dlp"
chmod 755 "$APP/Contents/Resources/bin/yt-dlp"
printf '%s\n' "$APP"
