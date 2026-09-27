# Pricing and Price Refresh

LLM Cost Tracker prices calls locally from recorded usage and a versioned price registry. Providers usually return token counts, not a stable per-request price, so the gem stores the calculated cost with each ledger row.

Pricing covers registry shape, refresh tasks, precedence, provider-qualified keys, pricing modes, token components, provider-reported tool/runtime charges, and provider-billed call totals.

## Registry Rules

- Built-in prices live in `lib/llm_cost_tracker/prices.json`.
- Local snapshots live wherever `config.pricing.file` points.
- Precedence is `pricing.overrides`, then `pricing.file`, then bundled prices. The first matching entry is used whole; rates are not merged across sources, so an override must list every rate its calls use.
- Within one source, provider-qualified keys like `openai/gpt-4o-mini` win over model-only keys; a model-only key in an earlier source still beats a provider-qualified key in a later one.
- A model with no key under its own provider in any source takes the price of the only `provider/model` key with the same model name, so Azure OpenAI's `gpt-4o` prices as `openai/gpt-4o`, while an `azure_openai/gpt-4o` override leaves direct OpenAI and OpenRouter calls on their own keys. With no match the call is recorded as `cost_status: unknown`.
- An Amazon Bedrock Claude model id or inference profile, such as `us.anthropic.claude-sonnet-4-5-20250929-v1:0` or `global.anthropic.claude-opus-4-6-v1`, prices as the Anthropic model when the prices list it. The bundled prices follow Anthropic's own API, so Claude models it has retired but Bedrock still sells, such as Claude Sonnet 4, stay unknown until you add them. Through RubyLLM or the Anthropic SDK, a regional profile such as `us.` or `eu.` on Claude 4.5 and later takes the model's `data_residency` rates, the 10% premium Bedrock charges for regional endpoints; earlier models keep their standard price. `backfill_unknown_pricing` adds the premium to RubyLLM regional-profile calls recorded before 0.14.2, which were stored unpriced; Anthropic SDK calls recorded before 0.14.2 keep the list price they were recorded at. Through RubyLLM, GovCloud profiles (`us-gov.`), which Bedrock bills at 1.2x the standard price, stay unknown until you add them to `pricing.overrides` under their full id, such as `us-gov.anthropic.claude-sonnet-4-5-20250929-v1:0`. The Anthropic SDK records the model that Bedrock's response names, such as `claude-sonnet-4-5-20250929`, so its GovCloud calls are priced at Anthropic's list rate, below the GovCloud bill.
- xAI prices come from LiteLLM's aggregated price list, which carries the model names and aliases xAI's API accepts, with batch, priority, and US regional rates from xAI's pricing and model pages, and image prompt tokens at the model's input rate, the one input price xAI lists. Mistral prices come from Mistral's pricing page, under the API names LiteLLM's list maps to each model there, with batch, priority, and regional rates at the multiples Mistral's docs give; Mistral models the page does not list, such as Pixtral Large or Mistral Nemo, stay unknown. DeepSeek is not bundled: its price halves outside weekday peak hours, which one rate per model cannot express, so add it to `pricing.overrides` at the rate you want budgets to assume.
- Historical rows keep the cost calculated when the call was recorded. `bin/rails llm_cost_tracker:backfill_unknown_pricing` prices unknown and partial calls; to correct calls already priced at a wrong rate, fix the price and run `bin/rails llm_cost_tracker:reprice FROM=2026-09-01` (optionally with `TO=`, exclusive), which reprices every call tracked in that range at the current prices, including tool charges such as web search or grounding and Anthropic advisor and fallback attempts, and moves rollups and per-tag budget costs by the difference. Amounts the provider billed, such as OpenRouter's `usage.cost`, and costs you passed to `track` keep their recorded value, and a call whose model is no longer priced is left as it was.

## Refresh Commands

```bash
bin/rails generate llm_cost_tracker:prices
bin/rails llm_cost_tracker:prices:refresh
bin/rails llm_cost_tracker:prices:check
```

