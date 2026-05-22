# Architecture

LLM Cost Tracker is a provider-neutral billing ledger. Core code models
provider-neutral billing concepts; provider-specific API fields stop at
ingestion, integration, and price-scraper boundaries.

## Canonical Vocabulary

Core vocabulary uses provider-neutral terms:

| Concept | Canonical terms |
| --- | --- |
| Text tokens | `input_tokens`, `output_tokens` |
| Cache tokens | `cache_read_input_tokens`, `cache_write_input_tokens`, `cache_write_extended_input_tokens` |
| Audio tokens | `audio_input_tokens`, `audio_output_tokens` |
| Hidden/reasoning tokens | `hidden_output_tokens` |
| Header total | `total_cost` (line items hold per-component breakdown) |
| Pricing tier | `pricing_mode` |
| Pricing audit | `pricing_snapshot`, `cost_status` |
| Provider identity | `provider`, `model`, `provider_response_id`, `provider_project_id`, `provider_api_key_id`, `provider_workspace_id` |
| Provider grouping | `batch`, `pricing_mode` |
| Per-component charges | `Billing::LineItem` (token line items + tool/runtime line items) |

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

## Line Items

Tokens and tool/runtime charges share one shape: `Billing::LineItem`. Parsers
emit token line items from provider usage data and service line items from
tool calls (web search, code execution, grounding, container sessions, file
search). `Pricing.calculate` applies provider/model token rates to
token line items and falls back to per-component rates from
`Pricing.charge_rate` for the rest.

Line items with no matching rate stay `unknown`. They keep the parent call
`partial` when token cost is known, or `unknown` when no reliable cost exists.

Free tiers and account-level reconciliation are not modeled in the ledger.

## Capture Boundaries

Capture paths output `UsageCapture`:

| Boundary | Input | Output |
| --- | --- | --- |
| Faraday middleware | HTTP request/response bodies or SSE chunks | `UsageCapture` |
| SDK integrations | SDK response or stream objects | `UsageCapture` |
| Explicit APIs | Host app token totals or stream events | `UsageCapture` |

`Tracker.record` is the central coordinator. It combines usage capture,
pricing, tags, cost status, notifications, ledger persistence (inline
or via the async inbox depending on `config.ingestion`), and
budget checks.

## Storage Boundaries

Storage is ActiveRecord-only. Mandatory tables, created by
`llm_cost_tracker:install`:

| Table | Responsibility |
| --- | --- |
| `llm_cost_tracker_calls` | Header ledger row per tracked call |
| `llm_cost_tracker_call_line_items` | Per-component cost rows; cascade-deletes with the parent |
| `llm_cost_tracker_call_tags` | Normalized tag rows; cascade-deletes with the parent |

Optional tables, created only by their dedicated generators when the
matching config flag is enabled:

| Table | Generator + flag | Responsibility |
| --- | --- | --- |
| `llm_cost_tracker_call_rollups` | `llm_cost_tracker:call_rollups` + `config.cache_rollups = true` | Pre-aggregated day/month totals per currency/provider for fast budget reads |
| `llm_cost_tracker_ingestion_inbox_entries` | `llm_cost_tracker:async_ingestion` + `config.ingestion = :async` | Write-ahead inbox for the background worker |
| `llm_cost_tracker_ingestion_leases` | same migration as the inbox | Shared worker lease |
| `llm_cost_tracker_provider_invoices` | `llm_cost_tracker:reconciliation` + `config.reconciliation_enabled = true` | Imported provider-side invoice rows |
| `llm_cost_tracker_provider_invoice_imports` | same migration as provider invoices | Importer cursor / window / state for resumable runs |

Runtime tracking assumes the current schema. Schema gaps belong in doctor/setup
failures, not per-event branches.

Column and index details are documented in [Data Model](data-model.md).

## Dashboard and Reporting

Dashboard and report code are read-only projections over the ledger. Views render
prepared data and must not reconstruct billing formulas, token component
semantics, or pricing decisions.

Dashboard queries may aggregate because they are user-initiated, but they should
remain bounded, indexed, and database-side.

## Reconciliation isolation contract

Reconciliation is an experimental opt-in side mode (v0.9) with a
different security plane (admin/org-level provider keys vs. the runtime
inference key). It must not couple to the core tracker:

- `LlmCostTracker::Reconciliation` is autoloaded, not eager-required.
  After `require "llm_cost_tracker"` the namespace stays unloaded until
  someone explicitly accesses it (`Reconciliation.import`,
  `Reconciliation.diff`, the dashboard tab, the rake task).
- Core code paths (`Tracker.record`, parsers, integrations, middleware,
  pricing, billing, ingestion, ledger schema for calls/line_items/tags/
  rollups) carry no references to `Reconciliation`, `ProviderInvoice`,
  or `provider_invoices` tables.
- `LlmCostTracker.reconciliation_enabled?` is the boolean proxy core
  code uses to gate behaviour without triggering autoload. Touching
  `LlmCostTracker::Reconciliation.enabled?` instead would resolve the
  constant and pull the subsystem into memory.
- `Doctor::InvoiceReconciliationCheck` and the controller's
  `reconciliation_schema_checks` only run after the proxy gate; doctor
  and dashboard are no-ops when reconciliation is disabled.
- `attribution_summary` view helper lives in `ReconciliationHelper`,
  not `ApplicationHelper`, so non-reconciliation views never reference
  `Reconciliation::Masking`.
- The install generator creates only core ledger tables. The optional
  `llm_cost_tracker:reconciliation` generator is the only path to
  `provider_invoices` / `provider_invoice_imports` schema.

The contract is verifiable: `LlmCostTracker.autoload?(:Reconciliation)`
returns the file path (autoload pending) on a fresh boot of a
non-reconciliation app. If that ever returns `nil`, something in core
has accidentally referenced the subsystem and pulled it in.

## Technical Docs

- [Module map](technical/module-map.md)
- [Data flow](technical/data-flow.md)
- [Extension points](technical/extension-points.md)
- [Operational notes](technical/operational-notes.md)
