# Offline arm64 distribution candidate

This is an offline arm64 distribution candidate. It is not a notarised download or a release-ready app. The first target is Apple silicon, macOS 14 or later. Developer ID signing, hardened-runtime validation, notarisation, Gatekeeper, App Translocation and a clean-Mac test remain owner acceptance work. The app is never opened by this build.

## Build from pinned cache files

A build machine needs full Xcode, a Python with `tarfile.data_filter` and `hashlib.file_digest`, and the `zstd` command. Ordinary source builds retain their existing prerequisites and `./build.sh` path. The offline distribution builder does not download anything, run pip, discover signing identities or invoke account services.

Provision the two public files named in `companion/distribution/runtime.lock.json` before building. Verify their SHA-256 values against that reviewed lock. The builder repeats the digest checks before extraction or compilation. Runtime metadata must also match the pinned Python version, target triple and interpreter path. Digest comparison checks integrity against the pinned value; it does not independently authenticate the publisher or its build process. Upstream provenance is the Astral PBS release and its GitHub asset metadata identified by the lock.

From the repository root, using an output directory that does not yet exist:

```sh
python3 tools/isolated_run.py -- sh -c 'cd companion && ./build.sh distribution \
  --runtime-archive /tmp/runtime-cache/cpython-full.tar.zst \
  --ca-bundle /tmp/runtime-cache/cacert.pem \
  --output /tmp/benji-distribution \
  --source-commit YOUR_REVIEWED_BASE_COMMIT \
  --identity -'
```

`--source-commit` records the caller-claimed reviewed source base, not proof of that base. The manifest also records the actual Git HEAD and dirty flag when built in a checkout, or explicitly marks exported source with unknown Git identity. The manifest separately records a digest of the actual source/build inputs, with a file-level map beside the build. Local changes must still be reviewed. No runtime binaries are checked into the repository. Preserve the exact pinned upstream archive and notices with release source records.

## Runtime and launch contract

Distribution Swift compilation passes `--arch arm64 -Xswiftc -DBENJI_DISTRIBUTION`. This constant selects the distribution behavior even if a resource marker is removed. A missing or damaged runtime manifest fails closed. It never falls back to a checkout or a Python on PATH, and `BENJI_DIR` and Python environment overrides cannot select engine code.

The PBS install prefix, excluding only the unused static libpython archive and its alias, stays inside `Contents/Frameworks/BenjiPython.framework/Versions/A`. The framework principal executable is a regular `BenjiPython` file at that location; `bin/python3.12` is a relative alias. Making the principal executable itself a symlink fails local codesign validation. The builder inventories every shipped Mach-O, enforces arm64 and a minimum OS no newer than macOS 14, checks load paths, signs inside out with the explicit ad-hoc identity and runs strict verification. Its inventory records hashes before and after signing. This is local ad-hoc evidence only.

The engine, skills and Chromium extension live together under `Contents/Resources/engine`. The shared launch description covers the engine service, provider information, model setup, diagnostics, transcription, phone listener and native messaging. Distribution processes use an absolute interpreter and bootstrap with `-I -B -u`. The bootstrap accepts a closed set of entry points and adds only its exact engine root. No process writes Python caches into the bundle through those entry points. Do not run the bundled interpreter without `-B`: writing bytecode caches changes signed files and can make later validation fail. Swift checks the manifest, critical file identities and bootstrap hash; the child bootstrap streams the full listed-file check once before dispatch, including native-host and optional TTS. Only successful Swift checks are cached within the app process, invalidated by bundle location, manifest bytes or critical file metadata. Every bootstrap process checks all listed files anew. These corruption checks do not reject extra unlisted files or authenticate a maliciously modified app; release signing remains required.

The distribution tool PATH is `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`. User shell files are not sourced. Put engine configuration in `~/.benji.env` or configure model keys through the app Keychain setup; shell-only exports do not reach a Dock launch. This can find tools installed in the standard Homebrew locations, but does not promise tools installed in arbitrary user shell paths. Source mode retains login-shell Python selection and source-location overrides.

Optional Kokoro remains in its separately managed voice environment. Its interpreter runs the same bundled bootstrap to import the engine, while keeping access to its own installed voice dependencies. Those dependencies and voice model files are not bundled or newly installed by this builder. Tests without them must report the existing unavailable/error behavior, not pretend synthesis was exercised.

## Known launch cost

Every bundled child validates the listed files before dispatch, including each transcription process. In the earlier corrected offline candidate, five warm-filesystem `engine --version` samples had a median of 945.8 ms and a range of 871.5 to 950.5 ms on macOS 26.6.2 arm64 with PBS Python 3.12.16. These are headless launch measurements, not push-to-talk or first-answer timing, and do not compare against source mode. Cold-cache cost is unmeasured. Source mode does not run this bundle validation. Measure the first real push-to-talk utterance during owner acceptance before release.

