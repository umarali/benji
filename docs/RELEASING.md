# Releasing Benji

For the owner. **Nothing here has been run.** A release needs an Apple Developer ID certificate and
an Apple ID, which a coding session cannot and should not use. Every command marked **(owner)** signs,
uploads or publishes something and is yours to run on your own Mac. Replace `<…>` placeholders; keep
passwords and the app-specific password out of shell history, scripts and the repository.

## Versioning

Semantic versioning, `MAJOR.MINOR.PATCH`, while pre-1.0 meaning: `0.MINOR.0` may change behaviour and
the `--serve` protocol; `0.x.PATCH` is fixes only. A new permission, a new Chrome extension
permission, or a gate rule that asks *less* is at least a MINOR and is named in the changelog.

The version lives in **one place that the build reads**: `VERSION` in `companion/build.sh` (today
`0.1.0`), which becomes `CFBundleShortVersionString` and `CFBundleVersion`. The extension has its own
`version` in `browser-extension/manifest.json`; move it only when the extension changes. For a notarised
build, make `CFBundleVersion` a number that goes up on every build (Apple and Sparkle-style updaters
compare it); until then it equals the short version.

## Checklist

### 1. Before tagging

- [ ] Working tree clean on the release commit; `CHANGELOG.md` has a dated section for the version
  (format below) and an empty `Unreleased` section above it.
- [ ] `python3 selftest.py` passes.
- [ ] `(cd companion && xcrun swift test)` passes (use `xcrun swift`, not plain `swift`).
- [ ] `python3 -I companion/ServeCheck/run.py` passes.
- [ ] `node --test browser-extension/test/core.test.mjs browser-extension/test/page-text.test.mjs` passes.
- [ ] CI is green on the release commit on GitHub.
- [ ] In the maintainer's private repository, the export tool run on the release commit with
  `--require-filled` passes. (The tool is not in the public repository. Skip this if you publish ordinary history.)
