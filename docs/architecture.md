# Architecture

LLM Cost Tracker is a provider-neutral billing ledger. Core code models durable
billing and observability concepts; provider-specific API fields stop at
ingestion, integration, and price-scraper boundaries.

## Canonical Vocabulary

Core vocabulary uses provider-neutral terms:

| Concept | Canonical terms |
| --- | --- |
| Text tokens | `input_tokens`, `output_tokens` |
| Cache tokens | `cache_read_input_tokens`, `cache_write_input_tokens`, `cache_write_extended_input_tokens` |
| Audio tokens | `audio_input_tokens`, `audio_output_tokens` |
| Hidden/reasoning tokens | `hidden_output_tokens` |
| Costs | component cost columns plus `total_cost` |
| Pricing tier | `pricing_mode` |
| Pricing audit | `pricing_snapshot`, `cost_status` |
| Provider identity | `provider`, `model`, `provider_response_id` |
| Tool/runtime usage | `service_charges` |

Provider names such as `service_tier`, `prompt_tokens_details`, `server_tool_use`,
or `groundingMetadata` may appear only while reading provider payloads. Past that
boundary, code should use canonical terms.

## Component Ownership

`Billing::Components` is the master registry for billable components. It owns
component keys, units, categories, directions, modalities, token keys, and cost
keys.

Pricing, ledger schema checks, dashboards, reports, and generator templates must
derive component knowledge from `Billing::Components` when the contract is
shared. If a boundary must keep an explicit list, add a drift spec.

## Pricing Model

Token pricing uses provider/model registry entries. Price keys mirror canonical
component keys:

| Component | Base price key |
| --- | --- |
| Input text | `input` |
| Output text | `output` |
| Cache read | `cache_read_input` |
| Cache write | `cache_write_input` |
| Extended cache write | `cache_write_extended_input` |
| Audio input | `audio_input` |
| Audio output | `audio_output` |

Alternate provider modes use mode-prefixed keys such as `batch_input`,
`priority_output`, `flex_audio_input`, or `data_residency_cache_read_input`.

Long-context price tiers use `_context_price_threshold_tokens` and
`above_context_*` keys. Parsers emit token buckets; pricing chooses the tier.

When a positive-token bucket has no exact price, the event stays unknown instead
of guessing from a nearby bucket. The exception is a documented stackable
multiplier, such as a batch cache-rate discount derived from a published input
discount.

## Service Charges

`service_charges` represent provider-reported tool/runtime usage outside token
prices. They are captured synchronously with the call and stored with the parent
ledger event.

Known-rate charges can be priced through `Pricing.charge_rate`. Unknown-rate
charges remain audit rows and make the parent call `partial` when token cost is
known, or `unknown` when no reliable cost exists.

Free tiers and account-level reconciliation are not modeled in the ledger.

## Capture Boundaries

Capture paths output `UsageCapture`:

| Boundary | Input | Output |
| --- | --- | --- |
| Faraday middleware | HTTP request/response bodies or SSE chunks | `UsageCapture` |
| SDK integrations | SDK response or stream objects | `UsageCapture` |
| Explicit APIs | Host app token totals or stream events | `UsageCapture` |

`Tracker.record` is the central coordinator. It combines usage capture, pricing,
tags, cost status, notifications, durable inbox staging, and budget checks.

## Storage Boundaries

Storage is ActiveRecord-only. The current schema is:

| Table | Responsibility |
| --- | --- |
| `llm_cost_tracker_calls` | Parent call ledger |
| `llm_cost_tracker_service_charges` | Provider-reported tool/runtime rows |
| `llm_cost_tracker_period_totals` | Budget rollups |
| `llm_cost_tracker_ingestion_inbox_entries` | Durable ingestion staging |
| `llm_cost_tracker_ingestion_leases` | Shared worker lease |

Runtime tracking assumes the current schema. Schema gaps belong in doctor/setup
failures, not per-event branches.

Column and index details are documented in [Data Model](data-model.md).

## Dashboard and Reporting

Dashboard and report code are read-only projections over the ledger. Views render
prepared data and must not reconstruct billing formulas, token component
semantics, or pricing decisions.

Dashboard queries may aggregate because they are user-initiated, but they should
remain bounded, indexed, and database-side.

## Technical Docs

- [Module map](technical/module-map.md)
- [Data flow](technical/data-flow.md)
- [Extension points](technical/extension-points.md)
- [Operational notes](technical/operational-notes.md)
