# Model providers

Benji talks to Anthropic's Messages API and to any server that speaks the OpenAI chat-completions
format. DeepSeek, GLM (Z.ai / Zhipu), Kimi (Moonshot) and Qwen (Alibaba Cloud Model Studio) are
presets of the second: each sets the address, the key variable, a default model, which models
read images, and how thinking is switched. Ollama and LM Studio are presets for a server on your
own computer. To choose one, see [Choosing a model provider](configuration.md#choosing-a-model-provider).

**Only Anthropic has been used live.** The others are tested against fake servers that follow
each provider's API documentation as read on 2026-11-05. A passing test means Benji does what
those documents describe, not that the live service still matches them. If a default model id is
rejected, set `BENJI_MODEL`; `tools/model_smoke.py` (below) checks a provider live with your key.

## Defaults and which models read images

| Provider (`BENJI_PROVIDER`) | Default model (doc date) | Stronger / other models named in the docs | Reads images | Where the docs say so |
|---|---|---|---|---|
| `deepseek` | `deepseek-flash` (V4.1-Flash-1017; changelog 2026-10-17) | `deepseek-v4-pro` (V4-Pro-0813; GA 2026-08-13). `deepseek-chat` / `deepseek-reasoner` were scheduled for discontinuation on 2026-07-24 and are no longer in the model tables | `deepseek-flash` yes; `deepseek-v4-pro` no | api-docs.deepseek.com: pricing page, `/guides/vision`, `/updates` |
| `glm` | `glm-5.3-flash` (docs show no date) | `glm-5.3` (flagship, text only); `glm-5.3-flashx`; free: `glm-4.7-flash` | `glm-5.3-flash(x)` yes; `glm-5.3` no (China platform also `glm-5v-turbo`, `glm-4.6v`) | docs.z.ai `/api-reference/llm/chat-completion`, docs.bigmodel.cn model overview |
| `kimi` | `kimi-k3.1-pro` (docs show no date) | `kimi-k3.1-pro-highspeed` (2–3× faster), `kimi-k3`. Retired: `kimi-k2.5`, `moonshot-v1-*`, `kimi-k2-thinking*`, `kimi-latest` (changelog, 2026) | `kimi-k3.1-pro`, `kimi-k3` yes. The highspeed model is not listed as reading images, so Benji does not assume it does | platform.kimi.ai `/docs/models`, `/docs/guide/use-kimi-vision-model` |
| `qwen` | `qwen3.8-flash` (page dated 2026-10-30) | `qwen3.7-plus`, `qwen3.8-max` (pages dated 2026-10-11); `qwen3.7-flash`. `qwen-turbo`, `qwen-vl-*`, `qwq-plus`, `qvq-max` were scheduled for decommissioning on 2026-10-10 | `qwen3.8-flash`, `qwen3.7-flash`, `qwen3.7-plus`, `qwen3.8-max`, `qwen3-vl-*` yes | alibabacloud.com/help/en/model-studio: `vision`, `qwen3-8-flash`, model pages |
| `ollama`, `lmstudio` | none: you name the model you have loaded | | by name only (`llava`, `vision`, `-vl`, `gemma3`…); override with `BENJI_VISION` | not read: local servers |

A model that is not on the "reads images" list is treated as not reading them: Benji keeps Screen off
for that session and says so (Settings › Screen; the startup line shows `screen=off`), instead of
failing in the middle of a turn. `BENJI_VISION=1` or `0` overrides.

## Addresses, keys and regions

| Provider | International | China | Key variable | Notes |
|---|---|---|---|---|
| DeepSeek | `https://api.deepseek.com` | same | `DEEPSEEK_API_KEY` | One endpoint; no regional ones. |
| GLM | `https://api.z.ai/api/paas/v4` | `https://open.bigmodel.cn/api/paas/v4` | `ZAI_API_KEY`; `ZHIPUAI_API_KEY` is also read (that name is not in the docs we read) | Separate accounts. The "Coding Plan" endpoints (`/api/coding/paas/v4`) are limited by both vendors' terms to their listed coding tools: Benji refuses them. |
| Kimi | `https://api.moonshot.ai/v1` | `https://api.moonshot.cn/v1` | `MOONSHOT_API_KEY` | Docs moved to platform.kimi.ai / platform.kimi.com in 2026. Keys are per platform. Kimi Code (`api.kimi.com/coding`, `api.kimi.ai/coding`) is for coding tools: refused. |
| Qwen | `https://dashscope-intl.aliyuncs.com/compatible-mode/v1` (Singapore) | `https://dashscope.aliyuncs.com/compatible-mode/v1` (Beijing) | `DASHSCOPE_API_KEY` | The docs call these hosts "legacy" but say they remain functional; workspace-dedicated hosts `https://<WorkspaceId>.<region>.maas.aliyuncs.com/compatible-mode/v1` are the documented way forward (set as `BENJI_BASE_URL`; the same key goes to them). Keys are per region. A US (Virginia) endpoint exists only as a workspace host. |
| Ollama / LM Studio | `http://localhost:11434/v1` / `http://localhost:1234/v1` | | none | Plain http only to `localhost` or `127.0.0.1`. |

`BENJI_REGION=cn` picks the China platform for GLM, Kimi and Qwen. Auth is `Authorization: Bearer <key>` for all of them.

## Quirks Benji handles

- **Thinking.** DeepSeek and Qwen thinking can be switched off in the request (`thinking.type`,
  `enable_thinking`). GLM-5.3 and Kimi K3 **cannot** be switched off (a `disabled` is an error on GLM-5.3;
  K3 takes no `thinking` field): Benji asks for the lowest effort (`reasoning_effort: low`) instead.
  `BENJI_THINKING=off` is the default (a voice assistant wants a quick answer), `on` asks for more,
  `default` sends nothing. Reasoning arrives as `reasoning_content` (streamed before the answer); it is
  dropped on arrival and never shown, spoken, logged or saved. Local models that put `<think>…</think>`
  in the text have it cut out.
- **Reasoning that must be sent back.** DeepSeek (thinking on, requests carrying tools): the docs say a
  missing `reasoning_content` on earlier assistant turns is a 400. Kimi K3: the docs say to return the
  assistant message unchanged (no error is named). Benji keeps that reasoning in memory for the session
  and sends it back for those two, and for no one else. It is never written to disk.
- **Output limit.** `max_tokens` for DeepSeek and GLM, `max_completion_tokens` for Kimi and Qwen
  (their docs mark `max_tokens` deprecated or thinking-excluding). 8192 by default, 16000 for Kimi
  (its guide asks for at least that for multi-step tool use); `BENJI_MAX_TOKENS` overrides.
- **Usage.** DeepSeek reports cache hits as `prompt_cache_hit_tokens` (in `usage`, and its docs also show
  them inside `prompt_tokens_details`); Kimi as `cached_tokens` and `cache_write_tokens`; GLM and Qwen
  as `cached_tokens`. All go to `usage.jsonl` as counts. DeepSeek's last streamed chunk carries both the
  usage and a choice; Kimi's and Qwen's usage chunk has no choices.
- **`stream_options`.** Sent to DeepSeek, Kimi and Qwen, whose docs have it; not sent to GLM, whose docs
  do not mention it (usage arrives on the last chunk anyway).
- **Errors and 429.** A 429 or 5xx is retried twice (the server's `Retry-After` if it sends one, cut to
  8 s, else 1 s then 2 s). Not retried: an account problem under a 429 (GLM codes 1113 and the plan and
  quota-window codes, Kimi `exceeded_current_quota_error`, any message naming a balance or billing),
  DeepSeek 402, Qwen 403 `Arrearage`. An error becomes one line: `HTTP 429 from host: code · message`,
  never the request, the address's path or the whole body.
- **Models that refuse tools or pictures** get a plain sentence naming `BENJI_MODEL` or `BENJI_VISION`.
- **Never sent to these providers:** prompt-cache markers, `output_config.effort` (both Anthropic-only),
  `temperature`/`top_p`/`n` (Kimi K3 fixes them and errors on others), `tool_choice` (GLM accepts only
  `auto`; Kimi and Qwen restrict it in thinking mode).

## What each provider sees, and where

Messages, tool results (file text, pages, command output) and, with Screen on, screenshots go to the
provider's servers. What its documents say about location (none of it says anything about whether API
inputs are used for training; read their terms):

