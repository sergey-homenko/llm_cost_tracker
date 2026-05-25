# Pricing and Price Refresh

LLM Cost Tracker prices calls locally from recorded usage and a versioned price
registry. Providers usually return token counts, not a stable per-request price,
so the gem stores the calculated cost with each ledger row.

Pricing covers registry shape, refresh tasks, precedence, provider-qualified
keys, pricing modes, token components, and provider-reported tool/runtime
charges.

## Registry Rules

- Built-in prices live in `lib/llm_cost_tracker/prices.json`.
- Local snapshots live wherever `config.prices_file` points.
- Precedence is `pricing_overrides`, then `prices_file`, then bundled prices.
- Provider-qualified keys like `openai/gpt-4o-mini` win over model-only keys.
- Historical rows keep the cost calculated when the call was recorded.

## Refresh Commands

```bash
bin/rails generate llm_cost_tracker:prices
bin/rails llm_cost_tracker:prices:refresh
bin/rails llm_cost_tracker:prices:check
PROVIDER=openai MODEL=gpt-4o bin/rails llm_cost_tracker:prices:explain
```

The refresh task reads the maintained LLM Cost Tracker snapshot and writes to
`ENV["OUTPUT"]`, then `config.prices_file`, then
`config/llm_cost_tracker_prices.yml`.

For production containers, refresh the file before deploy and ship it with the
release. Do not rely on a price refresh that mutates one running container.

## Price Fields

Base fields:

- `input`
- `output`
- `cache_read_input`
- `cache_write_input`
- `cache_write_extended_input`
- `audio_input`
- `audio_output`

These keys are derived from `Billing::Components`, the master component registry.

`cache_write_input` is the standard cache-write bucket. `cache_write_extended_input`
is priced separately when provider usage exposes a longer retention bucket, such
as Anthropic's 1-hour prompt cache writes.

`cache_read_input` is modality-agnostic. OpenAI's pricing page for the `gpt-image-*`
family lists separate rates for image-cached input ($2.00 / M) and text-cached input
($1.25 / M), but the API only reports a single `prompt_tokens_details.cached_tokens`
total without a modality breakdown. The registry stores the text-cached rate under
`cache_read_input`, which under-prices image-heavy cache hits relative to the published
list price. When OpenAI exposes the split (or a provider gives us a typed cached-image
token count), `image_cache_read_input_tokens` will become a separate billable component.

Mode-prefixed fields use the same base terms:

- `batch_input`
- `batch_output`
- `priority_input`
- `batch_cache_read_input`
- `priority_cache_write_extended_input`

Long-context entries may also include `_context_price_threshold_tokens` and
`above_context_*` fields. When the effective input side is above the threshold,
the calculator uses the matching `above_context_input`,
`above_context_output`, `above_context_cache_read_input`, or
`above_context_<mode>_*` rate for the whole priced event.

## Pricing Modes

`pricing_mode` is the canonical field for alternate provider pricing tiers.
OpenAI, OpenAI-compatible, Anthropic, Gemini, and RubyLLM capture populate it
from provider tier data when the response exposes that field. Standard aliases
such as `standard`, `default`, `auto`, and `standard_only` are treated as normal
pricing.

Bundled prices include OpenAI `flex`, `priority`, and regional processing
`data_residency` rates, Gemini `flex` and `priority`, Groq `flex`, and
Anthropic `fast` and `data_residency` rates where the official provider pages
publish them. OpenAI regional processing is captured from supported regional API
hosts for the model families whose uplift is published. Gemini Priority can
downgrade server-side, so Faraday capture trusts the `x-gemini-service-tier`
response header instead of assuming the requested tier was honored.

Pass `pricing_mode: :batch` when usage came from a batch job, a gateway, or
another path where the provider response does not expose the tier:

```ruby
LlmCostTracker.track(
  provider: "openai",
  model: "gpt-4o",
  tokens: { input: 1_000_000, output: 250_000 },
  pricing_mode: :batch,
  tags: { feature: "offline_eval" }
)
```

The calculator uses `batch_input`, `batch_output`, and other matching
mode-prefixed fields when present. When some mode-specific rates are missing,
the event is marked `partial` and only the priced components contribute to
total cost; with no matching rates at all it stays `unknown` instead of
silently using standard pricing. For batch mode, cache rates can be derived
from the input discount when the provider documents that modifiers stack.

## Price Explain

Use `prices:explain` when Data Quality shows unknown pricing or a local override
does not behave as expected:

```bash
PROVIDER=openai MODEL=gpt-4o PRICING_MODE=batch bin/rails llm_cost_tracker:prices:explain
```

Optional token env vars let the command check the exact buckets that a call used:

```bash
PROVIDER=custom MODEL=gateway-model INPUT_TOKENS=1000 OUTPUT_TOKENS=200 CACHE_READ_INPUT_TOKENS=50 CACHE_WRITE_EXTENDED_INPUT_TOKENS=25 AUDIO_INPUT_TOKENS=100 AUDIO_OUTPUT_TOKENS=20 bin/rails llm_cost_tracker:prices:explain
```

