# RFC 0001: Line-item billing ledger

Status: Implemented (partial) in 0.8
Target: 0.8.0
Originally drafted: pre-0.8 design pass

## Implementation notes

The 0.8 release ships the core of this RFC — header + line items, normalized
tags, unified `Billing::LineItem` covering tokens and tool/runtime charges,
`provider_invoices` placeholder for v0.9 reconciliation. Some of the more
ambitious moves were deferred to keep the upgrade scope manageable and
preserve dashboard/sort ergonomics:

| RFC proposal | What 0.8 shipped |
| --- | --- |
| `calls.id` UUID v4 | bigint `id` + string `event_id`. UUID switch deferred. |
| Drop all token counters from `calls` | Kept on the header as denormalized counters for sort/aggregate; only the per-component cost columns were dropped. |
| Drop `batch` and `stream` from `calls` | Kept; widely read in filters. |
| Inbox payload v3 | Stayed at v2 (v2 was not yet released when 0.8 stabilized). |
| `pricing_mode` as `text[]` / `jsonb` | Kept as a single string (`"batch_data_residency"`). |
| `currency` on `calls` header | Currency lives on line items only. |
| `TokenUsage` as derived view | Still the canonical capture shape on the way in. |
| `provider_reconciliation_imports` table | Renamed to `provider_invoices` (MySQL 64-char identifier limit). |
| `call_tags` PK `(call_id, key)` | Standard bigint PK; index on `(key, value)`. |

Everything below is the original design as proposed. Treat it as the
direction of travel for 0.9-0.10, not a literal description of the shipped
schema. For the as-shipped data model see [Data model](../data-model.md) and
[Architecture](../architecture.md).

## Summary

Replace the wide-row per-call ledger with a header + line-items shape. Each
billable component (text input, output, cache read, web search, code execution,
audio, image, embedding, fine-tuning, ...) becomes its own row. Tags move to a
separate normalized table. Service charges fold into line items.

## Motivation

The 2024 ledger shape assumed text in / text out + a few cache columns. The
2026 LLM landscape has:

- Multi-tier prompt caching as default
- Reasoning tokens as a billed category
- Multimodal pricing (audio, image, video) as core, not extension
- Hosted tool charges (web search, file search, code execution, computer use)
- Long-context tier rates
- Composable pricing modes (batch + data residency + priority)
- Provider org-level invoice reconciliation
- Multi-currency billing
- Free tiers operating at the account level
- Agentic workflows producing 20-50 billed events per user request
- Embeddings, image generation, TTS, STT as first-class workloads

Adding any of these to the current schema requires `ALTER TABLE`. After two or
three more components the row is unmanageable. Reconciliation against provider
invoices needs a line-item shape because that is how providers bill.

## Goals

1. Schema-fluid: a new component is data, not a migration.
2. Reconcilable: rows match provider invoice line items 1:1 where possible.
3. Multi-currency from row zero.
4. Multi-modal: text, audio, image, video, embedding fit the same shape.
5. Backward-compatible public API: `LlmCostTracker.track`, `with_tags`,
   `Call#total_cost`, AR scopes keep working.
6. Backward-compatible subscribers: `event.to_h` keeps the historical shape
   plus a new `line_items` key.

## Non-goals

- No proxy
- No prompt or completion storage
- Multi-cloud aggregation
- OLAP backend
- Eval platform

## Schema

### `llm_cost_tracker_calls` (header)

| column | type | notes |
| --- | --- | --- |
| `id` | uuid | primary key, generated app-side; replaces `id` bigint + `event_id` string |
| `tracked_at` | timestamptz | event time |
| `provider` | string | canonical provider key |
| `model` | string | canonical model key |
| `pricing_mode` | text[] / jsonb | `["batch", "data_residency"]`; ordered, indexable |
| `cost_status` | string | rolled up from line items |
| `total_cost` | decimal(20,8) | cached aggregate; primary read field for budgets |
| `currency` | string | call-level currency; line items can override |
| `usage_source` | string | `response`/`stream_final`/`stream_partial`/`sdk_response`/`manual`/`unknown` |
| `latency_ms` | integer | optional |
| `provider_response_id` | string | provider stable id |
| `provider_project_id` | string | provider org dimension |
| `provider_api_key_id` | string | provider org dimension |
| `provider_workspace_id` | string | provider org dimension |
| `pricing_snapshot` | jsonb | applied rate audit |
| `created_at` | timestamptz | ingestion time, for inbox lag monitoring |

