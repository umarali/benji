#!/usr/bin/env bash
# Build Benji.app (the notch app and its Python engine, `benji`).
# Usage: ./build.sh        then  open Benji.app
#        ./build.sh run    builds and launches it
set -e
cd "$(dirname "$0")"

APP="Benji.app"
BUNDLE_ID="com.emerssive.heybenji.app"
VERSION="0.1.0"

echo "• swift build (release)…"
xcrun swift build -c release
BIN="$(xcrun swift build -c release --show-bin-path)/BenjiApp"

echo "• assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Benji"
# App icon and menu-bar glyph, generated from docs/design-work/icon by ./make_icon.sh.
cp Resources/Assets.car Resources/AppIcon.icns Resources/MenuBarGlyph.svg Resources/MenuBarGlyphWorking.svg "$APP/Contents/Resources/"
# The explanation card's handwriting face, when bundled; the card falls back to Noteworthy.
if [ -d Resources/Fonts ]; then cp -R Resources/Fonts "$APP/Contents/Resources/"; fi
# Benji's own quiet cues, made by ../tools/make_cues.py; off until the user turns them on.
if [ -d Resources/Cues ]; then cp -R Resources/Cues "$APP/Contents/Resources/"; fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Benji</string>
    <key>CFBundleDisplayName</key><string>Benji</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>Benji</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>Benji listens through the microphone only while you hold the talk key, or while you have a hands-free conversation open. Your voice is turned into text on this Mac.</string>
    <key>NSAppleEventsUsageDescription</key><string>Benji runs AppleScript tasks you ask for, and controls an app only after you approve the task.</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>Benji transcribes what you say on this Mac (on-device) so it can act on your spoken request.</string>
</dict>
</plist>
PLIST

# Sign the bundle so macOS privacy permissions attach to it. With a stable identity,
# permissions survive rebuilds (macOS matches "this bundle id + this certificate");
# an ad-hoc signature changes every build, so every grant has to be redone.
# Default: a local "Benji Local Signing" certificate in the login keychain (self-signed, code signing
# only). A Mac that only has a certificate under an older name ("Chilly Local Signing") keeps using
# that one: another certificate would make macOS ask for every permission again. Override with
# BENJI_SIGN_IDENTITY, e.g. an "Apple Development: …" identity from
# `security find-identity -v -p codesigning`.
sign_bundle() {
SIGN_ID="${BENJI_SIGN_IDENTITY:-}"
if [ -z "$SIGN_ID" ]; then
    SIGN_ID="Benji Local Signing"
    if ! security find-certificate -c "$SIGN_ID" >/dev/null 2>&1 \
        && security find-certificate -c "Chilly Local Signing" >/dev/null 2>&1; then
        SIGN_ID="Chilly Local Signing"
    fi
fi
if [ "$SIGN_ID" = "-" ]; then
    codesign --force --sign - "$APP" >/dev/null 2>&1
    echo "• ad-hoc signed $APP (permissions will reset on each rebuild)"
    return
fi
if security find-certificate -c "$SIGN_ID" >/dev/null 2>&1; then
    codesign --force --sign "$SIGN_ID" "$APP" && echo "• signed $APP with \"$SIGN_ID\"" \
        || { echo "• codesign with \"$SIGN_ID\" failed"; exit 1; }
else
    echo "• \"$SIGN_ID\" not found; signing ad-hoc (permissions will reset on each rebuild)"
    codesign --force --sign - "$APP" >/dev/null 2>&1
    echo "• ad-hoc signed $APP"
fi
}
sign_bundle

echo "• done → $PWD/$APP"
echo "  run it:   open $APP"
echo "  then use Benji's menu-bar icon → “Show / Hide Benji”"

if [ "$1" = "run" ]; then
    killall Benji 2>/dev/null || true
    open "$APP"
    echo "  launched."
fi
