#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
DERIVED_DATA="$ROOT/build/NuraXcodeDebug"
xcodebuild \
  -project "$ROOT/macos/NuraMac/NuraMac.xcodeproj" \
  -scheme NuraMac \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build >/dev/null

APP="$DERIVED_DATA/Build/Products/Debug/Nura.app"
export NURA_MPV_LIBRARY="$("$ROOT/scripts/check-mpv.sh")"
exec "$APP/Contents/MacOS/Nura"
