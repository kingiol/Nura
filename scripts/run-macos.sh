#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
APP="$("$ROOT/scripts/build-macos-app.sh")"
open "$APP"