The command reports the matched source, matched key, match strategy, effective
rates, and any missing rate needed to price the event.

Provider-specific pricing pages belong in scrapers and snapshots. Runtime
pricing should stay in canonical billing terms.

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

Model prices are USD per 1M tokens. Tool/runtime rates use the quantity basis
of their billing component — request, session, hour, etc.

## Tool and Runtime Charges

The `service_charges` registry section prices provider tool and runtime calls
(web search, code execution, grounding, container sessions, file search). At
runtime they end up as line items on the parent call alongside token line
items — same shape, same `cost_status` semantics. A line item with no rate
match keeps the parent call `partial` when token cost is known, or `unknown`
when the unmatched line is the only billable usage.

Each line item preserves the provider item id, captured `provider_field` path,
quantity, kind, applied rate, and status — enough for downstream reconciliation
to join back to provider records without applying free tiers or private rates
locally.

Bundled rates ship only when the parser captures the same quantity basis the
provider publishes. OpenAI hosted web search and file search are priced when
the registry has a rate. OpenAI Code Interpreter container sessions are
captured as `container_session` audit rows; they aren't priced by default
because the provider rate depends on container size and a fixed session
window. Anthropic web-search requests are priced; Anthropic code-execution
requests stay `unknown` until a provider usage field exposes the hourly
quantity the published rate uses.

## Usage and Pricing Coverage

| Surface | Usage capture | Cost behavior |
| --- | --- | --- |
| OpenAI text, cache, reasoning, and audio token usage | Chat, Responses, OpenAI-compatible responses, and provider stream events | Token rates price captured buckets when the model has registry rates |
| OpenAI image generation (`gpt-image-*`) | `images.generate` / `edit` / `create_variation` (one-shot) + `*_stream_raw` (streaming) `usage` block; SDK or Faraday | `image_input` / `image_output` and `input`/`output` text token rates priced separately per modality |
| OpenAI Embeddings | `embeddings.create` `usage.prompt_tokens` | `input` rate prices the call when the model has registry rates |
| OpenAI Transcriptions (`gpt-4o-transcribe*`) | `audio.transcriptions.create` (+ `create_streaming`) `usage` block | `audio_input`, `input`, and `output` rates price captured buckets when present |
| OpenAI Speech (TTS) | `audio.speech.create` request `input` length (chars) | `character_input` rate per character for `tts-1` / `tts-1-hd`; `gpt-4o-mini-tts` records zero-cost visibility because tokens are not exposed |
| OpenAI Moderations | `moderations.create` request payload | Zero-cost visibility line item (OpenAI does not bill the endpoint) |
| OpenAI Realtime `response.done` | Provider stream events passed through `track_stream`; standard Faraday middleware does not auto-capture WebSocket/WebRTC sessions | Audio input/output token rates price the call when the model has registry rates |
| OpenAI hosted web search | `web_search_call` output items with `action.type = "search"` | Priced from `service_charges.openai.web_search_request` when present |
| OpenAI web search page actions | `open_page` and `find_in_page` output item actions | Ignored as service charges because they are not separate billable search calls |
| OpenAI hosted file search | `file_search_call` output items | Priced from `service_charges.openai.file_search_call` when present |
| OpenAI Code Interpreter containers | `code_interpreter_call` output items deduplicated by container id | Stored as unknown-cost `container_session` rows unless a custom rate matches the captured quantity basis |
| OpenAI MCP tool calls | `mcp_call` output items | Stored as unknown-cost `mcp_call` rows for visibility (no published per-call rate from OpenAI) |
| Anthropic server web search | `server_tool_use.web_search_requests` | Priced from `service_charges.anthropic.web_search_request` when present |
| Anthropic web fetch | `server_tool_use.web_fetch_requests` | Priced at `$0` from registry — Anthropic bills web fetch through standard tokens, not per fetch |
| Gemini modality tokens | `usageMetadata.promptTokensDetails` and response token details | Audio token rates price captured buckets when the model has registry rates |
| Gemini grounding | `groundingMetadata.webSearchQueries` | Stored as unknown-cost `grounding_request` rows because free-tier and query reconciliation are account-level |
| Groq OpenAI-compatible usage | Chat usage, cached input, reasoning output, and service tier headers | Token rates price captured buckets when the model has registry rates |
| RubyLLM chat | `RubyLLM::Provider#complete` (streaming-aware; `Chat#ask` and `Chat#complete` reach this transitively) | Routed through the matched provider parser (OpenAI / Anthropic / Gemini); same pricing path as native SDK |
| RubyLLM embed / transcribe | `RubyLLM::Provider#embed`, `#transcribe` | Routed through the matched provider parser; priced like the underlying provider call |
| RubyLLM image / moderation | `RubyLLM::Provider#paint`, `#moderate` | Zero-cost visibility line items when no captured quantity has a registry rate |
