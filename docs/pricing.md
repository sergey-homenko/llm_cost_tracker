# Pricing and Price Refresh

LLM Cost Tracker prices calls locally from recorded usage and a versioned price registry. Providers usually return token counts, not a stable per-request price, so the gem stores the calculated cost with each ledger row.

Pricing covers registry shape, refresh tasks, precedence, provider-qualified keys, pricing modes, token components, provider-reported tool/runtime charges, and provider-billed call totals.

## Registry Rules

- Built-in prices live in `lib/llm_cost_tracker/prices.json`.
- Local snapshots live wherever `config.pricing.file` points.
- Precedence is `pricing.overrides`, then `pricing.file`, then bundled prices.
- Within one source, provider-qualified keys like `openai/gpt-4o-mini` win over model-only keys; a model-only key in an earlier source still beats a provider-qualified key in a later one.
- A model with no key under its own provider takes the price of the only `provider/model` key with the same model name, so Azure OpenAI's `gpt-4o` prices as `openai/gpt-4o`. With no match the call is recorded as `cost_status: unknown`.
- Historical rows keep the cost calculated when the call was recorded.

## Refresh Commands

```bash
bin/rails generate llm_cost_tracker:prices
bin/rails llm_cost_tracker:prices:refresh
bin/rails llm_cost_tracker:prices:check
```

The refresh task reads the maintained LLM Cost Tracker snapshot and writes to `ENV["OUTPUT"]`, then `config.pricing.file`, then `config/llm_cost_tracker_prices.yml`.

Refresh refuses a snapshot that zeroes an existing price or charges for a free one, removes a model's `input` or `output` rate, moves a price 100-fold or more either way, or switches currency, and leaves the local file as it was. `PREVIEW=1` and `prices:check` list those changes; once confirmed, re-run with `FORCE=1` or pass `force: true` to `LlmCostTracker::Pricing::Sync.refresh`. New models, models the snapshot drops entirely, removed rates other than `input` and `output`, and smaller moves are not checked, so keep reviewing the refreshed file.

For production containers, refresh the file before deploy and ship it with the release. Do not rely on a price refresh that mutates one running container.

## Price Fields

Base fields:

- `input`
- `output`
- `cache_read_input`
- `cache_write_input`
- `cache_write_extended_input`
- `audio_input`
- `audio_output`
- `image_input`
- `image_output`

These keys are derived from `Usage::Catalog`, the master dimension registry, which also owns the non-token model keys `text_to_speech_character`, `transcription_minute`, and `grounding_request`.

`cache_write_input` is the standard cache-write bucket. `cache_write_extended_input` is priced separately when provider usage exposes a longer retention bucket, such as Anthropic's 1-hour prompt cache writes.

`cache_read_input` is modality-agnostic. OpenAI's pricing page for the `gpt-image-*` family lists separate rates for image-cached input ($2.00 / M) and text-cached input ($1.25 / M), but the API only reports a single `prompt_tokens_details.cached_tokens` total without a modality breakdown. The registry stores the text-cached rate under `cache_read_input`, which under-prices image-heavy cache hits relative to the published list price. When OpenAI exposes the split (or a provider gives us a typed cached-image token count), `image_cache_read_input_tokens` will become a separate billable component.

OpenAI Realtime does report the split in `input_token_details.cached_tokens_details`. The parser takes cached audio and image tokens out of `audio_input` and `image_input` and prices them at `cache_read_input`. That matches the published cached-audio rate on the full-size `gpt-realtime` models, but under-prices cached images and the mini models' cached audio ($0.30 / M published against $0.06 / M for cached text).

Mode-prefixed fields use the same base terms:

- `batch_input`
- `batch_output`
- `priority_input`
- `batch_cache_read_input`
- `priority_cache_write_extended_input`

Long-context entries may also include `_context_price_threshold_tokens` and `above_context_*` fields. When the effective input side is above the threshold, the calculator uses the matching `above_context_input`, `above_context_output`, `above_context_cache_read_input`, or `above_context_<mode>_*` rate for the whole priced event.

## Pricing Modes

`pricing_mode` is the canonical field for alternate provider pricing tiers. OpenAI, OpenAI-compatible, Anthropic, Gemini, and RubyLLM capture populate it from provider tier data when the response exposes that field. Standard aliases such as `standard`, `default`, `auto`, and `standard_only` are treated as normal pricing.

