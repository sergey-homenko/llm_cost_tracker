# Architecture

LLM Cost Tracker is a billing ledger. Core code speaks in billing concepts; provider-specific API fields stop at the ingestion, integration, and price-scraper boundaries.

## Canonical Vocabulary

Core vocabulary uses provider-neutral terms:

| Concept | Canonical terms |
| --- | --- |
| Text tokens | `input_tokens`, `output_tokens` |
| Cache tokens | `cache_read_input_tokens`, `cache_write_input_tokens`, `cache_write_extended_input_tokens` |
| Audio tokens | `audio_input_tokens`, `audio_output_tokens` |
| Image tokens | `image_input_tokens`, `image_output_tokens` |
| Hidden/reasoning tokens | `hidden_output_tokens` |
| Header total | `total_cost` (line items hold per-component breakdown) |
| Pricing tier | `pricing_mode` |
| Pricing audit | `pricing_snapshot`, `cost_status` |
| Provider identity | `provider`, `model`, `provider_response_id`, `provider_project_id`, `provider_api_key_id`, `provider_workspace_id` |
| Provider grouping | `pricing_mode` (and `batch`, derived from it) |
| Per-component charges | `Charges::LineItem` (token line items + tool/runtime line items) |

Provider names such as `service_tier`, `prompt_tokens_details`, `server_tool_use`, or `groundingMetadata` may appear only while reading provider payloads. Past that boundary, code should use canonical terms.

## Dimension Ownership

`Usage::Catalog` is the master registry of billable dimensions. It owns dimension keys, units, directions, modalities, cache states, and rate bases.

Pricing, ledger schema checks, dashboards, reports, and generator templates must derive dimension knowledge from `Usage::Catalog` when the contract is shared. If a boundary must keep an explicit list, add a drift spec.

## Pricing Model

Token pricing uses provider/model registry entries. Price keys mirror canonical component keys:

| Component | Base price key |
| --- | --- |
| Input text | `input` |
| Output text | `output` |
| Cache read | `cache_read_input` |
| Cache write | `cache_write_input` |
| Extended cache write | `cache_write_extended_input` |
| Audio input | `audio_input` |
| Audio output | `audio_output` |
| Image input | `image_input` |
| Image output | `image_output` |

Alternate provider modes use mode-prefixed keys such as `batch_input`, `priority_output`, `flex_audio_input`, or `data_residency_cache_read_input`.

Long-context price tiers use `_context_price_threshold_tokens` and `above_context_*` keys. Parsers emit token buckets; pricing chooses the tier.

When a positive-token bucket has no exact price, that bucket's line item stays unknown instead of guessing from a nearby bucket. The one derivation: under a pricing mode, a bucket other than `input`/`output` with no mode-prefixed rate uses its standard rate scaled by that mode's input discount (for example `cache_read_input` × `batch_input` / `input`).

## Line Items

Tokens and tool/runtime charges share one shape: `Charges::LineItem`. Parsers and SDK integrations emit token counts (`Usage::TokenUsage`) plus service line items for tool calls and non-token usage (web search, web fetch, grounding, container sessions, file search, transcription minutes, TTS characters). `Pricing::Calculation` builds token line items from the counts and applies provider/model token rates; a service line item takes the matched model's own rate when its registry entry has one (`transcription_minute`, `text_to_speech_character`), otherwise `Pricing::ServiceRates.charge_rate`.

Line items with no matching rate stay `unknown`. They keep the parent call `partial` when anything else on it is priced, or `unknown` when nothing is.

Free tiers and account-level reconciliation are not modeled in the ledger.

## Capture Boundaries

Capture paths output `Event`:

| Boundary | Input | Output |
| --- | --- | --- |
| Faraday middleware | HTTP request/response bodies or SSE chunks | `Event` |
| SDK integrations | SDK response or stream objects | `Event` |
| Explicit APIs | Host app token totals or stream events | `Event` |

`Tracker.record` is the central coordinator. It combines usage capture, pricing, tags, cost status, notifications, ledger persistence (inline or via the async inbox depending on `config.ingestion.mode`), and budget checks.

## Storage Boundaries

Storage is ActiveRecord-only. Mandatory tables, created by `llm_cost_tracker:install`:

| Table | Responsibility |
| --- | --- |
| `llm_cost_tracker_calls` | Header ledger row per tracked call |
| `llm_cost_tracker_call_line_items` | Per-component cost rows; cascade-deletes with the parent |
| `llm_cost_tracker_call_tags` | Normalized tag rows; cascade-deletes with the parent |

Optional tables, created only by their dedicated generators when the matching config flag is enabled:

| Table | Generator + flag | Responsibility |
| --- | --- | --- |
| `llm_cost_tracker_call_rollups` | `llm_cost_tracker:call_rollups` + `config.budgets.totals_source = :cache` | Pre-aggregated day/month totals per currency/provider; budget reads take the greater of these and the live sum |
| `llm_cost_tracker_ingestion_inbox_entries` | `llm_cost_tracker:async_ingestion` + `config.ingestion.mode = :async` | Write-ahead inbox for the background worker |
| `llm_cost_tracker_ingestion_leases` | same migration as the inbox | Shared worker lease |

Runtime tracking assumes the current schema. Schema gaps belong in doctor/setup failures, not per-event branches. The exceptions are the opt-in rollups table and per-tag cost columns: when they are missing, budget reads use only the calls ledger and per-tag budgets are skipped, each with a one-time warning.

Column and index details are documented in [Data Model](data-model.md).

## Dashboard and Reporting

Dashboard and report code are read-only projections over the ledger. Views render prepared data and must not reconstruct billing formulas, token component semantics, or pricing decisions.

Dashboard queries may aggregate because they are user-initiated, but they should remain bounded, indexed, and database-side.

## Technical Docs

- [Module map](technical/module-map.md)
- [Data flow](technical/data-flow.md)
- [Extension points](technical/extension-points.md)
- [Operational notes](technical/operational-notes.md)
