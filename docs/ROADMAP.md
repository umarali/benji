# Roadmap

**These are intentions, not promises.** Benji is a small project with one maintainer, no schedule and
no commitments to anyone. Order can change, and anything here can be dropped. Safety work comes before
features: a feature that makes Benji act on your behalf is not added until the rules for it are in code
and tested.

## Next

1. **Live verification of what is already built.** The honest label of most recent features is
   "experimental" or "not live-tested". Closing that comes before adding to them: quit mid-job and a long
   wait for jobs; the browser in a real Chrome profile; a real run of each open-model provider with the
   owner's own key (`tools/model_smoke.py`). The [status table](status.md) only
   changes when one of these has been done and written down.
2. **Browser acting in a real browser.** Clicking, typing, keys and uploads are built and tested
   offline and in headless Chrome, but not yet used in a real browser profile.
3. **Notarised builds.** A Developer ID signed, notarised and stapled `Benji.app` on GitHub Releases, so
   you do not have to build from source. This needs the engine bundled inside the app and an entitlements
   file. The owner's checklist is [RELEASING.md](RELEASING.md).

## Later, maybe

- A Web Store build of the extension, and trying Arc, Brave and Edge for real.
- Resuming a parked job after a restart; more than one job at a time.
- Jobs for hands-free (voice-only) turns, once the approval path for them is settled.
- A Settings switch for the audit log (today only `BENJI_AUDIT=0`).

## Not planned

- **Windows or Linux apps.** The notch app is macOS-only (AppKit, SwiftUI, Apple's on-device speech). The
  engine is plain Python, but it is tested on macOS only and a port of the app is not planned.
- **A hosted service, accounts or telemetry.** Benji talks to the model provider you choose and nothing
  else of its own.
- **Acting without asking where it matters.** No "approve everything" mode beyond the existing `--yes`
  for the command line, and no way for a web page or a model to widen its own access.

Ideas are welcome as [issues](https://github.com/umarali/benji/issues); see [CONTRIBUTING.md](../.github/CONTRIBUTING.md).