Indexes: `(tracked_at)`, `(provider, tracked_at)`, `(model, tracked_at)`,
`(cost_status)`, `(provider_response_id)`, `(currency, tracked_at)`.

Removed vs current: `event_id`, `input_tokens`, `output_tokens`,
`cache_read_input_tokens`, `cache_write_input_tokens`,
`cache_write_extended_input_tokens`, `audio_input_tokens`, `audio_output_tokens`,
`hidden_output_tokens`, `total_tokens`, all `*_cost` token columns, `batch`,
`stream`, `tags`, `updated_at`. 33 columns becomes 14.

### `llm_cost_tracker_call_line_items` (new)

| column | type | notes |
| --- | --- | --- |
| `id` | uuid | primary key |
| `call_id` | uuid | FK calls(id), `on delete cascade` |
| `position` | smallint | ordering within the call (0..N) |
| `kind` | string | `text_token` / `audio_token` / `image_token` / `video_token` / `embedding_token` / `web_search_request` / `file_search_call` / `code_execution_hour` / `container_session` / `grounding_request` / `tts_character` / `stt_second` / `fine_tuning_training_token` / `fine_tuning_inference_token` / ... |
| `direction` | string | `input` / `output` / `neither` |
| `modality` | string | `text` / `audio` / `image` / `video` / `embedding` / `none` |
| `cache_state` | string | `none` / `read` / `write_5m` / `write_1h` |
| `quantity` | decimal(30,10) | tokens, requests, hours, sessions, characters, seconds, images |
| `unit` | string | `token` / `request` / `hour` / `session` / `character` / `second` / `image` |
| `rate_amount` | decimal(20,8) | applied per `rate_quantity` |
| `rate_quantity` | decimal(30,10) | normally 1 or 1_000_000 |
| `cost` | decimal(20,8) | calculated cost |
| `currency` | string | line-level currency |
| `cost_status` | string | `complete` / `free` / `unknown`; `partial` is a call-level concept only |
| `pricing_basis` | string | `provider_usage`, etc. |
| `price_key` | string | matched registry key |
| `price_source` | string | `bundled` / `prices_file` / `pricing_overrides` / `provider_admin_api` |
| `price_source_version` | string | source freshness identifier |
| `source_key` | string | provider source field reference |
| `provider_item_id` | string | provider line id when exposed |
| `details` | jsonb | provider audit fields |

Indexes: `(call_id, position)`, `(kind)`,
`(cache_state) where cache_state != 'none'`.

This single table replaces:
- 9 token columns + 9 cost columns on `calls`
- the entire `llm_cost_tracker_service_charges` table

A new component (image gen, TTS, video, anything) becomes a new `kind` value
plus a `Billing::Components` registry entry. No migration.

### `llm_cost_tracker_call_tags` (new)

| column | type | notes |
| --- | --- | --- |
| `call_id` | uuid | FK calls(id), `on delete cascade` |
| `key` | string | tag key |
| `value` | string | tag value |

Primary key: `(call_id, key)`. Index: `(key, value)`.

Replaces JSONB `tags` column. Cross-DB friendly. Faster `GROUP BY tag_key`
queries. Symmetric storage between subscribers and DB.

### `llm_cost_tracker_call_rollups` (modified)

| column | type | notes |
| --- | --- | --- |
| `period` | string | `day` / `month` |
| `period_start` | date | bucket start |
| `currency` | string | rollup currency |
| `total_cost` | decimal(20,8) | cached aggregate |

Primary key: `(period, period_start, currency)`. Multi-currency from row zero.

### `llm_cost_tracker_provider_reconciliation_imports` (new placeholder)

