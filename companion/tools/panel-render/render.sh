#!/usr/bin/env bash
# Offscreen renders of the notch panel in every state, from a fake backend (no engine, no mic,
# no screen capture, no permissions). Usage: tools/panel-render/render.sh <output dir>
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${1:?usage: render.sh <output dir>}"
mkdir -p "$OUT"

xcrun swift build --target BenjiCore >/dev/null
BIN="$(xcrun swift build --show-bin-path)"
APP=$(ls Sources/BenjiApp/*.swift | grep -v '/main.swift$')
xcrun swiftc -O -module-name PanelRender \
    -I "$BIN/Modules" \
    tools/panel-render/main.swift $APP \
    "$BIN"/BenjiCore.build/*.o \
    -o "$OUT/panel-render"
"$OUT/panel-render" "$OUT"
rm -f "$OUT/panel-render"
