#!/usr/bin/env bash
# Offscreen renders of the pointer overlay over a synthetic screen (no screen capture, no
# window, no permissions). Usage: tools/overlay-render/render.sh <output dir> [drawing]
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${1:?usage: render.sh <output dir>}"
mkdir -p "$OUT"

xcrun swift build --target BenjiCore >/dev/null
BIN="$(xcrun swift build --show-bin-path)"
xcrun swiftc -O -module-name OverlayRender \
    -I "$BIN/Modules" \
    tools/overlay-render/main.swift tools/shared/SyntheticScreen.swift Sources/BenjiApp/OverlayViews.swift \
    "$BIN"/BenjiCore.build/*.o \
    -o "$OUT/overlay-render"
"$OUT/overlay-render" "$OUT" "${2:-}"
rm -f "$OUT/overlay-render"
