#!/usr/bin/env bash
# Offscreen renders of the setup window (current step, the Accessibility helper, the model step), the
# bar on another display, the panel visiting a display without a notch, the notch's arrow and the
# pointer companion, each at 1x and 2x. Injected states only: a fake backend and a fake probe; no
# engine, no permission API, no screen capture, no real settings. Usage: render.sh <output dir>
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${1:?usage: render.sh <output dir>}"
mkdir -p "$OUT"

xcrun swift build --target BenjiCore >/dev/null
BIN="$(xcrun swift build --show-bin-path)"
APP=$(find Sources/BenjiApp -name '*.swift' ! -name main.swift | sort)
xcrun swiftc -O -module-name DisplaySetupRender \
    -I "$BIN/Modules" \
    tools/display-setup-render/main.swift $APP \
    "$BIN"/BenjiCore.build/*.o \
    -o "$OUT/display-setup-render"
"$OUT/display-setup-render" "$OUT"
rm -f "$OUT/display-setup-render"
