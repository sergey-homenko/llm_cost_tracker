# Data model

LLM Cost Tracker stores everything in your app's database through ActiveRecord.
Supported adapters: PostgreSQL and MySQL-family.

## Tables

| Table | Role |
| --- | --- |
| `llm_cost_tracker_calls` | One row per tracked call. Header totals, attribution dimensions, pricing snapshot. |
| `llm_cost_tracker_call_line_items` | Per-component cost rows: text/audio/cached tokens, tool charges. |
| `llm_cost_tracker_call_tags` | Normalized tag rows for attribution queries. |
| `llm_cost_tracker_call_rollups` | Daily and monthly cost totals for fast budget checks. |
| `llm_cost_tracker_provider_invoices` | Imported provider invoice headers (reserved for v0.9 reconciliation). |
| `llm_cost_tracker_ingestion_inbox_entries` | Durable staging rows the ingestor drains into the ledger. |
| `llm_cost_tracker_ingestion_leases` | Shared lease rows for the ingestion worker. |

`llm_cost_tracker:install` creates the lot. `llm_cost_tracker:doctor` checks
that the schema matches the gem version.

## `llm_cost_tracker_calls`

Header row. One per tracked call (or completed stream).

| Column | Type | Notes |
| --- | --- | --- |
| `id` | primary key | Rails default |
| `event_id` | string, not null | Unique event identity for idempotent ingestion |
| `provider` | string, not null | Canonical provider name |
| `model` | string, not null | Captured or inferred model |
| `input_tokens` | integer, default `0` | Text input tokens |
| `output_tokens` | integer, default `0` | Text output tokens |
| `total_tokens` | integer, default `0` | Provider total or computed |
| `cache_read_input_tokens` | integer, default `0` | Cached input tokens read |
| `cache_write_input_tokens` | integer, default `0` | Standard cache-write input |
| `cache_write_extended_input_tokens` | integer, default `0` | Extended cache-write input |
| `audio_input_tokens` | integer, default `0` | Audio input |
| `audio_output_tokens` | integer, default `0` | Audio output |
| `hidden_output_tokens` | integer, default `0` | Reasoning/hidden output |
| `total_cost` | decimal(20,8) | Total known cost; `nil` when pricing is unknown |
| `latency_ms` | integer | Request latency when captured |
| `stream` | boolean, default `false` | Streamed response |
| `usage_source` | string | `response`, `stream_final`, `manual`, `unknown` |
| `provider_response_id` | string | Stable provider response id |
| `provider_project_id` | string | Provider project/account dimension |
| `provider_api_key_id` | string | Provider API key dimension |
| `provider_workspace_id` | string | Provider workspace/org dimension |
| `batch` | boolean, default `false` | Provider batch path |
| `pricing_mode` | string | `batch`, `flex`, `priority`, etc. |
| `cost_status` | string, default `unknown` | `free`, `complete`, `partial`, `unknown` |
| `pricing_snapshot` | jsonb / json | Applied rate audit snapshot |
| `tracked_at` | datetime, not null | Event timestamp |
| `created_at` / `updated_at` | datetime | Rails timestamps |

Per-component cost values live in `call_line_items`, not on the header. The
header keeps only the denormalized `total_cost` for budget queries and sort
columns.

Indexes:

- unique `event_id` (idempotent ingestion)
- `tracked_at`, `[provider, tracked_at]`, `[model, tracked_at]` (filters)
- `cost_status` (data quality)
- `provider_response_id` (reconciliation)

## `llm_cost_tracker_call_line_items`

One row per priced component on a call. Tokens and tool charges live here in
the same shape.