| column | type | notes |
| --- | --- | --- |
| `id` | bigint | primary key |
| `source` | string | `openai_admin` / `anthropic_console` / `gemini_billing` |
| `period_start` | date | invoice period start |
| `period_end` | date | invoice period end |
| `external_id` | string | provider invoice / usage id |
| `billed_amount` | decimal(20,8) | provider amount |
| `currency` | string | invoice currency |
| `metadata` | jsonb | provider-side details |
| `imported_at` | timestamptz | import time |

Indexes: `(source, period_start)`, `(external_id)` unique.

Empty in 0.8.0. Populated by import services in 0.9.0. Doctor exposes drift
between local rollups and imported provider amounts.

### Unchanged

`llm_cost_tracker_ingestion_inbox_entries` keeps its shape. Payload format
moves to schema v3 only. Drain v2 rows before deploy.

`llm_cost_tracker_ingestion_leases` is unchanged.

## Domain types

### `LineItem` (new value object)

```ruby
LineItem = Data.define(
  :kind,
  :direction,
  :modality,
  :cache_state,
  :quantity,
  :unit,
  :rate_amount,
  :rate_quantity,
  :cost,
  :currency,
  :cost_status,
  :pricing_basis,
  :price_key,
  :price_source,
  :price_source_version,
  :source_key,
  :provider_item_id,
  :details
)
```

### `Billing::Components` extended

Each component carries:

- `kind` (`text_token`, `web_search_request`, ...)
- `unit` (`token`, `request`, `hour`, ...)
- `direction` (`input`, `output`, `neither`)
- `modality` (`text`, `audio`, `image`, `video`, `embedding`, `none`)
- `cache_state` (only on token components: `none`/`read`/`write_5m`/`write_1h`)
- `default_price_keys` (e.g., `text_token + input + cache_state=read` maps to
  `cache_read_input` registry key)

Adding a new component (image generation, TTS character, video token) is one
entry in `REGISTRY`, plus a parser change to emit it. No schema change.

### `TokenUsage` becomes a derived view

`TokenUsage` stops being the canonical capture shape. It survives as a
backward-compat helper that aggregates token line items into the historical
struct. Public API (`Call#input_tokens`, `Call#output_tokens`,
`Call#total_tokens`) keeps working through this view.

### `Billing::ServiceCharge` is removed

Service charges become regular line items with `kind != *_token`. No separate
type. The `LlmCostTracker::ServiceCharge` AR model is removed; use
`LlmCostTracker::CallLineItem.where("kind NOT LIKE '%_token'")` instead.

### `UsageCapture` carries line items

```ruby
UsageCapture = Data.define(
  :provider,
  :model,
  :pricing_mode,    # array of strings
  :usage_source,
  :provider_response_id,
  :provider_project_id,
  :provider_api_key_id,
  :provider_workspace_id,
  :line_items       # array of LineItem (without prices yet)
)
```

Parsers emit a `UsageCapture` containing a list of `LineItem` describing what
the call did. Pricing engine prices them. Storage persists them.

## Tracker flow

```
provider response →
  parser →
    UsageCapture(line_items: [LineItem(kind, direction, modality, quantity, ...)]) →
      Pricing.price_line_items(capture) →
        UsageCapture(line_items: [LineItem(... + rate_amount, cost, cost_status)]) →
          Tracker.build_event(capture) →
            Event(line_items, total_cost, cost_status, ...) →
              Notifications.instrument →
                Inbox.save (payload v3) →
                  Worker drains →
                    Store.insert_many:
                      Calls.insert_all
                      CallLineItems.insert_all
                      CallTags.insert_all
                      Rollups.increment_many
```

Order of writes matches today's design. Inbox + Worker + Lease pattern is
unchanged.

## AR models

### `LlmCostTracker::Call`

- Replaces direct `input_tokens` etc. accessors with derived methods that scan
  `line_items`.
- Keeps cached `total_cost` column for hot rollup feed.
- `has_many :line_items, class_name: "LlmCostTracker::CallLineItem"`
- `has_many :tag_records, class_name: "LlmCostTracker::CallTag"`

### `LlmCostTracker::CallLineItem` (new)

`belongs_to :call`. Scopes for `text_token`, `audio_token`, `cache_read`,
`tool`, etc.

### `LlmCostTracker::CallTag` (new)

