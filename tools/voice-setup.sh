#!/usr/bin/env bash
# Install Kokoro, Benji's optional on-device voice (benji/tts.py). Speech then runs
# offline: answer text never leaves the Mac. Everything goes into the data folder:
#   ~/.benji/voice-venv   an isolated Python venv (packages pinned by hash in voice-requirements.txt)
#   ~/.benji/voices       the model and voices (pinned SHA-256 below)
# Usage: tools/voice-setup.sh [full|int8|both]   (default full: best quality, and faster on Apple CPUs)
# The only network use is these downloads, each pinned by exact URL and SHA-256 and verified:
# 17 wheels from files.pythonhosted.org (~47 MB, voice-requirements.txt) and, from
# github.com/thewh1teagle/kokoro-onnx release model-files-v1.0, the full model (325.5 MB),
# the int8 model (92.4 MB) and the voices (28.2 MB). After that Kokoro runs fully offline.
set -euo pipefail
cd "$(dirname "$0")"

WHICH="${1:-full}"
DATA="${BENJI_WORKDIR:-$HOME/.benji}"
VENV="$DATA/voice-venv"
VOICES="$DATA/voices"
BASE="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0"

# The release publishes no checksums; these are the files as first downloaded (2026-10-31).
sha_of() {
    case "$1" in
        kokoro-v1.0.onnx)      echo 7d5df8ecf7d4b1878015a32686053fd0eebe2bc377234608764cc0ef3636a6c5 ;;
        kokoro-v1.0.int8.onnx) echo 6e742170d309016e5891a994e1ce1559c702a2ccd0075e67ef7157974f6406cb ;;
        voices-v1.0.bin)       echo bca610b8308e8d99f32e6fe4197e7ec01679264efed0cac9140fe9c29f1fbf7d ;;
    esac
}

case "$WHICH" in
    full) FILES=(voices-v1.0.bin kokoro-v1.0.onnx) ;;
    int8) FILES=(voices-v1.0.bin kokoro-v1.0.int8.onnx) ;;
    both) FILES=(voices-v1.0.bin kokoro-v1.0.onnx kokoro-v1.0.int8.onnx) ;;
    *) echo "usage: $0 [full|int8|both]" >&2; exit 2 ;;
esac

# The pinned wheels are for CPython 3.12 (kokoro-onnx supports 3.10 to 3.13).
PY="$(command -v python3.12 || true)"
[ -n "$PY" ] || { echo "Needs Python 3.12 (e.g. brew install python@3.12)." >&2; exit 1; }

if [ ! -x "$VENV/bin/python3" ]; then
    echo "• creating $VENV with $PY"
    "$PY" -m venv "$VENV"
fi
echo "• installing pinned packages (hash-checked, wheels only)"
"$VENV/bin/python3" -m pip install --disable-pip-version-check -q \
    --require-hashes --only-binary :all: --no-deps -r voice-requirements.txt

mkdir -p "$VOICES"
for f in "${FILES[@]}"; do
    want="$(sha_of "$f")"
    if [ -f "$VOICES/$f" ] && [ "$(shasum -a 256 "$VOICES/$f" | cut -d' ' -f1)" = "$want" ]; then
        echo "• $f already present"
        continue
    fi
    echo "• downloading $f"
    curl -fL --proto '=https' --retry 2 -sS -o "$VOICES/$f.partial" "$BASE/$f"
    got="$(shasum -a 256 "$VOICES/$f.partial" | cut -d' ' -f1)"
    if [ "$got" != "$want" ]; then
        rm -f "$VOICES/$f.partial"
        echo "✗ $f checksum mismatch (got $got); not installed." >&2
        exit 1
    fi
    mv "$VOICES/$f.partial" "$VOICES/$f"
done

echo "• Kokoro is ready. Benji.app uses it for spoken answers on its next launch."
echo "  Voice: defaults write com.emerssive.heybenji.app kokoroVoice af_heart   (Apple voice: ttsEngine system)"
