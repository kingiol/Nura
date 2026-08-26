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
printf '%s\n' "$APP"
