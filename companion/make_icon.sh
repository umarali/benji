#!/usr/bin/env bash
# Regenerate Benji's committed icon resources from the design sources (D-137).
# Usage: ./make_icon.sh      (needs Xcode 26's actool; build.sh only copies the results)
#
#   Resources/Assets.car       benji.icon compiled by actool: the macOS 26 layered icon
#                              (light, dark, tinted, clear) plus flattened 16–1024 px renditions
#   Resources/AppIcon.icns     actool's legacy .icns (Apple's grid and small-size margins)
#   Resources/MenuBarGlyph.svg          the two elbows, the status item's idle template glyph
#   Resources/MenuBarGlyphWorking.svg   the halves closed, shown while Benji is busy with a turn
set -e
cd "$(dirname "$0")"

ICON_SRC="../docs/design-work/icon"
OUT="Resources"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# actool names the app icon after the .icon document, so compile a copy named AppIcon.
cp -R "$ICON_SRC/benji.icon" "$WORK/AppIcon.icon"
mkdir -p "$WORK/out" "$OUT"
xcrun actool "$WORK/AppIcon.icon" --compile "$WORK/out" \
    --platform macosx --minimum-deployment-target 14.0 \
    --app-icon AppIcon --include-all-app-icons \
    --output-partial-info-plist "$WORK/out/partial.plist" >/dev/null

cp "$WORK/out/Assets.car" "$WORK/out/AppIcon.icns" "$OUT/"
cp "$ICON_SRC/benji-menubar-glyph.svg" "$OUT/MenuBarGlyph.svg"
cp "$ICON_SRC/benji-menubar-glyph-working.svg" "$OUT/MenuBarGlyphWorking.svg"
echo "• wrote $OUT/Assets.car, $OUT/AppIcon.icns, $OUT/MenuBarGlyph.svg, $OUT/MenuBarGlyphWorking.svg"
