#!/usr/bin/env bash
# Offscreen renders of the settings page inside the open notch, one PNG per section, from a
# made-up snapshot (no app, no window, no permissions). Usage: tools/settings-render/render.sh <output dir>
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${1:?usage: render.sh <output dir>}"
mkdir -p "$OUT"

xcrun swift build --target BenjiCore >/dev/null
BIN="$(xcrun swift build --show-bin-path)"
xcrun swiftc -O -module-name SettingsRender \
    -I "$BIN/Modules" \
    tools/settings-render/main.swift Sources/BenjiApp/SettingsView.swift Sources/BenjiApp/MemorySettingsView.swift Sources/BenjiApp/NotchStyle.swift \
    "$BIN"/BenjiCore.build/*.o \
    -o "$OUT/settings-render"
"$OUT/settings-render" "$OUT"
rm -f "$OUT/settings-render"