The refresh task reads the maintained LLM Cost Tracker snapshot and writes to `ENV["OUTPUT"]`, then `config.pricing.file`, then `config/llm_cost_tracker_prices.yml`.

Refresh refuses a snapshot that zeroes an existing price or charges for a free one, removes a model's `input` or `output` rate, moves a price 100-fold or more either way, or switches currency, and leaves the local file as it was. `prices:check` lists those changes without writing; once confirmed, re-run refresh with `FORCE=1` or pass `force: true` to `LlmCostTracker::Pricing::Sync.refresh`. New models, models the snapshot drops entirely, removed rates other than `input` and `output`, and smaller moves are not checked, so keep reviewing the refreshed file.

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
- `audio_cache_read_input`
- `image_cache_read_input`
- `video_input` (Gemini embedding video parts; falls back to `input`)

These keys are derived from `Usage::Catalog`, the master dimension registry, which also owns the non-token model keys `text_to_speech_character`, `transcription_minute`, `grounding_request`, `maps_grounding_request`, and `cache_storage_token_hour`.

`cache_write_input` is the standard cache-write bucket. `cache_write_extended_input` is priced separately when provider usage exposes a longer retention bucket, such as Anthropic's 1-hour prompt cache writes. An Anthropic stream's final `message_delta` reports the cache-write total but not its 5-minute/1-hour split, so writes beyond the `message_start` split (the automatic breakpoints on server-tool results) are priced as 5-minute writes, the TTL Anthropic always gives them.

A bundled or `pricing.file` OpenAI entry with no `cache_read_input` or `cache_write_input` rate prices those tokens at its `input` rate, as OpenAI bills them: Pro models have no cached-input discount, and models before GPT-5.6 have no cache-write charge. When the bundled snapshot lists the same model, its rates decide, so a `pricing.file` entry for `openai/gpt-4o` without a cached rate leaves cached tokens unpriced instead of charging them at the input rate. A `pricing.overrides` entry, or a `pricing.file` entry marked `"_source": "manual"` (the marker `prices:refresh` keeps hand-written entries by), leaves them unpriced too.

`cache_read_input_tokens` counts cached tokens of every modality. When a response says how many of them are audio or image tokens, those are priced at `audio_cache_read_input` / `image_cache_read_input`, or at `cache_read_input` when the model has no such rate; the call's line items show the split (`kind` `audio_token` or `image_token` with `cache_state` `read`), and the dashboard adds it to Cache read.

OpenAI Realtime reports the split in `input_token_details.cached_tokens_details`, so the mini models' cached audio is priced at $0.30 / M rather than the $0.06 / M cached-text rate, and cached images at their own rate. The `gpt-image-*` family reports only a single `cached_tokens` total, so its cached image tokens stay at the text-cached rate ($1.25 / M against $2.00 / M published for cached images).

Gemini reports the split in `cacheTokensDetails`; cached audio is priced at the published audio caching rate (Gemini 2.5 Flash: $0.10 / M against $0.03 / M for text / image / video). Creating an explicit Gemini context cache (`POST /v1beta/cachedContents` through Faraday, or `RubyLLM.cache` on RubyLLM 2.x) records a `cache_storage_token_hour` line item: the cached token count times the hours from the response's `createTime` to its `expireTime`, at the model's standard storage rate per 1M tokens per hour. It is an estimate: a cache deleted early is still counted to its expiry, and a TTL changed later with a `PATCH` is not captured.

Mode-prefixed fields use the same base terms:

- `batch_input`
- `batch_output`
- `priority_input`
- `batch_cache_read_input`
- `priority_cache_write_extended_input`
- `data_residency_transcription_minute`

A mode-prefixed non-token model key, such as `data_residency_transcription_minute`, applies under that mode; without one, the model's standard non-token rate applies.

Long-context entries may also include `_context_price_threshold_tokens` and `above_context_*` fields. When the effective input side is above the threshold, the calculator uses the matching `above_context_input`, `above_context_output`, `above_context_cache_read_input`, or `above_context_<mode>_*` rate for the whole priced event. xAI bills its long-context rate from exactly 200,000 prompt tokens, so its bundled threshold is 199,999.

