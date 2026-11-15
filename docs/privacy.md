# Privacy

What leaves your Mac, where it goes, and what Benji keeps locally.

**In short:** Benji has no telemetry, no account and no hosted backend. It talks to the model
provider you configured, and to the websites and services a tool you use needs. Run
`python3 -m benji --print-provider` to see where your requests go, without making an API call.

## What the provider sees

With a hosted provider, these are sent to that company's servers, in the country the
[provider table](configuration.md#choosing-a-model-provider) names, under its terms:

- your messages;
- what the tools return: file text, web pages, command output, browser page text;
- screenshots, when Settings › Screen includes them (see [Your screen](#your-screen));
- the earlier exchanges of the same conversation, as text, so it can follow up: as many as fit in
  about 24,000 characters, and always the last 10. Earlier screenshots are not sent again.

The gate, taint rules and audit log work the same for every provider, but they cannot make a
hosted model forget what it was sent.

A model you run yourself (Ollama, LM Studio) keeps the model's work on your Mac. Web searches,
page fetches, browser reach and cloud transcription, when you use them, still contact other
services.

DeepSeek's own policy says personal data is stored in the People's Republic of China. Z.ai,
Moonshot and Alibaba Cloud name Singapore for their international platforms. The provider table
has the details.

## Your keys

- Keys come from the environment, from `~/.benji.env`, or from the macOS Keychain if you move
  them there in the app (Settings › General › Move to the Keychain). The move copies the key,
  checks it, and then takes it out of `~/.benji.env`. The app hands Keychain keys to its engine
  through the engine's environment.
- Benji never writes a key to a log.
- A provider's key is sent only to that provider's own host. A different `BENJI_BASE_URL` needs
  its own `BENJI_API_KEY`.
- Hosted providers need `https://`. Plain `http://` is accepted for a model on your own computer,
  and for a custom server on a private network address or a `.local` or `.ts.net` host, which
  may be another computer.

## What stays on your Mac

Everything below lives in one hidden folder, `~/.benji` by default (`BENJI_WORKDIR` changes it).
Settings › "Show Benji's folder" opens it. Log files are written readable by you only.

| File | What it holds |
|---|---|
| `memory.jsonl` | Durable facts Benji was told to remember (never secrets) |
| `usage.jsonl` | Token counts only |
| `conversations/` | Your saved conversations with Benji |
| `answers.jsonl` | The model's raw answers and the events of each turn. On by default; `BENJI_ANSWER_LOG=0` turns it off |
| job folders | Each background job's report and output |
| `events.jsonl` | The audit log: metadata only |
| `engine.log` | The engine's own log |

The key file `~/.benji.env` and the browser link's private folder are outside this folder.

## Your screen

Settings › Screen decides when a screenshot goes with a message:

| Mode | What happens |
|---|---|
| **Off** | Never. |
| **Ask** | Before each message, a card asks whether to include the screen. |
| **On** | A screenshot goes with every message. New installs start here. |

Each capture is one screenshot of the display you are working on, with Benji's own windows left
out, downscaled and sent with that one message. There is no continuous recording. When you let
Benji act on the screen, it takes a fresh screenshot after each step. You see a thumbnail of
what was sent. A model that cannot read images is never sent one.

## Your voice

By default, speech is turned into text on your Mac, with Apple's on-device recognition. Opening
the panel starts listening, and listening can continue after the panel closes; Settings › Voice
has "Listen while Benji is open" and "Keep listening when the panel closes" to turn either off.

Cloud transcription is used only if you choose it: the command-line `--voice`, `--listen` and
`--transcribe`, or the app's `pttTranscriber` setting set to `engine`.