`belongs_to :call`. Scope `with_key(key)`.

### `LlmCostTracker::ServiceCharge`

Removed. Migrate references.

## Public API impact

### Preserved

- `LlmCostTracker.track(provider:, model:, tokens:, tags:, ...)` — same signature
- `LlmCostTracker.track_stream` — same signature
- `LlmCostTracker.with_tags` — unchanged
- `LlmCostTracker.configure` — unchanged
- `LlmCostTracker::Tracker.enforce_budget!` — unchanged
- `LlmCostTracker::Ingestion::Worker.flush!` / `shutdown!` — unchanged
- `Call.today`, `Call.this_month`, `Call.between(from, to)` — unchanged
- `Call.by_tags(...)` — unchanged signature, internally JOINs `call_tags`
- `Call.cost_by_provider`, `Call.cost_by_model`, `Call.cost_by_tag(key)` — unchanged
- `Call.total_cost`, `Call.total_tokens` — unchanged
- `LlmCostTracker.report` / `Call.daily_costs` — unchanged

### Changed

- `Call#input_tokens`, `Call#output_tokens`, `Call#cache_read_input_tokens`,
  etc. — derived from `line_items` association. Same return type. May trigger
  a query if not preloaded; use `Call.includes(:line_items)`.
- `Call#service_charges` returns line items where `kind != *_token` for
  backward compatibility, but new code should use `Call#line_items`.
- `pricing_mode` returns an array of strings instead of an underscore-joined
  string. Subscribers reading `event.pricing_mode` need to update format
  expectations. Add a deprecation shim that joins on read for one minor
  version.

### Removed

- `Billing::ServiceCharge` value object
- `LlmCostTracker::ServiceCharge` AR model
- `cache_write_extended_input_*` columns on `calls`
- `total_tokens` column on `calls`
- `hidden_output_tokens` column on `calls`
- `batch`, `stream` columns on `calls`
- `tags` JSONB column on `calls`
- `updated_at` columns on `calls`, `service_charges`
- `event_id` column (`id` is now UUID)

### Notifications

Subscribers receive `event.to_h` with the historical token/cost keys
(`token_usage`, `cost`, `service_charges`) **plus** a new `line_items` array.
For one minor version, both shapes coexist; after that, only `line_items`.

## Pricing engine

`Pricing.price_line_items(capture)` walks line items, applies registry rates
per line, returns priced line items. Token line items use `EffectivePrices`
(unchanged). Service-charge line items use `Pricing::ServiceCharges` (unchanged
internally).

`Pricing.cost_for(provider:, model:, tokens:, pricing_mode:)` keeps its
signature for direct callers; internally builds line items, prices them, sums
into the legacy hash shape for backward compatibility.

## Inbox payload v3

```json
{
  "schema_version": 3,
  "id": "uuid",
  "provider": "openai",
  "model": "gpt-5",
  "pricing_mode": ["batch"],
  "cost_status": "complete",
  "total_cost": "0.0625",
  "currency": "USD",
  "usage_source": "response",
  "latency_ms": 240,
  "tracked_at": "2026-05-05T12:00:00.000Z",
  "provider_response_id": "...",
  "provider_project_id": "...",
  "pricing_snapshot": {...},
  "line_items": [
    {"kind": "text_token", "direction": "input", "modality": "text", "cache_state": "none", "quantity": "1000", "unit": "token", "cost": "0.00125", ...},
    {"kind": "text_token", "direction": "output", "modality": "text", "cache_state": "none", "quantity": "500", "unit": "token", "cost": "0.005", ...}
  ],
  "tags": {"feature": "chat", "user_id": "42"}
}
```

v2 rows reject; drain on previous gem version before upgrade.

## Doctor

New checks:
- `call_line_items` schema present
- `call_tags` schema present
- `call_rollups` has `currency` column
- `pricing_snapshot.rates` consistent with stored line items (sample-based)
- Drift between `Call.total_cost` and `SUM(line_items.cost)` per call (sample)

## Dashboard