## Browser registration and replacement

Browser opt-in remains explicit. Ownership is determined from the exact expected native manifest fields. Currentness also requires the launcher bytes for this bundle. Startup repairs only existing owned opt-ins after a move. Repair never creates another browser opt-in or changes a site's grant. Foreign manifests and launchers are not overwritten; uninstall removes only owned registrations. Re-register from Settings if a connection needs repair.

Distribution registration refuses read-only volumes, `/Volumes` locations and App Translocation paths. Move the app into Applications first. This conservative policy also excludes writable external volume installations. Quarantine and real translocation behavior have not been tested by the offline checks.

Replace the app as a unit. User data and the optional voice environment remain outside it. Deleting user data is a separate action and is not performed by the builder or bundle replacement. A running engine must be stopped by the user before replacing the app. Signing invalidates any file changes after assembly, so do not patch files inside an installed app.

## HTTPS trust

The pinned Mozilla CA data extracted by curl is in `Contents/Resources/trust/cacert.pem`. The complete MPL 2.0 licence and attribution are in `Contents/Resources/Notices`, together with all PBS runtime/transitive notices and its `PYTHON.json`.

Every engine HTTPS path uses the shared in-process SSL context: provider JSON and streaming, web fetch and searches, and both transcription providers. Web fetch layers the shared trust context on the DNS-pinned transport, preserving its connection and redirect checks.

An explicit `BENJI_TLS_CA_FILE` environment variable inherited by the app can select an absolute, readable PEM CA file. For a Dock launch, completely quit Benji, run the following yourself in Terminal, then reopen Benji:

```sh
launchctl setenv BENJI_TLS_CA_FILE /absolute/path/to/your-combined-roots.pem
```

To restore bundled roots, quit Benji, run `launchctl unsetenv BENJI_TLS_CA_FILE`, then reopen it. This changes the current login session environment for subsequently launched apps; it does not edit shell files or persist across login sessions. The distribution app supplies its bundled default before `~/.benji.env` is loaded, so a CA line in that file cannot override the distribution default. Use the launch environment for this setting. Never set an empty value to reset it. An empty, missing or malformed selection fails closed. The selected roots replace the default roots for engine requests. Add required public roots to a private-root bundle when both are needed. There is no settings UI or automatic macOS Keychain trust import in this candidate. Direct source mode without this variable keeps its existing trust behavior.

The app and bootstrap do not set `SSL_CERT_FILE` or `SSL_CERT_DIR`. `gate.tool_env()` removes the engine CA variable before tool processes run, so the engine's trust choice is not injected into curl, git or other tools. Existing caller-supplied tool trust variables are not rewritten.

A local untrusted certificate must fail against the shipped default bundle. A disposable test CA may pass through an explicit override. The shipped CA bytes must match the lock. Those checks do not prove default public HTTPS on a clean Mac. The owner still needs that harmless public-endpoint test, then an explicitly authorised provider answer with their own key.

## Acceptance still required

Owner acceptance covers Developer ID and hardened runtime, notarisation and stapling, Gatekeeper and quarantine, app movement/replacement on a clean Mac, permission onboarding, actual transcription and optional voice hardware, and a provider answer. Intel is not supported by this candidate.

## Headless launch probe

The external distribution probe source is retained in `companion/distribution/probe/main.swift`. It never opens the app. Compile it from the repository root inside the isolated wrapper:

```sh
python3 tools/isolated_run.py -- xcrun swiftc -O -DBENJI_DISTRIBUTION \
  companion/Sources/BenjiCore/Engine/EngineLaunch.swift \
  companion/Sources/BenjiCore/Engine/AssistantLocator.swift \
  companion/Sources/BenjiCore/Jobs/Browser.swift \
  companion/distribution/probe/main.swift -o /tmp/benji-distribution-probe
```

`describe BUNDLE ENTRY [ARGS...]` describes a launch. `launch BUNDLE ENTRY [ARGS...]` executes that headless engine entry. `cache-check BUNDLE` temporarily damages and restores bootstrap, runtime location and manifest bytes to check cache invalidation. Run that mode only against a disposable candidate copy, never an installed app. `register`, `current`, `owned`, `repair` and `unregister` accept `BUNDLE DISPOSABLE_HOME` and exercise browser registration without a browser. `DISTRIBUTION_PROBE_OPTIONAL_PYTHON` selects the separate interpreter only for optional TTS checks. Never supply real keys to the probe or publish its environment output. Omit `-DBENJI_DISTRIBUTION` to compile the source-mode identity probe.