| Provider | Statement we found |
|---|---|
| DeepSeek | The API docs say nothing. The general privacy policy (last update 2026-02-10) says personal data is collected, processed and stored in the People's Republic of China. |
| GLM, international | Privacy policy (2025-09-29): "generally processed in Singapore"; the API data-processing terms say input and output content is processed in real time and not saved on its servers. |
| GLM, China | Personal information collected in China is stored in China (privacy policy effective 2025-05-20). |
| Kimi | The global privacy policy (2025-04-30) says data is stored on servers in Singapore. The China platform's policy was not read. |
| Qwen | The docs say a region sets where data is stored and the deployment scope sets where inference runs; they make no firmer statement for Singapore or Beijing. |
| Ollama, LM Studio | Your own computer. Nothing leaves it unless you point `BENJI_BASE_URL` elsewhere. |

## A five-minute live check

`python3 tools/model_smoke.py <provider>` starts the real engine against your key in a throwaway folder
and runs a typed question, one tool call, one background job and (for a model that reads images) one
picture question, printing PASS or FAIL for each and `benji --diagnose` at the end. It prints no key and
no message text. If something fails, the output of that script is what to open an issue with.

## Notes for changing a provider

For anyone editing `benji/presets.py`. **D**: the provider's documentation says it. **F**: a fake
server in `tests/check_providers.py` checks it. **U**: the docs do not say, so Benji does not rely
on it. **A**: an assumption of ours. None of it has been tried against the live services.

