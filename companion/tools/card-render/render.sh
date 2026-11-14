#!/usr/bin/env bash
# Offscreen renders of explanation cards (D-125) on a synthetic page of text: no window, no
# permissions, no API. Usage: tools/card-render/render.sh <output dir> [replies dir]
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${1:?usage: render.sh <output dir>}"
mkdir -p "$OUT"

xcrun swift build --target BenjiCore >/dev/null
BIN="$(xcrun swift build --show-bin-path)"
xcrun swiftc -O -module-name CardRender \
    -I "$BIN/Modules" \
    tools/card-render/main.swift Sources/BenjiApp/ExplainCardDrawing.swift \
    "$BIN"/BenjiCore.build/*.o \
    -o "$OUT/card-render"
"$OUT/card-render" "$OUT" "${2:-tools/card-render/replies}" "Resources/Fonts"
rm -f "$OUT/card-render"
