# Data Model

LLM Cost Tracker stores data in the host Rails app database through ActiveRecord.
Supported adapters are PostgreSQL and MySQL-family adapters.

## Tables

| Table | Role |
| --- | --- |
| `llm_cost_tracker_calls` | Parent ledger row for one tracked LLM call |
| `llm_cost_tracker_service_charges` | Provider-reported tool/runtime usage tied to a call |
| `llm_cost_tracker_period_totals` | Maintained daily/monthly totals for budget reads |
| `llm_cost_tracker_ingestion_inbox_entries` | Durable staging rows before ledger insertion |
| `llm_cost_tracker_ingestion_leases` | Shared worker lease rows for durable ingestion |

Fresh installs create all tables through `llm_cost_tracker:install`. Existing
installs add missing pieces through the focused generators listed in
[Upgrading](upgrading.md).

## `llm_cost_tracker_calls`

Primary ledger table. One row represents one tracked call or completed stream.

| Column | Type | Notes |
| --- | --- | --- |
| `id` | primary key | Rails default |
| `event_id` | string, not null | Unique event identity used by durable ingestion |
| `provider` | string, not null | Canonical provider identity |
| `model` | string, not null | Captured or inferred model identity |
| `input_tokens` | integer, not null, default `0` | Text input tokens |
| `cache_read_input_tokens` | integer, not null, default `0` | Cached input tokens read from provider cache |
| `cache_write_input_tokens` | integer, not null, default `0` | Standard cache-write input tokens |
| `cache_write_extended_input_tokens` | integer, not null, default `0` | Extended cache-write input tokens |
| `audio_input_tokens` | integer, not null, default `0` | Audio input tokens |
| `output_tokens` | integer, not null, default `0` | Text output tokens |
| `audio_output_tokens` | integer, not null, default `0` | Audio output tokens |
| `total_tokens` | integer, not null, default `0` | Provider total or calculated token total, whichever is larger |
| `hidden_output_tokens` | integer, not null, default `0` | Hidden/reasoning output tokens |
| `input_cost` | decimal, precision `20`, scale `8` | Text input cost |
| `cache_read_input_cost` | decimal, precision `20`, scale `8` | Cached input read cost |
| `cache_write_input_cost` | decimal, precision `20`, scale `8` | Standard cache-write cost |
| `cache_write_extended_input_cost` | decimal, precision `20`, scale `8` | Extended cache-write cost |
| `audio_input_cost` | decimal, precision `20`, scale `8` | Audio input cost |
| `output_cost` | decimal, precision `20`, scale `8` | Text output cost |
| `audio_output_cost` | decimal, precision `20`, scale `8` | Audio output cost |
| `total_cost` | decimal, precision `20`, scale `8` | Total known cost; nil when pricing is unknown |
| `latency_ms` | integer | Request latency in milliseconds when captured |
| `stream` | boolean, not null, default `false` | Whether the row came from stream capture |
| `usage_source` | string | `response`, `stream_final`, `sdk_response`, `manual`, or `unknown` |
| `provider_response_id` | string | Stable provider response id when exposed |
| `pricing_mode` | string | Canonical pricing mode such as `batch`, `flex`, or `priority` |
| `cost_status` | string, not null, default `unknown` | `free`, `complete`, `partial`, or `unknown` |
| `pricing_snapshot` | JSONB on PostgreSQL, JSON on MySQL | Applied pricing audit snapshot |
| `tags` | JSONB on PostgreSQL, JSON on MySQL, not null | Sanitized attribution tags |
| `tracked_at` | datetime, not null | Event timestamp |
| `created_at` | datetime | Rails timestamp |
| `updated_at` | datetime | Rails timestamp |

PostgreSQL installs use a database default of `{}` for `tags`. MySQL-family
installs use JSON without a database default; runtime storage writes a JSON
object for every row.

Indexes:

| Index | Purpose |
| --- | --- |
| unique `event_id` | Idempotent durable ingestion |
| `tracked_at` | Time-range filters and pruning |
| `provider, tracked_at` | Provider/time dashboard filters |
| `model, tracked_at` | Model/time dashboard filters |
| `cost_status` | Data-quality and unknown-pricing filters |
| `provider_response_id` | Provider reconciliation lookup |
| PostgreSQL GIN on `tags` | JSONB tag filters |

## `llm_cost_tracker_service_charges`

Child table for provider-reported tool/runtime usage outside token prices.