All services that rendered token / cost columns directly need updates:
- "Token usage" charts → group line items by direction + modality + cache_state
- "Cost by tag" → JOIN `call_tags` instead of JSONB extract
- "Cost by component" → group line items by kind
- CSV export → flatten line items into denormalized rows or summary per call

This is the largest blast radius outside core code.

## Migration

`bin/rails generate llm_cost_tracker:upgrade_to_line_items`:

1. Create `call_line_items`, `call_tags`, `provider_reconciliation_imports`
   tables.
2. Add `currency` column to `call_rollups`, change PK.
3. Backfill loop (in batches, transactional):
   - For each `Call` row:
     - Generate new UUID `id`.
     - Insert into new `calls` table (header columns only).
     - Build line items from token/cost columns + linked service_charges.
     - Insert into `call_line_items`.
     - Build tag rows from JSONB `tags`.
     - Insert into `call_tags`.
4. Migrate FK in `service_charges` (drop after copy).
5. Drop dropped columns from `calls`. Drop `service_charges` table. Drop
   `tags` JSONB column.

Backfill is online and resumable. Use `Retention`-style batched scope.

## Open questions

1. **UUID PK type vs bigint sequence.** UUID v7 (timestamp-ordered) is ideal
   but Ruby 3.3 lacks `SecureRandom.uuid_v7`. Options: (a) Ruby 3.4+ requirement,
   (b) bundle a v7 generator gem, (c) accept v4 random with fragmentation.
   Decision: ship v4 in 0.8, evaluate v7 in 0.9 alongside Ruby 3.4 minimum.
2. **`pricing_mode` storage on MySQL.** Postgres has `text[]`; MySQL has
   `JSON`. Keep both as JSONB-equivalent for portability. Subscribers always
   receive an array; storage is JSON.
3. **`Call.total_tokens` performance.** Sums across line items per call. For
   dashboard top-N queries, may need a cached `total_tokens` column on
   `calls`. Defer until profiling shows it.
4. **Reconciliation timeline.** Do we ship the import services in 0.8 or
   defer to 0.9? Recommend defer; 0.8 ships only the placeholder table.
5. **Component registry data source.** Keep the registry in Ruby code, or
   move to YAML? Keep in Ruby; component metadata is part of the gem product
   shape, not user config.

## Risks

- Migration time on 100M+ row tables: backfill takes hours. Online but I/O
  heavy. Provide `BATCH_SIZE` env var; document maintenance window.
- Subscribers that read `pricing_mode` as a string break. Document and
  provide one-minor-version shim.
- Dashboard query patterns shift to JOINs. Profile representative tenants
  before release.
- More rows per call increase index size on Postgres. Plan for 5-10x
  `call_line_items` row count vs current `calls`.

## Phased delivery plan

This RFC describes the end state. Implementation lands across multiple
sessions:

**Session 1 (this session)**: RFC document, no code.

**Session 2**: Foundation. Build `LineItem` value object, extend
`Billing::Components`, add new schema tables (additive), add new AR models.
Tests stay green.

**Session 3**: Pricing engine + parsers. `Pricing.price_line_items`,
parsers emit `UsageCapture(line_items: ...)`, pricing applies. Tests stay
green via dual-write to legacy columns.

**Session 4**: Storage + Inbox. `Store.insert_many` writes to both old
columns and new line items. Inbox payload v3 with both shapes for one
release. Tests verify dual-write.

**Session 5**: Cutover. Drop old columns. Drop service_charges. Drop tags
JSONB. Drop `Billing::ServiceCharge`. Inbox v3 only.

**Session 6**: Dashboard adaptation. All services that read old columns
move to line items. Views render from new shape.

**Session 7**: Doctor + tests + docs.

Total: 6-7 sessions of focused work. Each session ends with green
`bin/check`.

## Decision required

Before Session 2, confirm:

1. **Path?** B (full rewrite) confirmed above. Yes / no?
2. **Ruby minimum**: stay at 3.3, or bump to 3.4 for `SecureRandom.uuid_v7`?
3. **Reconciliation**: ship empty placeholder in 0.8, full integration in
   0.9? Or full in 0.8?
4. **Dashboard during transition**: keep reading legacy columns, or also
   migrate now?

After confirmation: Session 2 starts.