| Capability | DeepSeek | GLM | Kimi | Qwen | Ollama / LM Studio |
|---|---|---|---|---|---|
| OpenAI chat-completions at the base URL, Bearer key | D F (literal header text U) | D F | D F | D F | U (docs not read) F |
| Tool calls in OpenAI `tool_calls` format | D F | D F | D F | D F | U F |
| Streamed tool-call arguments by `index` | D F | U (`tool_stream` is documented; which chunk carries the name is not; Benji takes pieces or whole) F | D F | D F (later chunks have an empty `id`) | U F |
| Parallel tool calls | U (handled F) | U (handled F) | D F | D F | U (handled F) |
| `tool` role accepted by the fast model | D | **U for `glm-5.3-flash`** (its vision schema lists no tool role; the function-calling page says it supports tools) | D | D | U |
| Reasoning in `reasoning_content` | D F | D F (non-streamed presence U) | D F | D F | A (`<think>` tags in text) F |
| Thinking can be switched off | D F | No on 5.3 (D); effort `low` instead F | No (D); effort `low` instead F | D F | n/a |
| Reasoning must be sent back | D F (400 if omitted, thinking on, tools) | not by default (D: `clear_thinking` true) | D (required; error U) F | U when thinking is on (Benji keeps thinking off) | n/a |
| Output-limit parameter | `max_tokens` D F | `max_tokens` D F | `max_completion_tokens` D F | `max_completion_tokens` D F | `max_tokens` A F |
| `stream_options.include_usage` | D F | U (not sent) F | D F | D F | not sent |
| Where streamed usage sits | last chunk with a choice D F | last chunk D F | top-level on a chunk with no choices D F; also inside the choice (handled) | no choices D F | U |
| Cache hits in usage | `prompt_cache_hit_tokens` D F | `cached_tokens` D F | `cached_tokens`, `cache_write_tokens` D F | `cached_tokens` D F | none |
| Images as base64 data URLs in a user message | D F (flash only) | D F (data-URL syntax U) | D F (plain http URLs not accepted) | D F | U F |
| Image in a *tool* message | U (Benji sends it as a user message instead) | U (same) | U (same) | U (same) | n/a |
| 429 body / `Retry-After` | body shape U (fake uses the OpenAI shape); header U | `{"error":{"code","message"}}` D F; header U | `{"error":{"type","message"}}` D F; `Retry-After` for engine overload D F | `{"error":{"message","type","param","code"}}` D F; header U | A F |
| Out of balance | 402 D F | 429 code 1113 D F | 429 `exceeded_current_quota_error` D F | 403 `Arrearage` D F | n/a |
| A model that rejects tools / pictures | F | F | F | F | F |
| Data location stated | PRC (general policy) D | Singapore / China D | Singapore (global policy) D | storage by region D | local |
