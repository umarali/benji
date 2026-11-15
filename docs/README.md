# Benji docs

New here? Start with [Set up Benji on your Mac](setup.md). It covers the source build,
your first typed message and permissions you can add later.

This folder holds the parts of the project's working documents that are useful to people who
read or change the code. (The maintainer's day-to-day notes, usage figures and design
explorations are not part of this repository.)

| File | What it is |
|---|---|
| [setup.md](setup.md) | Step-by-step Mac setup, an offline check, a first message and troubleshooting. |
| [status.md](status.md) | Feature status: what has been tried live and what has only been tested offline. |
| [configuration.md](configuration.md) | Using and configuring Benji: features in detail, settings, choosing a model provider, command-line voice, skills and memory. |
| [safety.md](safety.md) | The safety model, background jobs and browser reach. |
| [privacy.md](privacy.md) | What leaves your Mac, where it goes, and what Benji keeps locally. |
| [building.md](building.md) | Requirements, building and signing `Benji.app`, its permissions, the offline checks and the repository layout. |
| [design-system/](design-system/) | The design system: name and wordmark, the Exchange icon, colour and type tokens, the notch object, motion, sound and the pointing overlay. |
| [decisions.md](decisions.md) | The decision log: what was decided, why, and what was turned down. A trimmed copy: entries that refer to private working material are left out and ids are not renumbered. |
| [proposal-serve.md](proposal-serve.md) | The protocol of `benji --serve`, the JSON-lines interface the app talks to. |
| [providers.md](providers.md) | The model providers: defaults, which models read images, addresses and regions, what each provider's documentation said and what has and has not been checked. |
| [RELEASING.md](RELEASING.md) | The owner's checklist for cutting a release: versioning, tagging, building, Developer ID signing and notarisation, release notes. |
| [ROADMAP.md](ROADMAP.md) | Where the project may go. Intentions, not promises. |
| [benji-rename.md](benji-rename.md) | The move to the Benji name: the identifiers, what moves on first launch and what was tested. |
| [impl-notes/](impl-notes/) | Records of the 3D-figure evaluations: what was asked and what each model drew. |
| [design-work/](design-work/) | Source files for the app icon and menu-bar glyph. |

The [demo kit](../demo/README.md) explains how to record a real demo safely, in a separate macOS account.

For what Benji is, start with the top-level [README](../README.md); the original design brief is
[SPEC.md](../SPEC.md).
