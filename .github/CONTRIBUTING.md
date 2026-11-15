# Contributing to Benji

Thanks for looking. Benji is a small project with one maintainer, so the process is light.

## Ground rules

- **Original work only.** Do not paste in code, assets, prompts or copy from other
  applications, including ones you have taken apart or whose licence does not clearly allow
  it. Ideas credited from open-source projects go in
  [THIRD_PARTY_NOTICES.md](../docs/THIRD_PARTY_NOTICES.md).
- **Your contribution is licensed under the MIT licence** of this repository.
- **No secrets, ever.** Never commit `.benji.env`, API keys, tokens or personal data. Test
  fixtures that look like keys must be obviously fake.
- **Safety is a feature.** Changes that loosen the approval gate (`benji/gate.py`,
  `benji/tools/approval.py`, `companion/Sources/BenjiCore/Safety/ApprovalPolicy.swift`) need a clear reason
  and a test that shows what is still asked.

## How to contribute

1. **Open an issue first** for anything bigger than a small fix, so we agree on the shape before you build it.
2. **Fork, then branch** from `main` (`fix-…` or `feature-…`; any clear name is fine).
3. **Make one change, with its tests** (see below).
4. **Run the checks** (below). They must pass.
5. **Open a pull request.** Say what you ran and what you could **not** check (for example, something that
   needs a real microphone, a permission prompt or a live model). CI runs the same checks.
6. **Review and merge.** The maintainer reviews every pull request and merges it as one squashed commit.

## Set up and checks

Requirements: macOS 14+ to run the app, Python 3.11+ for the engine, and Xcode 26+ for building
(on a Mac supported by that Xcode release). The Python engine has **no third-party dependencies**
and should stay that way (standard library only).

```bash
git clone https://github.com/<you>/benji.git && cd benji
python3 tools/isolated_run.py -- python3 tests/selftest.py                          # engine
python3 tools/isolated_run.py -- sh -c 'cd companion && xcrun swift test'     # app logic
```

`tools/isolated_run.py` runs a command with a throwaway home folder, so tests never touch your own Benji
data or keys. If you changed `browser-extension/`, also run
`node --test browser-extension/test/*.test.mjs`. No check calls a live model or needs an API key; if a
change needs a live call to verify, describe it in the pull request and keep it out of the tests.

## Writing tests

- Python: add a check to `tests/selftest.py` next to the closest existing one, using the offline fakes already
  there; no network calls.
- Swift: keep decision logic in `BenjiCore` (Foundation only, so it tests headlessly) with a test in
  `companion/Tests/BenjiCoreTests`. `BenjiApp` holds AppKit and SwiftUI glue.
- Run UI or browser checks **headless**; do not add tests that open visible windows.
- Match the surrounding code: its comment density, naming and idiom.

## Reporting a vulnerability

Do not open a public issue; see [SECURITY.md](SECURITY.md).
