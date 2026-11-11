#!/bin/bash
# Build (Debug) and render the snapshots.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate >/dev/null
~/.claude/bin/safe-run.sh -C "$PWD" --allow-read /Users/gmecocci/projects/etude/mac/vendor -- xcodebuild -scheme ChessLens -configuration Debug -derivedDataPath build/dd build CODE_SIGN_IDENTITY=- 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | sort -u
scripts/render-snapshots.sh "${1:-build/shots}" | tail -3
