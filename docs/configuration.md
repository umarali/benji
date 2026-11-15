# Using and configuring Benji

How to use Benji in the app and on the command line, the settings it reads, how to choose a model
provider, and the optional extras.

- [Using Benji](#using-benji)
- [Settings](#settings) and [choosing a model provider](#choosing-a-model-provider)
- [Command-line voice](#command-line-voice-optional)
- [macOS automation, skills and memory](#macos-automation-skills-and-memory)

## Using Benji

### In the app

- **Talk:** hold **Right ⌥**, speak and release. A tap starts a conversation: Benji sends each
  message when you pause, and stops when you say "that's all" or go quiet. Opening the panel
  starts listening too, and listening can go on after the panel closes; Settings › Voice has
  **Listen while Benji is open** and **Keep listening when the panel closes** to turn these off.
  Speech is transcribed on your Mac with Apple's on-device recognition. Spoken questions are
  answered aloud; typed ones are too if you turn on Settings › General › **Read answers aloud**.
  The talk key needs Accessibility; the mic button in the panel works without it, and
  `defaults write com.emerssive.heybenji.app talkKey off` turns the key off.
- **Type:** open the panel from the notch or the menu-bar icon and use the message box.
- **Keys:** Esc stops an answer in progress, then folds the panel. On an approval card in the
  conversation, Esc and Return mean **No** and ⌘Return means **Yes**. In Settings, Esc goes back;
  in the conversation list, it goes home. A background job's card is answered only by its own
  buttons.
- **Show your screen:** Settings › Screen › Let Benji see your screen. **Off** never sends it; **Ask** shows a card
  before each message; **On** sends a screenshot with every message, and new installs start in
  On. Each capture goes with one message; there is no continuous recording. The answer may point
  at a control with a ring or outline a region. If Screen Recording is not granted, the message
  waits on the card: choose **Send without screen** to send it alone, or Cancel to put it back in
  the message box. Benji can also click, scroll and type for you: see
  [Acting on your screen](safety.md#acting-on-your-screen).

### What Benji can do

- **Do things:** shell commands, files in Benji's folder (`~/.benji` by default), web search
  and fetch, AppleScript and Shortcuts, skills (folders of instructions you can add) and a small
  memory of durable facts.
- **Work in the background:** "In the background, find three options and write a comparison to a
  file." The job runs in its own folder while you keep talking, behind the same safety rules as
  everything else. See [Background jobs](safety.md#background-jobs).
- **Use your own browser** (optional): a job can open pages you approved in your signed-in
  browser, read their text and, once you allow it for that site, click and type, with a card for
  anything that sends, pays, posts, deletes or uploads. "Summarise this page" reads the page in
  front of you after a card. See [Browser reach](safety.md#browser-reach).
- **Use your choice of model:** see [Choosing a model provider](#choosing-a-model-provider) and,
  for what each provider is sent, [Privacy](privacy.md).

### On the command line

- `python3 -m benji "…"` runs one task; `python3 -m benji` starts an interactive prompt.
- `--image shot.png` attaches an image.
- `python3 -m benji --serve` stays running and speaks JSON lines over stdin and stdout. The app
  uses it; [How Benji works](architecture.md#how-the-app-and-the-engine-talk) describes it.

## Settings

```bash
export BENJI_PROVIDER=claude   # or openai, deepseek, glm, kimi, qwen, ollama, lmstudio (else detected from the key present)
export BENJI_MODEL=...         # exact model id, if the default is rejected
export BENJI_EFFORT=low        # Claude only: low (default), medium, high, xhigh, max
export BENJI_WORKDIR=~/.benji  # Benji's folder (default ~/.benji)
export BENJI_THINKING=off      # off (default), on, or default (the provider's own setting); thinking is never shown or logged
export BENJI_MAX_TOKENS=8192   # the answer length limit (default 8192; 16000 for Kimi)
```

The default model is `claude-haiku-5-5` at effort `low`. `BENJI_MODEL=claude-sonnet-5-5` draws
better 3D figures at about 20 times the price (Settings › General › Model offers the same
choice).

### Choosing a model provider

Each provider is a preset: it sets the address, the key variable and a default model, and
`BENJI_MODEL` and `BENJI_BASE_URL` still override them. Model ids change quickly; if a default is
rejected, set `BENJI_MODEL` to a current id from the provider's model list.

| `BENJI_PROVIDER` | Key variable | Default model | Data goes to | Reads images (Screen) |
|---|---|---|---|---|
| `claude` (default) | `ANTHROPIC_API_KEY` | `claude-haiku-5-5` | `api.anthropic.com` | yes |
| `openai` | `OPENAI_API_KEY` | `gpt-4o` | `api.openai.com` | yes |
| `deepseek` | `DEEPSEEK_API_KEY` | `deepseek-flash` | `api.deepseek.com` (its privacy policy says personal data is stored in the People's Republic of China) | `deepseek-flash` yes, `deepseek-v4-pro` no |
| `glm` | `ZAI_API_KEY` (or `ZHIPUAI_API_KEY`) | `glm-5.3-flash` | `api.z.ai` ("generally processed in Singapore", per its policy); `BENJI_REGION=cn`: `open.bigmodel.cn` (China) | `glm-5.3-flash` yes, `glm-5.3` no |
| `kimi` | `MOONSHOT_API_KEY` | `kimi-k3.1-pro` | `api.moonshot.ai` (stored in Singapore, per its policy); `BENJI_REGION=cn`: `api.moonshot.cn` | `kimi-k3.1-pro` yes |
| `qwen` | `DASHSCOPE_API_KEY` | `qwen3.8-flash` | `dashscope-intl.aliyuncs.com` (Alibaba Cloud's Singapore region); `BENJI_REGION=cn`: `dashscope.aliyuncs.com` (Beijing region). Its docs say data is stored in the region you pick and say nothing firmer about where it is processed | `qwen3.8-flash` yes |
| `ollama` | none | name one with `BENJI_MODEL` | `localhost:11434`, your computer | only models whose name says so (`llava`, `-vl`, `vision`, `gemma3`…) |
| `lmstudio` | none | name one with `BENJI_MODEL` | `localhost:1234`, your computer | same |

```bash
export BENJI_PROVIDER=deepseek
export DEEPSEEK_API_KEY=...        # in ~/.benji.env is better than your shell history
python3 -m benji --print-provider # shows the provider, model, host and whether Screen can work, no API call
```

- **https only for hosted providers.** Plain `http://` is accepted for Ollama and LM Studio on
  your own computer, and for a custom server on a private address or a `.local` or `.ts.net`
  host. GLM's and Kimi's "coding plan" endpoints are refused: their terms limit them to listed
  coding tools.
- **Regions.** GLM, Kimi and Qwen each run an international and a China platform, with separate
  accounts and keys. `BENJI_REGION=intl` (default) or `cn` picks one.
- **Thinking** is off by default (`BENJI_THINKING=off`), because a spoken answer should come back
  quickly. GLM-5.3 and Kimi K3 cannot turn it off, so Benji asks them for the lowest effort.
- **Screen.** A model that cannot read images is never sent your screen, and Settings › Screen
  says why. `BENJI_VISION=1` or `0` overrides the table.
- **Only Claude has been used live.** Benji's prompts were written against it, and other models
  may handle tools, approval wording or pointing less well. `tools/model_smoke.py <provider>`
  is a five-minute live check with your own key. [Model providers](providers.md) has the details
  for each provider.

Open-weight or other models, on any server that speaks the OpenAI Chat Completions format
(OpenRouter, Together, Groq, llama.cpp, MLX, or Ollama / LM Studio at another address):

```bash
export BENJI_BASE_URL=https://openrouter.ai/api/v1   # or http://localhost:11434/v1 (Ollama)
export BENJI_MODEL=...         # required: the model id as that server lists it
export BENJI_API_KEY=...       # that server's key; leave unset for a local server
```

With a Claude model, web search is Anthropic's own: it needs no extra key and runs inside the model
call, at Anthropic's price per search (at the time of writing $10 per 1,000 searches, plus the results as
input tokens), at most three a request. With any other provider, or with `BENJI_WEB_SEARCH=local`,
Benji searches itself: DuckDuckGo with no key, which often blocks automated requests (Benji says
so when it does), so set `BRAVE_API_KEY` or `SERPAPI_KEY` for reliable search. `web_fetch` (reading a
known URL) needs no key.

Prompt caching and streaming are on by default (`BENJI_PROMPT_CACHE=0`, `BENJI_STREAM=0` turn
them off). `BENJI_USAGE_LOG=0` turns the token log off; `benji --usage` summarises it without an
API call.

## Command-line voice (optional)

```bash
python3 -m benji --speak "what's on my calendar today?"   # speak the answer (macOS `say`)
python3 -m benji --voice                                  # speak one task (needs ffmpeg + a transcription key)
python3 -m benji --listen                                 # always-listening loop with a wake word
tools/voice-setup.sh                                           # optional on-device voice (Kokoro), downloads ~400 MB
```

The app does not need these: it transcribes on-device unless you set its `pttTranscriber` setting
to `engine`. `--voice` and `--listen` need `ffmpeg` and `OPENAI_API_KEY` (Whisper) or
`DEEPGRAM_API_KEY`.

## macOS automation, skills and memory

- `run_applescript` drives apps through their scripting (read Calendar, create a Note…);
  read-only scripts run freely, ones that change state or send are gated. `run_shortcut` runs
  a Shortcut by name (always gated). macOS asks for Automation permission per app.
- **Skills** are folders `skills/<name>/SKILL.md` with front-matter (`name`, `description`,
  `when_to_use`) and instructions. Benji sees titles and descriptions and loads a skill's full
  text before using it. Drop in a folder to add one.
- **Memory:** `remember` and `recall` keep durable facts in `<workdir>/memory.jsonl`, one
  human-readable JSON line per fact, never secrets. A short digest is added to the prompt.
