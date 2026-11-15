# Privacy

What leaves your Mac, where it goes, and what Benji keeps locally.

**In short:** Benji has no telemetry, no account and no hosted backend. It talks to the model
provider you configured and to nothing else of its own. Run `python3 -m benji --print-provider`
to see where your data goes, without making an API call.

## What the provider sees

With a hosted provider, these are sent to that company's servers, in the country the
[provider table](configuration.md#choosing-a-model-provider) names, under its terms:

- your messages;
- what the tools return: file text, web pages, command output, browser page text;
- the screenshot, when Screen is on.

The gate, taint rules and audit log work the same for every provider, but they cannot make a
hosted model forget what it was sent. **Only a model you run yourself** (Ollama, LM Studio) keeps
everything on your Mac.

DeepSeek's own policy says personal data is stored in the People's Republic of China. Z.ai,
Moonshot and Alibaba Cloud name Singapore for their international platforms. The provider table
has the details.

## Your keys

- Keys are read from the environment or `.benji.env` files. Benji never logs them or writes them
  to disk.
- A provider's key is sent only to that provider's own host. A different `BENJI_BASE_URL` needs
  its own `BENJI_API_KEY`.
- Plain `http://` is refused, except to your own computer.

## What stays on your Mac

Everything below lives in one hidden folder, `~/.benji` by default (the working folder), not in
loose folders. Settings › "Show Benji's folder" opens it. Log files are written readable by you only.

| File | What it holds |
|---|---|
| `memory.jsonl` | Durable facts Benji was told to remember (never secrets) |
| `usage.jsonl` | Token counts only |
| saved conversations | Your conversations with Benji |
| `answers.jsonl` | The model's raw answers: the one log that holds content |
| job folders | Each background job's report and output |
| `events.jsonl` | The audit log: metadata only |
| `engine.log` | The engine's own log |

An older `~/benji` is moved into `~/.benji` once, on the first start. If both exist, `~/.benji`
is used and nothing is merged. The key file `~/.benji.env` and the browser link's private folder
stay where they are.

## Your screen

One screenshot of the display the panel is on, with Benji's own windows left out, downscaled and
sent with the next message only. You see a thumbnail of exactly what was sent, and the file is
deleted after the reply. A model that cannot read images is never sent one.

## Your voice

Transcription happens on your Mac, with Apple's speech recognition. Cloud transcription exists
only for the optional command-line flags `--voice` and `--listen`.