A field with a `_from_YYYY-MM-DD` suffix, such as `input_from_2027-01-01`, replaces that field's rate for calls made on or after that date (UTC). The Gemini scraper writes these for price changes Google announces on its pricing page, such as the 3.6, 3.7, and 3.8 Flash increase on January 1, 2027, so bundled prices switch on the day. `backfill_unknown_pricing` and `reprice` price each call at the rate of its own date while the snapshot carries the dated field. A snapshot scraped on or after that date carries only the new rate, so after `prices:refresh` or a gem update they price earlier calls at it too, as with any other price change.

## Pricing Modes

`pricing_mode` is the canonical field for alternate provider pricing tiers. OpenAI, OpenAI-compatible, Anthropic, Gemini, and RubyLLM capture populate it from provider tier data when the response exposes that field. Standard aliases such as `standard`, `default`, `auto`, and `standard_only` are treated as normal pricing.

Bundled prices include OpenAI `flex`, `fast` (with `priority` as the legacy alias OpenAI still returns for GPT-5.6 and earlier), and regional processing `data_residency` rates, Gemini `flex` and `priority`, Groq `flex` and `batch` (half the on-demand rate on the models Groq's Batch API accepts, cached tokens included, since Groq does not stack the two discounts), Anthropic `fast` and `data_residency`, xAI `batch` (on the models xAI discounts and the aliases their model pages list), `priority`, and `data_residency` (the `us.api.x.ai` endpoint, on the models it serves), and Mistral `batch`, `priority`, and `data_residency` (the `api.eu.mistral.ai` and `api.us.mistral.ai` endpoints) rates where the official provider pages publish them. xAI and Mistral batches are not captured, so their `batch` rates apply only when `pricing_mode` names them, as with `LlmCostTracker.track`. OpenAI regional processing is captured from supported regional API hosts for the model families whose uplift is published; batch results get it only through `us.api.openai.com` and `eu.api.openai.com`, the hosts where OpenAI processes batches regionally. xAI's `us.api.x.ai` and Mistral's `api.eu.mistral.ai` and `api.us.mistral.ai` work the same way: a model whose prices list `data_residency` rates is priced at them there, and any other model at its standard rates. Faraday captures those hosts only once each is registered in `capture.openai_compatible_providers` (see [Configuration](configuration.md#openai-compatible-hosts)). xAI Priority Processing is read from the response's `service_tier` and Mistral's Priority Tier from `usage.service_tier`, and both are priced at the model's `priority` rates, or on a regional endpoint at its `priority_data_residency` rates. On xAI those are 2.2x standard, since the US endpoint bills 10% more than the global one. Mistral publishes no rate for Priority Tier on a regional endpoint and bills it by your Priority Tier terms, so the bundled rates compound its 1.75x and 1.1x to 1.925x; set `priority_data_residency_*` in `pricing.overrides` if your terms differ. Gemini Priority can downgrade server-side, so Faraday capture trusts the `x-gemini-service-tier` response header instead of assuming the requested tier was honored. OpenAI and Anthropic streams, through Faraday or the SDK integrations, likewise price the tier and speed the stream reports and fall back to the requested ones only when it reports none, so a downgraded OpenAI or Azure priority request, or a Claude Opus 4.6 request with `speed: "fast"`, is priced at standard rates. Anthropic batch results are priced as `batch`, plus `data_residency` when the result's `usage.inference_geo` is `us`.

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

The calculator uses `batch_input`, `batch_output`, and other matching mode-prefixed fields when present. In any mode, a missing cache, audio, or image rate is derived from that component's standard rate and the mode's input discount (`<mode>_input / input`), and the call's `pricing_snapshot` and line item name it by the mode key it stands in for, such as `batch_cache_read_input`. When a mode `input` or `output` rate is missing, or a rate cannot be derived, the event is marked `partial` and only the priced components contribute to total cost; with no matching rates at all it stays `unknown` instead of silently using standard pricing.

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

Model token prices are per 1M tokens, in the registry's `metadata.currency` (USD in the bundled file). Tool/runtime rates use their component's rate basis: per 1,000 requests for web search, web fetch, file search, and Search and Maps grounding (so `web_search_request: 10.0` is $10 per 1,000 searches), per call for `image_generation_call`, per session, hour, or minute for `container_session`, `code_execution_hour`, and `transcription_minute`, per 1M characters for `text_to_speech_character`, and per 1M tokens per hour for `cache_storage_token_hour`.

## Tool and Runtime Charges

The `service_charges` registry section prices provider tool and runtime calls that bill the same way for every model of a provider: web search, web fetch, file search. Charges whose rate differs per model — Gemini grounding, audio minutes — live on the model entry instead. At runtime they end up as line items on the parent call alongside token line items — same shape, same `cost_status` semantics. A line item with no rate match keeps the parent call `partial` when token cost is known, or `unknown` when the unmatched line is the only billable usage.

Each line item preserves the provider item id, captured `provider_field` path, quantity, kind, applied rate, and status — enough to join back to provider records downstream without applying free tiers or private rates locally.

Bundled rates mostly ship only where the parser captures the same quantity basis the provider publishes; `code_execution_hour` is the exception — the rate ships but nothing captures an hour quantity yet. OpenAI hosted web search and file search are priced when the registry has a rate. OpenAI Code Interpreter and Hosted Shell container sessions are captured as `container_session` audit rows; they aren't priced by default because the provider rate depends on container size and a fixed session window. OpenAI image-generation tool calls are captured the same way as `image_generation_call` rows; the image price depends on the tool's model, quality, and size. Anthropic web-search and web-fetch requests are priced; Anthropic code-execution requests are not captured at all — no row is recorded for them until a provider usage field exposes the hourly quantity the published rate uses.

## Provider-Billed Cost

OpenRouter returns what it charged for each call in `usage.cost`, in the response and in the final chunk of a stream. That amount follows the provider it routed to, long-context rates, and image or audio output, which one list price per model cannot. When an OpenAI-compatible response carries a numeric `usage.cost`, the call is recorded at that amount in USD, as one `billed_request` line item with `provider_field: "usage.cost"` and `price_source: "provider_response"`. The token line items keep their counts with no cost. On a BYOK call (`usage.is_byok`), `usage.cost` is only OpenRouter's fee and the provider bills your key separately, so `usage.cost_details.upstream_inference_cost` is added. Registry rates price the call only when the response has no `usage.cost`. Through RubyLLM this applies only to OpenRouter chats; its other OpenRouter calls and other OpenAI-compatible providers keep registry prices.

## Usage and Pricing Coverage

| Surface | Usage capture | Cost behavior |
| --- | --- | --- |
| OpenAI text, cache, reasoning, and audio token usage | Chat, Responses, OpenAI-compatible responses, and provider stream events | Token rates price captured buckets when the model has registry rates |
| OpenAI image generation (`gpt-image-*`) | `images.generate` / `edit` / `create_variation` (one-shot) + `*_stream_raw` (streaming) `usage` block; SDK or Faraday | `image_input` / `image_output` and `input`/`output` text token rates priced separately per modality |
| OpenAI Embeddings | `embeddings.create` `usage.prompt_tokens` | `input` rate prices the call when the model has registry rates |
| OpenAI Transcriptions (`gpt-4o-transcribe*`) | `audio.transcriptions.create` (+ `create_streaming`) `usage` block | `audio_input`, `input`, and `output` rates price captured buckets when present. A transcription with `response_format` `text`, `srt`, or `vtt` returns no `usage` block on any model, so it is recorded as `cost_status: unknown` through the SDK, Faraday and RubyLLM. A response whose `usage` has `type: "duration"`, as in the API reference's `gpt-4o-transcribe-diarize` example, is recorded as `cost_status: unknown` with no `total_cost`, because these models are billed per token and have no per-minute rate |
| OpenAI duration-billed audio (`whisper-1`, `gpt-transcribe`, `gpt-live-transcribe`, `gpt-realtime-whisper`, `gpt-realtime-translate`) | `usage` block with `type: "duration"` | `transcription_minute` rate, per billed second (`usage.seconds`, fractional minutes). These models publish no token price, so the minute is the billing basis. On a regional processing host, `gpt-transcribe` is priced at its `data_residency_transcription_minute` rate, OpenAI's 10% uplift. `audio.translations` (whisper-1 only) and Azure OpenAI Whisper return no usage, so those calls are recorded as `cost_status: unknown` |
| OpenAI Speech (TTS) | `audio.speech.create`, or a Faraday POST to `/v1/audio/speech`: request `input` length (chars) | `text_to_speech_character` rate, per 1M characters, for `tts-1` / `tts-1-hd`; `gpt-4o-mini-tts` is recorded with no line items and no rate because its tokens are not exposed, so it lands `cost_status: unknown` |
| OpenAI Moderations | `moderations.create` request payload | The call is recorded with no line items. OpenAI does not bill the endpoint, and `omni-moderation-latest` and its snapshot `omni-moderation-2024-09-26` are priced at $0, so the call lands `cost_status: free`; other moderation model ids have no entry and land `unknown` |
| OpenAI Realtime `response.done` | Provider stream events passed through `track_stream`; standard Faraday middleware does not auto-capture WebSocket/WebRTC sessions | Audio input/output token rates price the call when the model has registry rates |
| OpenAI hosted web search | `web_search_call` output items with `action.type = "search"` or no action type; every Chat Completions call to a `*-search-preview` or `*-search-api` model | Priced from `service_charges.openai.web_search_request` when present; with the `web_search_preview` tool or a Chat Completions search model, from `web_search_preview_request_reasoning` or `web_search_preview_request_non_reasoning` instead |
| OpenAI web search page actions | `open_page` and `find_in_page` output item actions | Ignored as service charges because they are not separate billable search calls |
| OpenAI hosted file search | `file_search_call` output items | Priced from `service_charges.openai.file_search_call` when present |
| OpenAI Code Interpreter and Hosted Shell containers | `code_interpreter_call` output items and `shell_call` items whose `environment.type` is `container_reference`, deduplicated by container id | Stored as unknown-cost `container_session` rows unless a custom rate matches the captured quantity basis |
| OpenAI image-generation tool calls | Completed `image_generation_call` output items | Stored as unknown-cost `image_generation_call` rows, so the call is `partial`: the Responses usage block covers only the mainline model's tokens, not the image |
| OpenAI computer-use / MCP tool calls | `computer_call`, `mcp_call` output items | Not recorded as line items — billed through the model's tokens (captured separately), with no separate per-call charge |
| Anthropic server web search | `server_tool_use.web_search_requests` | Priced from `service_charges.anthropic.web_search_request` when present |
| Anthropic web fetch | `server_tool_use.web_fetch_requests` | Priced at `$0` from registry — Anthropic bills web fetch through standard tokens, not per fetch |
| Anthropic compaction | `usage.iterations` entries of type `compaction`, which the top-level usage leaves out (anthropic SDK, Faraday middleware, and `track_stream`; not RubyLLM) | Added to the call's tokens at the request model's rates, so an on-demand or paused compaction whose top-level usage is zero is priced, not `free` |
| Anthropic advisor tool and server-side fallback | `usage.iterations` entries of type `advisor_message`, `message` entries of a model that declined before a `fallback_message`, and the `trigger.category` of each `fallback` content block (anthropic SDK, Faraday middleware, and `track_stream`; not RubyLLM) | One `model_iteration` line item per entry, priced at the token rates of the entry's `model` in the call's pricing mode, at standard speed when that model has no fast mode (unknown, and the call `partial`, when that model has no rates; `backfill_unknown_pricing` and `reprice` price it from its stored model and token counts). A declined attempt is recorded when it produced output or when its `fallback` block's category is one Anthropic bills before any output (`bio`, `frontier_llm`, `reasoning_extraction`). The call's `model` is the one in the `fallback_message` entry, which a streamed mid-output fallback reports only there. Fallback-credit repricing is already reflected in the reported cache counts |
| Anthropic refusals | `stop_reason: "refusal"` with `stop_details.category`, in the response or the final stream `message_delta` (anthropic SDK, Faraday middleware, and `track_stream`; not RubyLLM) | A refusal before any output (compaction output counts as output) is recorded at `$0` as a `billed_request` line item, with its token counts kept, unless its category is `bio`, `frontier_llm`, or `reasoning_extraction`, which Anthropic bills at the model's rates. Earlier billed fallback attempts are still added as `model_iteration` line items, and one whose model has no rates makes the call `partial` |
| Anthropic SDK client-side fallback | `Anthropic::BetaRefusalFallbackMiddleware` (anthropic >= 1.54) on `client.beta.messages` | The returned message covers only the last attempt, so each refusal the middleware retried is recorded as its own call, billed by the refusal rules above; a streamed refusal that produced output is instead a `model_iteration` line item on the returned call. A streamed one before any output is recorded as the stream is consumed, with the tags active at that point and without a Bedrock regional profile's `data_residency` rates. Budget and unknown-pricing errors from these extra calls are not raised, so they cannot abort the served call; `on_exceeded` still fires. A stream on which every model declined is recorded under the last model |
| Gemini modality tokens | `usageMetadata.promptTokensDetails` and response token details | Image and audio prompt tokens are priced at `image_input` and `audio_input`, and PDF (`DOCUMENT`) tokens at `image_input`, as Google bills them; these rates equal the model's input rate unless Google publishes a separate audio price (image-generation models publish no audio rate, so their audio prompt tokens stay unpriced); image and audio output tokens use `image_output` and `audio_output` when the model has those rates. Google's `gemini-2.5-flash-image` table publishes only a per-image output price and says text is priced as 2.5 Flash, so its bundled text `output` rates in each tier are 2.5 Flash's |
| Gemini grounding | `groundingMetadata.webSearchQueries` and `imageSearchQueries`; a candidate with Google Maps sources (`groundingChunks[].maps`) is Maps grounding. Interactions API: `usage.grounding_tool_count` | Priced from the model's own `grounding_request` and `maps_grounding_request` rates, which Google publishes per 1,000 requests and which differ by family: per grounded prompt on Gemini 2.x ($35 Search, $25 Maps), per unique non-empty query on 3.x ($14 each). A Maps response without queries counts as one query. The free allowances are account-level and are not modelled, so a project inside them is over-reported |
| Gemini Interactions API | `POST /v1beta/interactions` through Faraday, including `stream: true` (the `interaction.completed` event), `GET /v1beta/interactions/{id}`, and RubyLLM 2.x Gemini chats on `protocol: :interactions` (or `config.gemini_protocol = :interactions`), blocking or streamed | `usage` token counts are priced like `generateContent` usage. A `background: true` interaction returns no usage when created; it is recorded from the first `GET` that returns it out of `queued` and `in_progress`. Each interaction is stored once, however often it is fetched. `:block_requests` does not check a `GET` or `DELETE` before it is sent; like any recorded call over budget, the `GET` that records an interaction still raises `BudgetExceededError` after recording. A stream resumed with `GET ...?stream=true` is not recorded |
| Gemini model | `modelVersion` in the response or stream, else the model in the URL (or the `track_stream` model) | A `-latest` alias such as `gemini-flash-latest` is recorded and priced as the model version that served it. `gemini-3.5-transcribe` and `gemini-2.5-computer-use-preview-10-2025` have no bundled entry, so their calls record `cost_status: unknown` until priced in `pricing.overrides` |
| Groq OpenAI-compatible usage | Chat usage, cached input, reasoning output, and the `service_tier` field from the response (or the request) | Token rates price captured buckets when the model has registry rates |
| xAI OpenAI-compatible usage | Chat and Responses usage, cached input, reasoning output, Chat Completions image prompt tokens, and the `service_tier` field from the response | Reasoning tokens that `total_tokens` counts outside `completion_tokens` or `output_tokens`, as xAI reports them, are added to the output tokens and priced at the output rate, through RubyLLM too; image prompt tokens are priced at the model's input rate |
| RubyLLM chat | `RubyLLM::Provider#complete` (streaming-aware; `Chat#ask` and `Chat#complete` reach this transitively) | Token counts from RubyLLM's response (input, output, cache read/write), the service tier, Anthropic fast mode and US inference (`usage.speed`, `usage.inference_geo`) from its raw body, and OpenAI, xAI, and Mistral regional processing from the configured `openai_api_base`, `xai_api_base`, or `mistral_api_base` host, priced with the same registry as native SDK calls. Server-tool fees come from the raw body too: Anthropic web search (`usage.server_tool_use`), OpenAI Responses tool calls such as `web_search_call`, and Gemini grounding. Gemini chats take their token counts from the raw `usageMetadata` (on the Interactions protocol, the interaction's `usage` and `service_tier`), so audio prompt tokens are priced at `audio_input` and `toolUsePromptTokenCount` (URL context) as input. Streamed chats read the same fields from the stream events RubyLLM parses, except Bedrock streams. When RubyLLM 2.x continues a `pause_turn`, the input of every segment is counted (a streamed segment's from its final `message_delta`), but only the last segment's cache-write split is reported, so earlier segments' writes are priced at the 1-hour rate if the chat uses `with_caching(ttl: "1h")` and at the 5-minute rate otherwise. OpenRouter chats are recorded at the billed `usage.cost` (see above). Bedrock input is read from the raw `inputTokens`, because RubyLLM 1.x subtracts the cache tokens from it again; Bedrock streams on 1.x still record it too low. Bedrock cache writes are split into 5-minute and 1-hour writes by the raw `cacheDetails`; without it (as in Bedrock streams), they are priced at the 1-hour rate when the chat uses `with_caching(ttl: "1h")`. Audio/image token buckets of other providers are not captured |
| RubyLLM embed / transcribe | `RubyLLM::Provider#embed`, `#transcribe` (on RubyLLM 1.x also `RubyLLM::Providers::Gemini::Transcription#transcribe`) | Token counts from RubyLLM's response. A transcription's audio tokens are priced at the model's `audio_input` rate and its prompt text at the text rate when the response splits them (OpenAI `input_token_details`, streamed or not, and Gemini `promptTokensDetails`); without the split, a Gemini transcription's input is priced as text input, and any other's at `audio_input` when the model has one, otherwise as text input. Gemini embeddings take their tokens from the raw `usageMetadata`, which RubyLLM does not report: image, audio, and video parts (`promptTokenDetails`) are priced at `image_input`, `audio_input`, and `video_input`, PDF (`DOCUMENT`) parts at `image_input`, and the rest at the text rate. A transcription without token counts (for example `gpt-transcribe`, `whisper-1`) gets a `transcription_minute` line item from the response's `usage.seconds`, or else from RubyLLM's duration rounded up to whole seconds, which lands `cost_status: unknown` when the model has no `transcription_minute` rate; one with neither, such as a `text` transcript, is recorded as `cost_status: unknown` |
| RubyLLM image / moderation | `RubyLLM::Provider#paint`, `#moderate` | `#paint` records image-token line items when the usage block carries them; `gpt-image-*` output without `output_tokens_details` is priced as image output. Gemini native image models (`gemini-*-image*`, RubyLLM 2.x) price the `IMAGE` tokens of `candidatesTokensDetails` as image output and text and thinking at the text rate; without that split all their output is priced as image output. `#moderate` records the call with no line items, so it lands `cost_status: free` for a $0-priced model such as `omni-moderation-latest` and `unknown` otherwise |