Bundled prices include OpenAI `flex`, `fast` (with `priority` as the legacy alias OpenAI still returns for GPT-5.6 and earlier), and regional processing `data_residency` rates, Gemini `flex` and `priority`, Groq `flex`, and Anthropic `fast` and `data_residency` rates where the official provider pages publish them. OpenAI regional processing is captured from supported regional API hosts for the model families whose uplift is published. Gemini Priority can downgrade server-side, so Faraday capture trusts the `x-gemini-service-tier` response header instead of assuming the requested tier was honored.

Pass `pricing_mode: :batch` when usage came from a batch job, a gateway, or another path where the provider response does not expose the tier:

```ruby
LlmCostTracker.track(
  provider: "openai",
  model: "gpt-4o",
  tokens: { input_tokens: 1_000_000, output_tokens: 250_000 },
  pricing_mode: :batch,
  tags: { feature: "offline_eval" }
)
```

The calculator uses `batch_input`, `batch_output`, and other matching mode-prefixed fields when present. In any mode, a missing cache, audio, or image rate is derived from that component's standard rate and the mode's input discount (`<mode>_input / input`). When a mode `input` or `output` rate is missing, or a rate cannot be derived, the event is marked `partial` and only the priced components contribute to total cost; with no matching rates at all it stays `unknown` instead of silently using standard pricing.

Provider-specific pricing pages belong in scrapers and snapshots. Runtime pricing should stay in canonical billing terms.

## Registry Shape

Bundled and local registries use this high-level shape:

```json
{
  "metadata": {
    "schema_version": 1,
    "currency": "USD",
    "unit": "1M tokens"
  },
  "service_charges": {
    "openai": {
      "web_search_request": 10.0
    }
  },
  "models": {
    "openai/gpt-4o": {
      "input": 2.5,
      "output": 10.0
    }
  }
}
```

Model token prices are per 1M tokens, in the registry's `metadata.currency` (USD in the bundled file). Tool/runtime rates use their component's rate basis: per 1,000 requests for web search, web fetch, file search, and grounding (so `web_search_request: 10.0` is $10 per 1,000 searches), per session, hour, or minute for `container_session`, `code_execution_hour`, and `transcription_minute`, and per 1M characters for `text_to_speech_character`.

## Tool and Runtime Charges

The `service_charges` registry section prices provider tool and runtime calls that bill the same way for every model of a provider: web search, web fetch, file search. Charges whose rate differs per model — Gemini grounding, audio minutes — live on the model entry instead. At runtime they end up as line items on the parent call alongside token line items — same shape, same `cost_status` semantics. A line item with no rate match keeps the parent call `partial` when token cost is known, or `unknown` when the unmatched line is the only billable usage.

Each line item preserves the provider item id, captured `provider_field` path, quantity, kind, applied rate, and status — enough to join back to provider records downstream without applying free tiers or private rates locally.

Bundled rates mostly ship only where the parser captures the same quantity basis the provider publishes; `code_execution_hour` is the exception — the rate ships but nothing captures an hour quantity yet. OpenAI hosted web search and file search are priced when the registry has a rate. OpenAI Code Interpreter container sessions are captured as `container_session` audit rows; they aren't priced by default because the provider rate depends on container size and a fixed session window. Anthropic web-search and web-fetch requests are priced; Anthropic code-execution requests are not captured at all — no row is recorded for them until a provider usage field exposes the hourly quantity the published rate uses.

## Provider-Billed Cost

OpenRouter returns what it charged for each call in `usage.cost`, in the response and in the final chunk of a stream. That amount follows the provider it routed to, long-context rates, and image or audio output, which one list price per model cannot. When an OpenAI-compatible response carries a numeric `usage.cost`, the call is recorded at that amount in USD, as one `billed_request` line item with `provider_field: "usage.cost"` and `price_source: "provider_response"`. The token line items keep their counts with no cost. On a BYOK call (`usage.is_byok`), `usage.cost` is only OpenRouter's fee and the provider bills your key separately, so `usage.cost_details.upstream_inference_cost` is added. Registry rates price the call only when the response has no `usage.cost`. RubyLLM hands over token counts only, so OpenRouter calls through RubyLLM are still priced from the registry.

## Usage and Pricing Coverage

