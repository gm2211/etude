#!/bin/bash
# Renders the video views to PNGs headlessly (no window, no Dock icon). Build the app first (Debug, derivedDataPath
# build/dd). The app is App-Sandboxed, which cannot nest inside safe-run's sandbox, so a copy is re-signed ad hoc
# WITHOUT entitlements (the snapshot mode reads and writes nothing of the user's) and run inside safe-run.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC=build/dd/Build/Products/Debug/Etude.app
APP=build/snap/Etude.app
OUT=${1:-build/shots}
rm -rf build/snap && mkdir -p build/snap "$OUT"
cp -R "$SRC" "$APP"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1
~/.claude/bin/safe-run.sh -C "$PWD" -- "$APP/Contents/MacOS/Etude" --render-snapshots "$OUT"
