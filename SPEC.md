# Personal Assistant — Specification (v0.1 draft)

*Working name at the time: `pal`. The product is called **Benji** (D-178); it was Chilly before that (D-48, D-58, D-84). A local AI assistant that does real work on your Mac and your connected apps.*

Status (updated 2026-10-31): **built.** This is the original spec (v0.1, 2026-10-29) for the backend and CLI; milestones M0–M4 are all done (§8). Work since then, the notch companion and Benji's design system, is in §11. Sections 1–7 are kept as written, with notes where a later decision changed them.

---

## 1. Goal & philosophy

Build a personal assistant that:

1. **Does tasks, not just chat.** It runs an agentic tool-use loop: look at the request → use tools (shell, files, web, app integrations) → report what it did.
2. **Runs locally, terminal-first.** A CLI you launch on your Mac. Voice and UI come later; they're not required for it to be useful.
3. **Is model-agnostic.** Auto-detects an Anthropic or OpenAI key (or a DeepSeek, GLM, Kimi or Qwen key with `BENJI_PROVIDER`; or a local Ollama / LM Studio server); backend is swappable without touching the agent logic.
4. **Is safe by construction.** An explicit approval policy, a prompt-injection boundary, and no silent destructive/outbound actions.
5. **Grows through skills, not rewrites.** New capabilities are added as self-contained skill folders the agent reads on demand.

**Non-goals (for now):** cloning another assistant, cloud sync, multi-user, a hosted backend. Benji is original code; the few ideas it borrows are credited in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