| Surface | Usage capture | Cost behavior |
| --- | --- | --- |
| OpenAI text, cache, reasoning, and audio token usage | Chat, Responses, OpenAI-compatible responses, and provider stream events | Token rates price captured buckets when the model has registry rates |
| OpenAI image generation (`gpt-image-*`) | `images.generate` / `edit` / `create_variation` (one-shot) + `*_stream_raw` (streaming) `usage` block; SDK or Faraday | `image_input` / `image_output` and `input`/`output` text token rates priced separately per modality |
| OpenAI Embeddings | `embeddings.create` `usage.prompt_tokens` | `input` rate prices the call when the model has registry rates |
| OpenAI Transcriptions (`gpt-4o-transcribe*`) | `audio.transcriptions.create` (+ `create_streaming`) `usage` block | `audio_input`, `input`, and `output` rates price captured buckets when present |
| OpenAI duration-billed audio (`gpt-transcribe`, `gpt-live-transcribe`, `gpt-realtime-whisper`, `gpt-realtime-translate`) | `usage` block with `type: "duration"` | `transcription_minute` rate, rounded up to the whole minute. These models publish no token price, so the minute is the billing basis |
| OpenAI Speech (TTS) | `audio.speech.create` request `input` length (chars) | `text_to_speech_character` rate, per 1M characters, for `tts-1` / `tts-1-hd`; `gpt-4o-mini-tts` is recorded with no line items and no rate because its tokens are not exposed, so it lands `cost_status: unknown` |
| OpenAI Moderations | `moderations.create` request payload | The call is recorded with no line items and no rate, so it lands `cost_status: unknown` (OpenAI does not bill the endpoint, but the price table carries no entry saying so) |
| OpenAI Realtime `response.done` | Provider stream events passed through `track_stream`; standard Faraday middleware does not auto-capture WebSocket/WebRTC sessions | Audio input/output token rates price the call when the model has registry rates |
| OpenAI hosted web search | `web_search_call` output items with `action.type = "search"` or no action type; Chat Completions `url_citation` annotations or `*-search-preview` / `*-search-api` models | Priced from `service_charges.openai.web_search_request` when present; with the `web_search_preview` tool or a Chat Completions search model, from `web_search_preview_request_reasoning` or `web_search_preview_request_non_reasoning` instead |
| OpenAI web search page actions | `open_page` and `find_in_page` output item actions | Ignored as service charges because they are not separate billable search calls |
| OpenAI hosted file search | `file_search_call` output items | Priced from `service_charges.openai.file_search_call` when present |
| OpenAI Code Interpreter containers | `code_interpreter_call` output items deduplicated by container id | Stored as unknown-cost `container_session` rows unless a custom rate matches the captured quantity basis |
| OpenAI image-generation / computer-use / MCP tool calls | `image_generation_call`, `computer_call`, `mcp_call` output items | Not recorded as line items — billed through the model's tokens (captured separately), with no separate per-call charge |
| Anthropic server web search | `server_tool_use.web_search_requests` | Priced from `service_charges.anthropic.web_search_request` when present |
| Anthropic web fetch | `server_tool_use.web_fetch_requests` | Priced at `$0` from registry — Anthropic bills web fetch through standard tokens, not per fetch |
| Gemini modality tokens | `usageMetadata.promptTokensDetails` and response token details | Audio token rates price captured buckets when the model has registry rates |
| Gemini grounding | `groundingMetadata.webSearchQueries` | Priced from the model's own `grounding_request` rate, which Google publishes per 1,000 requests and differs by family ($35 on Gemini 2.x, $14 on 3.x). The free monthly allowance is account-level and is not modelled, so a project inside it is over-reported |
| Groq OpenAI-compatible usage | Chat usage, cached input, reasoning output, and the `service_tier` field from the response (or the request) | Token rates price captured buckets when the model has registry rates |
| RubyLLM chat | `RubyLLM::Provider#complete` (streaming-aware; `Chat#ask` and `Chat#complete` reach this transitively) | Token counts from RubyLLM's response (input, output, cache read/write) and the service tier from its raw body, priced with the same registry as native SDK calls; provider tool charges (web search, grounding) and audio/image token buckets are not captured |
| RubyLLM embed / transcribe | `RubyLLM::Provider#embed`, `#transcribe` (on RubyLLM 1.x also `RubyLLM::Providers::Gemini::Transcription#transcribe`) | Token counts from RubyLLM's response; a transcription's input is priced at the model's `audio_input` rate when it has one, otherwise as text input |
| RubyLLM image / moderation | `RubyLLM::Provider#paint`, `#moderate` | `#paint` records image-token line items when the usage block carries them; `#moderate` records the call with no line items, so it lands `cost_status: unknown` |
