#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
FIXTURE="${NURA_E2E_MEDIA_PATH:-$ROOT/test-fixtures/media/oceans.mp4}"

if [ ! -f "$FIXTURE" ]; then
    printf '%s\n' "E2E media fixture was not found: $FIXTURE" >&2
    exit 1
fi

export NURA_E2E_MEDIA_PATH="$FIXTURE"
export NURA_MPV_LIBRARY="$("$ROOT/scripts/check-mpv.sh")"

xcodebuild test \
  -project "$ROOT/macos/NuraMac/NuraMac.xcodeproj" \
  -scheme NuraMac \
  -derivedDataPath "$ROOT/build/NuraE2EDerivedData" \
  -destination 'platform=macOS,arch=arm64'
