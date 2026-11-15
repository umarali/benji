# Privacy

What leaves your Mac, where it goes, and what Benji keeps locally.

- **No telemetry, no account, no hosted backend.** Benji talks to the model provider you
  configured and to nothing else of its own. `benji --print-provider` shows where your data
  goes, with no API call.
- **What the provider sees.** With a hosted provider, your messages, what the tools return (file
  text, web pages, command output, browser page text) and, when Screen is on, the screenshot are sent
  to that company's servers, in the country the [provider table](configuration.md#choosing-a-model-provider) names,
  under its terms. The gate, taint rules and audit log work the same for every provider but cannot
  make a hosted model forget what it was sent. **Only a model you run yourself** (Ollama, LM Studio)
  keeps everything on your Mac. DeepSeek's own policy says personal data is stored in the People's
  Republic of China; Z.ai, Moonshot and Alibaba Cloud name Singapore for their international
  platforms (details in the table).
- **Keys** are read from the environment or `.benji.env` files and are never logged or written to
  disk by Benji. A provider's key is sent only to that provider's own host (a different
  `BENJI_BASE_URL` needs its own `BENJI_API_KEY`), and plain `http://` is refused except to your own
  computer.
- **Local files.** Memory (`memory.jsonl`), token counts (`usage.jsonl`, counts only), saved
  conversations, `answers.jsonl` (the model's raw answers: the one content log), job folders, the
  audit log and `engine.log` live in the working folder, `~/.benji` by default: one hidden folder, not
  loose folders. Log files are written readable by you only. Settings ›
  "Show Benji's folder" opens it. An older `~/benji` is moved into it once, on the first start; if both
  exist, `~/.benji` is used and nothing is merged. The key file `~/.benji.env` and the browser link's
  private folder stay where they are.
- **Screen.** One screenshot of the display the panel is on (Benji's own windows left out),
  downscaled, sent with the next message only; you see a thumbnail of exactly what was sent and the
  file is deleted after the reply. A model that cannot read images is never sent one.
- **Voice.** Transcription is on-device (Apple). Cloud transcription exists only for the optional
  command-line `--voice` / `--listen` flags.