| Column | Type | Notes |
| --- | --- | --- |
| `id` | primary key | Rails default |
| `llm_cost_tracker_call_id` | bigint, not null | Parent `llm_cost_tracker_calls` id |
| `charge_id` | string, not null | Unique charge identity |
| `component` | string, not null | Billing component such as `web_search_request` |
| `unit` | string, not null | Component unit such as `request`, `session`, or `hour` |
| `quantity` | decimal, precision `30`, scale `10`, not null | Captured quantity |
| `rate_amount` | decimal, precision `20`, scale `8` | Applied rate amount when priced |
| `rate_quantity` | decimal, precision `30`, scale `10`, not null, default `1` | Quantity basis for `rate_amount` |
| `cost` | decimal, precision `20`, scale `8` | Calculated charge cost when priced |
| `currency` | string, not null, default `USD` | Charge currency |
| `cost_status` | string, not null, default `unknown` | `free`, `complete`, or `unknown` |
| `pricing_basis` | string | Why the charge is priced, free, ignored, or unknown |
| `price_key` | string | Matched registry key when priced |
| `price_source` | string | `builtin`, `file`, or configured source |
| `price_source_version` | string | Version or timestamp for the applied source |
| `source_key` | string | Provider source key from parser output |
| `provider_item_id` | string | Provider item id when exposed |
| `details` | JSONB on PostgreSQL, JSON on MySQL, not null | Provider audit details |
| `created_at` | datetime | Rails timestamp |
| `updated_at` | datetime | Rails timestamp |

Indexes:

| Index | Purpose |
| --- | --- |
| `llm_cost_tracker_call_id` | Call details and dependent pruning |
| unique `charge_id` | Idempotent service charge storage |
| `component` | Service charge coverage and reporting |

## `llm_cost_tracker_period_totals`

Maintained aggregate table for budget checks. Request-time budget checks read
this table instead of scanning `llm_cost_tracker_calls`.

| Column | Type | Notes |
| --- | --- | --- |
| `id` | primary key | Rails default |
| `period` | string, not null | `day` or `month` |
| `period_start` | date, not null | Start date for the period |
| `total_cost` | decimal, precision `20`, scale `8`, not null, default `0` | Known cost total for the period |
| `created_at` | datetime | Rails timestamp |
| `updated_at` | datetime | Rails timestamp |

Indexes:

| Index | Purpose |
| --- | --- |
| unique `period, period_start` | Upsert target for daily/monthly totals |

## `llm_cost_tracker_ingestion_inbox_entries`

Durable ingestion staging table. Capture writes here first; the ingestor drains
rows into the ledger tables in batches.

| Column | Type | Notes |
| --- | --- | --- |
| `id` | primary key | Rails default |
| `event_id` | string, not null | Unique event identity |
| `total_cost` | decimal, precision `20`, scale `8` | Known total cost used by pending budget reads |
| `tracked_at` | datetime, not null | Event timestamp |
| `payload` | text, not null | Versioned JSON payload |
| `locked_at` | datetime | Worker row lock timestamp |
| `locked_by` | string | Worker identity |
| `attempts` | integer, not null, default `0` | Retry count |
| `last_error` | text | Last ingestion error |
| `created_at` | datetime | Rails timestamp |
| `updated_at` | datetime | Rails timestamp |

Indexes:

| Index | Purpose |
| --- | --- |
| unique `event_id` | Idempotent staging |
| `tracked_at, attempts` | Pending budget totals and retryable row lookup |
| `locked_at, id` | Lease expiry and claim ordering |

## `llm_cost_tracker_ingestion_leases`

Shared lease table for background ingestion.

| Column | Type | Notes |
| --- | --- | --- |
| `id` | primary key | Rails default |
| `name` | string, not null | Lease name |
| `locked_by` | string | Worker identity |
| `locked_until` | datetime | Lease expiry |
| `created_at` | datetime | Rails timestamp |
| `updated_at` | datetime | Rails timestamp |

Indexes:

| Index | Purpose |
| --- | --- |
| unique `name` | One active holder per lease name |

## JSON Fields

| Field | Stored data |
| --- | --- |
| `llm_cost_tracker_calls.tags` | Sanitized application attribution tags |
| `llm_cost_tracker_calls.pricing_snapshot` | Schema version, source metadata, currency, and applied token rates |
| `llm_cost_tracker_service_charges.details` | Provider item details used for audit and reconciliation |
| `llm_cost_tracker_ingestion_inbox_entries.payload` | Versioned event payload for durable ingestion |

## Schema Health

`bin/rails llm_cost_tracker:doctor` verifies the current ledger schema, JSON
column types, service charge table, durable ingestion tables, and period totals.
The dashboard renders setup guidance instead of querying when required schema is
missing.
