#!/bin/bash
# Renders the README screenshots in docs/screenshots/ from made-up sample data, with the stock Ghost sprite and
# default settings. Nothing from your own sessions, alerts, chats or config.json ends up in them.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-docs/screenshots}"
mkdir -p build "$OUT"
swift build
swift tools/make_wolf.swift ghost build/ghost-sheet.png >/dev/null
.build/debug/IronPet --render-previews "$OUT" --sprite build/ghost-sheet.png
