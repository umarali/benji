#!/usr/bin/env bash
# Offscreen renders of figure blocks in Benji's card (D-108): no window, no permissions, no API.
# Usage: tools/figure-render/render.sh <output dir> [replies dir] [name ...]
# (default: tools/figure-render/replies and its hand-written airliner, house, jet engine, prompt example)
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${1:?usage: render.sh <output dir>}"
mkdir -p "$OUT"

xcrun swift build --target BenjiCore >/dev/null
BIN="$(xcrun swift build --show-bin-path)"
xcrun swiftc -O -module-name FigureRender \
    -I "$BIN/Modules" \
    tools/figure-render/main.swift tools/shared/SyntheticScreen.swift \
    Sources/BenjiApp/FigureStage.swift Sources/BenjiApp/FigureStageDrawing.swift Sources/BenjiApp/FigureReality.swift \
    "$BIN"/BenjiCore.build/*.o \
    -o "$OUT/figure-render"
REPLIES="${2:-tools/figure-render/replies}"
shift $(( $# < 2 ? $# : 2 ))
"$OUT/figure-render" "$OUT" "$REPLIES" "$@"
rm -f "$OUT/figure-render"