| Column | Type | Notes |
| --- | --- | --- |
| `llm_cost_tracker_call_id` | bigint, not null | FK with `on_delete: :cascade` |
| `position` | smallint, default `0` | Stable order within a call |
| `kind` | string, not null | `text_token`, `audio_token`, `web_search_request`, `code_execution_request`, `code_execution_hour`, `grounding_request`, `container_session`, `file_search_call` |
| `direction` | string, not null | `input`, `output`, `neither` |
| `modality` | string, not null | `text`, `audio`, `none` |
| `cache_state` | string, default `none` | `none`, `read`, `write_5m`, `write_1h` |
| `quantity` | decimal(30,10) | Token count or charge count |
| `unit` | string, not null | `token`, `request`, `session`, `hour` |
| `rate_amount` | decimal(20,8) | Applied rate when priced |
| `rate_quantity` | decimal(30,10), default `1` | Rate denominator (e.g. 1_000_000 for tokens) |
| `cost` | decimal(20,8) | `quantity / rate_quantity * rate_amount` |
| `currency` | string, default `USD` | Currency for `cost` |
| `cost_status` | string, default `unknown` | `complete`, `free`, `unknown` |
| `pricing_basis` | string | `provider_usage`, `bundled`, `pricing_overrides`, `prices_file` |
| `price_key` | string | Registry key the rate matched |
| `price_source` / `price_source_version` | string | Where the rate came from |
| `provider_field` | string | Path in the provider response (audit) |
| `provider_item_id` | string | Provider item id (audit) |
| `details` | jsonb / json | Free-form provider audit blob |
| `created_at` | datetime | Insert time |

New billing components are added by registering metadata in
`Billing::Components`; no migration needed.

Indexes:

- `[llm_cost_tracker_call_id, position]`
- `kind`

## `llm_cost_tracker_call_tags`

Normalized attribution. One row per `key=value` pair on a call.

| Column | Type | Notes |
| --- | --- | --- |
| `llm_cost_tracker_call_id` | bigint, not null | FK with `on_delete: :cascade` |
| `key` | string, not null | Tag key |
| `value` | text, not null | Tag value (nested hashes are stored as JSON strings) |

Indexes:

- `llm_cost_tracker_call_id`
- `key` (filter by tag key; value-side filtering happens row-wise after seek)

## `llm_cost_tracker_call_rollups`

Maintained daily/monthly totals so budget checks don't scan the full ledger.

| Column | Type | Notes |
| --- | --- | --- |
| `period` | string, not null | `day` or `month` |
| `period_start` | date, not null | Start of the period |
| `total_cost` | decimal(20,8), default `0` | Cost total |
| `created_at` / `updated_at` | datetime | Rails timestamps |

Index: unique `[period, period_start]`.

## `llm_cost_tracker_provider_invoices`

Reserved for v0.9 invoice reconciliation. Written by the upcoming import jobs;
not populated by the ingestor today.

| Column | Type |
| --- | --- |
| `source` | string, not null |
| `period_start` / `period_end` | date, not null |
| `external_id` | string, not null (unique) |
| `billed_amount` | decimal(20,8) |
| `currency` | string, default `USD` |
| `metadata` | jsonb / json |
| `imported_at` | datetime, not null |

## `llm_cost_tracker_ingestion_inbox_entries`

Durable staging. Capture writes here first; the worker drains rows into the
ledger.

| Column | Type | Notes |
| --- | --- | --- |
| `event_id` | string, not null (unique) | |
| `total_cost` | decimal(20,8) | Used by pending budget reads |
| `tracked_at` | datetime, not null | |
| `payload` | text, not null | Versioned JSON payload |
| `locked_at` / `locked_by` | datetime / string | Worker row lock |
| `attempts` | integer, default `0` | Retry count |
| `last_error` | text | Last ingestion error |
| `created_at` / `updated_at` | datetime | |

Indexes: `[tracked_at, attempts]`, `[locked_at, id]`.

## `llm_cost_tracker_ingestion_leases`

Shared lease for the background worker.

| Column | Type |
| --- | --- |
| `name` | string, not null (unique) |
| `locked_by` | string |
| `locked_until` | datetime |
| `created_at` / `updated_at` | datetime |

## JSON fields

| Field | Stored |
| --- | --- |
| `calls.pricing_snapshot` | Schema version, source metadata, currency, applied rates |
| `call_line_items.details` | Provider item details for audit |
| `provider_invoices.metadata` | Invoice metadata blob |
| `ingestion_inbox_entries.payload` | Versioned event payload |

## Schema health

`bin/rails llm_cost_tracker:doctor` verifies the calls schema, JSON column
types, line items, tags, call rollups, and the durable ingestion tables. When
something is missing, the dashboard renders setup guidance instead of running
queries.
