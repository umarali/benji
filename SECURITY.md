# Security policy

## Reporting a vulnerability

Please report security problems **privately**, not in a public issue or pull request.

Private contact: email **aliumar.me@gmail.com**, or use GitHub's
[Report a vulnerability](https://github.com/umarali/benji/security/advisories/new) on this repository.

Include what you found, how to reproduce it, and the version or commit. You will get an
acknowledgement from the maintainer; this is a one-person project, so please allow some days.
Please give a reasonable time to fix before disclosing publicly.

## What counts

Benji is an assistant that can run commands, read and write files and drive apps on your
Mac. Reports of interest include:

- a way around the approval gate (an action that should ask first running without asking);
- hostile text in a web page, file, screenshot or tool result steering Benji into doing
  something the user did not ask for (prompt injection that reaches an action);
- API keys or private content leaving the Mac somewhere other than the provider you chose;
- the app granting itself, or misusing, a macOS permission (microphone, screen recording,
  accessibility, automation).

## Known limits

Be aware of these before relying on Benji with anything sensitive:

- The approval gate is a best-effort, pattern-based safeguard and a prompt rule, not a
  sandbox. A determined hostile input may find a gap. Leave `--yes` off and read what you
  approve.
- Whatever you send to a model provider (your request, tool output, optional screenshots)
  is seen by that provider. Only a model you run yourself keeps data on your machine.
- Only the latest commit on the default branch is supported.
