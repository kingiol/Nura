#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
APP="$("$ROOT/scripts/build-macos-app.sh")"
NURA_MPV_LIBRARY="$("$ROOT/scripts/check-mpv.sh")" open "$APP"
