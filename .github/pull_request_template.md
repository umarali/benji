## What changed

<!-- One change per pull request. What, and why. Link the issue if there is one. -->

## How it was tested

<!-- Tick what you ran, and say what you could NOT check (a real microphone, a permission prompt, a live model, a real Chrome profile). -->

- [ ] `python3 tools/isolated_run.py -- python3 selftest.py`
- [ ] `python3 tools/isolated_run.py -- sh -c 'cd companion && xcrun swift test'` (not plain `swift`)
- [ ] `node --test browser-extension/test/*.test.mjs` (if the extension changed)
- [ ] `python3 -I companion/ServeCheck/run.py` (if the app/engine protocol changed)
- [ ] New or changed behaviour has a test; UI or browser-driven checks are **headless**
- Not checked, and why:

## Safety and privacy check

- [ ] No message text, page text, file contents, addresses or keys are written to any log (`events.jsonl`, `engine.log`, stderr); new log fields are added to the closed schema, not as free text.
- [ ] No API key, token, `.benji.env` or personal data in the diff, fixtures or screenshots (fake keys are obviously fake).
- [ ] The approval gate asks no *less* than before, or this pull request says exactly what is now unasked and why, with a test showing what still asks.
- [ ] No new network destination, permission or Chrome extension permission, or it is called out here.
- [ ] No third-party Python dependency; no code, assets or copy taken from another application.

## Notes for the reviewer

<!-- Anything surprising, follow-ups, screenshots of the app (of fake content only). -->