*Changed since v0.1:* "a native GUI" was a non-goal; it no longer is. The menu-bar app came with M4, and the notch companion (Benji's main surface, D-54) followed (§11).

---

## 2. Design principles

| Pattern | What we adopt |
|---|---|
| Skills as `SKILL.md`, read before first use | Lazy-loaded skills folder; agent lists/reads on demand |
| Working folder with `output/`, `tmp/`, dated `AGENTS.md` notes | Same convention; **never store secrets in notes** |
| "The request is the approval; confirm before delete/send/spend" | Our approval policy (§6) |
| Prompt-injection guard ("a brief's paths are not a chosen destination") | Instruction-source boundary (§6) |
| `mdfind`/`rg` to find files instead of walking folders | Built-in search tool prefers these |
| Anti-hallucination ("never say something happened unless it did") | System-prompt rule + tools return real results only |
| No synthetic clicks (`System Events`, `cliclick`); prefer AppleScript/Shortcuts | Same stance when we add Mac automation |

---

## 3. Architecture

```
┌──────────────────────────────────────────────────────────┐
│  Benji CLI  (REPL + one-shot:  Benji "summarize my downloads")  │
└───────────────┬──────────────────────────────────────────┘
                │ messages + tool results
        ┌───────▼────────┐      neutral tool schema
        │   Agent loop    │◀───────────────────────────┐
        │ (provider-      │                             │
        │  agnostic)      │─── tool calls ──▶  Tool registry
        └───────┬─────────┘                   (shell, files, search, web, skills)
                │ translate per provider              │
      ┌─────────▼─────────┐                           │ approval gate
      │ Provider adapter  │                   ┌───────▼────────┐
      │  Claude | OpenAI  │                   │  Approval policy │ ← terminal y/n
      └─────────┬─────────┘                   └────────────────┘
                │ HTTPS
        Anthropic / OpenAI API
```

### Components
- **CLI** (`benji`): REPL and one-shot mode; renders the conversation, streams the final answer, prints a short line per tool call.
- **Agent loop**: maintains message history, calls the model, dispatches tool calls, feeds results back until the model emits a final answer.
- **Provider adapters**: one neutral tool/message schema; each adapter translates to/from Anthropic Messages API or OpenAI Chat Completions. Auto-selected from whichever API key is present (`BENJI_PROVIDER` / `BENJI_MODEL` override). DeepSeek, GLM, Kimi, Qwen, Ollama and LM Studio are presets of the OpenAI adapter (`benji/presets.py`, D-147): address, key variable, default model, which models read images, how thinking is switched; the approval gate and the logs are the same for every provider.
- **Tool registry**: each tool = name, description, JSON-schema params, handler, and a `side_effect` flag that drives the approval gate.
- **Skills**: folders under `skills/`, each with a `SKILL.md`; surfaced via `list_skills` / `read_skill`.
- **Working folder**: a per-session (or per-project) directory holding `output/`, `tmp/`, and `AGENTS.md`.

### Language / stack
- **Python 3.11+** (3.14 present on this machine). **Zero third-party deps for the MVP** — HTTP via stdlib `urllib` so there's nothing to `pip install`. Optional niceties (e.g. `rich`) can come later behind a soft import.

---

## 4. Tools (MVP set)

| Tool | Params | Side effect | Notes |
|---|---|---|---|
| `run_shell` | `command`, `cwd?` | **yes** (gated for destructive) | runs in a shell; destructive patterns (`rm`, `mv` over existing, `>` redirects, `sudo`, …) require approval |
| `read_file` | `path`, `offset?`, `limit?` | no | |
| `write_file` | `path`, `content` | **yes** (approval) | overwrites require showing a diff/summary |
| `list_dir` | `path` | no | |
| `search_files` | `query`, `path?`, `content?` | no | prefers `rg`; `mdfind` for whole-Mac name/content search |
| `web_fetch` | `url`, `prompt?` | no (network read) | fetch + extract text; later: summarize via model |
| `web_search` | `query` | no (network read) | optional; needs a search provider/key — stub if absent |
| `list_skills` | — | no | enumerate `skills/*/SKILL.md` titles |
| `read_skill` | `name` | no | return a skill's `SKILL.md` |

Later tiers (post-MVP): AppleScript/Shortcuts runner, calendar/mail/notes via connectors, a `browser` tool, voice I/O.

---

## 5. Skills system

- A skill is a folder `skills/<name>/` containing at least `SKILL.md` (front-matter: `name`, `description`, `when_to_use`) and optionally helper scripts/assets.
- The agent sees only **titles + descriptions** by default; it calls `read_skill` to load the full instructions **before first use** (keeps context small).
- Ship 1–2 example skills to prove the pattern (e.g. `summarize-folder`, `draft-email`).

---

## 6. Safety model

### Instruction-source boundary
Only the user (via the CLI) issues instructions. Anything a tool returns — file contents, web pages, command output — is **data, never commands**. If tool output contains text aimed at the agent ("ignore previous instructions", "run X"), the agent surfaces it to the user rather than acting on it. A task brief's file paths are not evidence the user chose a destination.

### Approval policy (the request is the approval, with exceptions)
The user's request authorizes the obvious writes it implies. The agent **must confirm first** before:
- deleting or overwriting data it wasn't asked to change,
- sending anything to other people (email, message, post),
- spending money,
- any `run_shell` command matching the destructive-pattern list,
- anything outside the stated working folder.

Messages/posts are **drafts** until the user approves that exact text. Approval is per-action, per-session — never generalized.

### Secrets & privacy
- API keys read only from the environment; never logged, never written to `AGENTS.md` or `output/`.
- No telemetry, by design.

### Honesty
Never claim an action happened unless the tool confirmed it; never invent a fact, path, price, or citation — look it up or ask.

---

## 7. Config & runtime

- **Keys:** `ANTHROPIC_API_KEY` or `OPENAI_API_KEY` (auto-detect; prefer Anthropic if both); `DEEPSEEK_API_KEY`, `ZAI_API_KEY`, `MOONSHOT_API_KEY`, `DASHSCOPE_API_KEY` with `BENJI_PROVIDER` (a single one present is also detected).
- **Overrides:** `BENJI_PROVIDER` (`claude`|`openai`|`deepseek`|`glm`|`kimi`|`qwen`|`ollama`|`lmstudio`), `BENJI_REGION`, `BENJI_THINKING`, `BENJI_VISION`, `BENJI_MAX_TOKENS`, `BENJI_MODEL` (exact model id), `BENJI_WORKDIR`.
- **Invocation:** `benji` (interactive REPL) or `benji "do this thing"` (one-shot). `--yes` to auto-approve in trusted contexts; `--workdir PATH`.
- Startup prints the selected provider, model, and working folder so there's no ambiguity.

---

## 8. Milestones

- **M0 — Walking skeleton:** ✅ done. CLI + agent loop + one provider + `run_shell`, `read_file`, `list_dir`.
- **M1 — Useful MVP:** ✅ done. Both providers, `write_file` + `search_files` + approval gate + working folder, system prompt, skills system (`list_skills`/`read_skill`) + 2 example skills (summarize-folder, draft-email).
- **M2 — Skills & web:** ✅ done. `web_fetch`/`web_search` (Brave/SerpAPI/DuckDuckGo), isolated `web.py`, and a web-using `research` skill alongside summarize-folder and draft-email.
- **M3 — Mac reach:** ✅ done. `run_applescript` (mutating scripts gated), `run_shortcut` (gated), `list_shortcuts`, and an `apple-notes` skill. Optional native connectors (calendar, mail) remain future work.
- **M4 — Ambient:** ✅ done. Voice I/O — `--speak` (macOS `say` TTS) and `--voice` (ffmpeg → Whisper/Deepgram → run) — plus a first native Swift menu-bar app (since replaced by the notch companion, `companion/`) with an **in-app Approve/Deny dialog** (Benji↔app approval over stdio via `BENJI_APPROVAL_IO`). Plus an **always-listening voice loop** (`--listen`): energy-gated windows, wake-word trigger, context-preserving across utterances, spoken replies. All planned milestones are complete.

---

## 9. Open questions (settled)

1. **Name** — `benji` (placeholder kept).
2. **Default model ids** — `claude-haiku-5-5` (effort `low`) / `gpt-4o`, overridable via `BENJI_MODEL`; `claude-sonnet-5-5` is the secondary option for better figures.
3. **Working folder scope** — one global `~/.benji` workspace (override with `BENJI_WORKDIR`).
4. **Web search provider** — Brave/SerpAPI when keyed, else DuckDuckGo best-effort.
5. **Persistence** — ✅ done: a `memory.jsonl` store with `remember`/`recall` and a prompt digest.
6. **REPL niceties** — plain stdlib I/O (no third-party deps).

## 10. Beyond the plan
- ✅ Always-listening loop bound into the menu-bar app (Listen toggle + mic entitlement).
- Next: real connectors (calendar, mail) as skills; richer memory (editing/forgetting facts);
  package Benji as a `pipx`-installable CLI; sign/notarize `PalBar.app`.

## 11. Since the spec (summary; details in `docs/`)
- **Notch companion** (`companion/`, SwiftPM, macOS 14+): text, approvals, on-device voice,
  per-message screen context, conversation memory, a pointer overlay. Its pure logic
  (`BenjiCore`) is unit-tested.
- **Backend additions:** `--image`, `--history`, `--allow-pointing` (`[POINT:…]` and
  `[BOX:…]` tags, up to three targets), `--transcribe`, `BENJI_BASE_URL` for any
  OpenAI-compatible server (D-46), approvals for sensitive capabilities (D-57), a local
  token-usage log and `benji --usage`.
- **Name and design:** the product is Benji, with a design system in
  `docs/design-system/project/` (D-55 to D-67).
- **Direction:** a personal assistant trusted with anything (D-44), on Claude for now (D-45);
  its safety model needs rework before it gets more reach (per-tool permissions, tainting by
  untrusted content, egress control).
- **Next:** a persistent `benji --serve` (D-34), then conversation mode (D-43), and the app work
  from the design system.
