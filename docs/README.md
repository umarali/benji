# Benji docs

This folder holds the parts of the project's working documents that are useful to people who
read or change the code. (The maintainer's day-to-day notes, usage figures and design
explorations are not part of this repository.)

| File | What it is |
|---|---|
| [design-system/](design-system/) | The design system: name and wordmark, the Exchange icon, colour and type tokens, the notch object, motion, sound and the pointing overlay. |
| [decisions.md](decisions.md) | The decision log: what was decided, why, and what was turned down. A trimmed copy: entries that refer to private working material are left out and ids are not renumbered. |
| [proposal-serve.md](proposal-serve.md) | The protocol of `benji --serve`, the JSON-lines interface the app talks to. |
| [providers.md](providers.md) | The model providers: defaults, which models read images, addresses and regions, what each provider's documentation said and what has and has not been checked. |
| [RELEASING.md](RELEASING.md) | The owner's checklist for cutting a release: versioning, tagging, building, Developer ID signing and notarisation, release notes. |
| [ROADMAP.md](ROADMAP.md) | Where the project may go. Intentions, not promises. |

The [demo kit](../demo/README.md) explains how to record a real demo safely, in a separate macOS account.

For what Benji is, how to build it and what is verified, start with the top-level
[README](../README.md); the original design brief is [SPEC.md](../SPEC.md).