- [ ] `SECURITY.md` and `CODE_OF_CONDUCT.md` have a real contact and no placeholder is left
  (the export tool's `--require-filled` run above passes).
- [ ] Live checks owed for any feature the release notes call more than "experimental" are done and
  written down (the maintainer's readiness notes list them under "Live verification still owed"). Do not upgrade a label in
  the README's status table without one.
- [ ] README status table, `docs/providers.md` and the changelog agree with each other.

### 2. Tag

```bash
git switch main && git pull --ff-only                  # (owner)
git tag -a v0.1.0 -m "Benji 0.1.0"                   # (owner)  annotated; sign it with -s if you have a GPG/SSH signing key
git push origin v0.1.0                                # (owner)  publishes the tag
```

### 3. Build

```bash
cd companion && ./build.sh                             # (owner)
```

For a distributable build the local self-signed certificate is not enough: sign with the Developer ID
below. `build.sh` signs with `BENJI_SIGN_IDENTITY` if set, but it uses plain `codesign --force`. A
notarised app needs the **hardened runtime** and a secure timestamp, so re-sign after the build as in step 4.

Check what you built before signing for release:

```bash
plutil -lint Benji.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Benji.app/Contents/Info.plist
```

### 4. Developer ID signing (owner)

Prerequisite: an Apple Developer Program membership and a **Developer ID Application** certificate in your
login keychain. List it:

```bash
security find-identity -v -p codesigning               # (owner)  look for "Developer ID Application: <Your Name> (<TEAMID>)"
```

Sign the app with the hardened runtime and a secure timestamp. Benji runs a Python engine as a child
process and a native-messaging relay; they are scripts inside the repo, not signed binaries in the
bundle, so there are no nested binaries to sign separately today. If that changes, sign inside-out.

```bash
codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: <Your Name> (<TEAMID>)" companion/Benji.app     # (owner)
codesign --verify --strict --verbose=2 companion/Benji.app                          # (owner)
```

Open points the first release must settle (not decided here):

- **Entitlements.** The hardened runtime blocks some things unless entitled. Benji uses the microphone,
  Apple Events (AppleScript) and records the screen. Microphone and Apple Events need
  `com.apple.security.device.audio-input` and `com.apple.security.automation.apple-events` under the
  hardened runtime. Screen Recording is a TCC permission and needs no entitlement. Write an entitlements
  file, sign with `--entitlements`, and test each permission on the signed build.
- **Where the engine lives.** The app finds the `benji` package next to the bundle (or from
  `BENJI_DIR`). A downloaded app has no repo beside it, so a distributable build must either bundle the
  `benji/` folder inside `Benji.app/Contents/Resources` (and `AssistantLocator` must look there) or
  document a separate install. This is not built yet and is the largest piece of work before a download
  exists. Python itself is not bundled: the engine uses the system `python3` (the Xcode command-line
  tools provide one).

### 5. Notarise (owner)

One-time: store credentials in the keychain so no password appears on the command line. Use an
**app-specific password** from your Apple ID account page, not your Apple ID password.

```bash
xcrun notarytool store-credentials "benji-notary" \
  --apple-id "<your Apple ID email>" --team-id "<TEAMID>"                            # (owner)  prompts for the app-specific password
```

Zip the app (`ditto` keeps the signature), submit, wait:

```bash
ditto -c -k --keepParent companion/Benji.app Benji-0.1.0.zip                       # (owner)
xcrun notarytool submit Benji-0.1.0.zip --keychain-profile "benji-notary" --wait   # (owner)
```

If the status is not `Accepted`, read the log (the submission id is printed above):

```bash
xcrun notarytool log <submission-id> --keychain-profile "benji-notary"              # (owner)
```

Staple the ticket to the app and re-check what Gatekeeper will think:

```bash
xcrun stapler staple companion/Benji.app                                            # (owner)
xcrun stapler validate companion/Benji.app                                          # (owner)
spctl --assess --type execute --verbose=4 companion/Benji.app                      # (owner)  expect: accepted, source=Notarized Developer ID
```

### 6. Package and publish (owner)

Re-zip the **stapled** app (the earlier zip has no ticket) and compute a checksum:

```bash
ditto -c -k --keepParent companion/Benji.app Benji-0.1.0.zip                       # (owner)
shasum -a 256 Benji-0.1.0.zip                                                       # (owner)
```

On GitHub (owner): create a release from the tag, paste the release notes (below), attach the zip and put
the SHA-256 in the notes. Test the download once: fetch it with a browser on a Mac that has never seen
the app, open it, and confirm there is no Gatekeeper block and that the permission prompts attach to the app.

### 7. After

- [ ] Move `Unreleased` items in `CHANGELOG.md` under the new version if not already done; start a fresh `Unreleased`.
- [ ] Bump `VERSION` in `companion/build.sh` to the next development version in a separate commit.
- [ ] Add the release to the README only if install instructions changed (for example, a download link replaces "Build from source").

## Release notes format

Same sections as the changelog entry (Keep a Changelog: Added, Changed, Deprecated, Removed, Fixed,
Security). Put these first, plainly, because they decide whether someone should install it:

1. **One-line summary** and the date.
2. **Status of each headline feature** using the README's three labels (stable, experimental, not
   live-tested). Never raise a label in the release notes without the live check behind it.
3. **What this build asks of the user**: macOS version, permissions, anything that changed since the
   last version (a new permission, a changed default, a gate rule that now asks less).
4. **Known issues** and what is not live-tested.
5. **Verification**: the SHA-256 of the download, and "notarised and stapled" only if `spctl` said so.
6. **Upgrade notes**: working-folder format changes, `defaults` keys, extension re-approval (Chrome
   disables an extension whose permissions grow).

## What cannot be done by a session

Obtaining or using the Developer ID certificate and the app-specific password, running `notarytool`,
pushing a tag, creating the GitHub release, and the live checks a release must not skip.
