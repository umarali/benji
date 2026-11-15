# Third-party notices

## Clicky (github.com/farzaa/clicky), MIT License

The companion adapts these ideas and small pieces from Clicky, an open-source macOS assistant
(checked at commit `e71105c`, 2026-10-28):

- the `[POINT:x,y:label]` answer tag format, kept for compatibility; Benji's parser is its own
  and also reads `[BOX:…]` and answers with several targets
  (`companion/Sources/BenjiCore/Drawing/Pointing.swift`, `benji/pointing.py`);
- streaming on-device speech recognition with a fallback to the latest partial result
  (`companion/Sources/BenjiApp/Voice/VoiceController.swift`);
- the idea of an event tap gated on Accessibility for a modifier-only talk key (ours is an
  active pass-through tap, because a listen-only tap needs Input Monitoring on macOS 26)
  (`companion/Sources/BenjiApp/Voice/ModifierTalkKey.swift`);
- the permission flow: system prompt once per launch, then System Settings, and a
  remembered Screen Recording grant (`companion/Sources/BenjiCore/Safety/PermissionPolicy.swift`,
  `companion/Sources/BenjiApp/App/Permissions.swift`);
- sending recent exchanges with each message as conversation history (`benji/history.py`).

No Clicky branding, artwork, sounds, colours or copy are used.

```
MIT License

Copyright (c) 2026 Farza

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Kalam (explanation cards' handwriting face), SIL Open Font License 1.1

`companion/Resources/Fonts/Kalam-Regular.ttf` and `Kalam-Bold.ttf`, unmodified, from
github.com/google/fonts (`ofl/kalam/`), bundled in Benji.app for the words on explanation
cards. Copyright (c) 2014 Indian Type Foundry
(info@indiantypefoundry.com). The full licence ships beside the fonts as
`companion/Resources/Fonts/OFL.txt` and in the app's `Contents/Resources/Fonts/OFL.txt`.
SHA-256: Regular `57cecb63d4608019371954274ae1d8c397764debd5b19d4a33c1efa4dc923c0b`,
Bold `2f6576601db015d4f6c08678120277fc8510b98c06e932ce7a6a9cbff4cbdded`.

## Kokoro on-device voice (optional, not bundled)

`tools/voice-setup.sh` downloads these into the user's own data folder (`~/.benji`); none of them
is shipped in this repository or in Benji.app, and Benji's code talks to them only through
`python -m benji --tts` in that separate venv:

- Kokoro-82M weights by hexgrad (Apache-2.0), as converted to ONNX in the kokoro-onnx
  release `model-files-v1.0`;
- kokoro-onnx (MIT), onnxruntime (MIT), numpy (BSD-3-Clause) and their helpers;
- phonemizer (GPL-3.0) and espeak-ng via espeakng-loader (GPL-3.0), used for phonemes.
