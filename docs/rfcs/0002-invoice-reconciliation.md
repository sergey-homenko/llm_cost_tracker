# RFC 0002: Provider invoice reconciliation

Status: Draft
Target: 0.9.0

## Summary

Import provider-side cost and usage rows into
`llm_cost_tracker_provider_invoices`, diff them against local rollups and
line items per `(source, period_start, period_end)` and the captured
attribution dimensions (`provider_project_id`, `provider_api_key_id`,
`provider_workspace_id`), and surface drift in the dashboard.

This is the reason 0.8 carried those dimension columns into the
`llm_cost_tracker_calls` header and shipped the
`llm_cost_tracker_provider_invoices` placeholder table. With this RFC the
gem stops being an estimator and becomes a reconciler.

## Motivation

Local cost is a forecast computed from a price snapshot. Provider invoice
cost is the bill. For any non-trivial spend the two will drift — bundled
prices lag, snapshot caches go stale, batch discounts apply asynchronously,
hosted tool charges arrive on a separate meter, free-tier credits get
deducted at month boundaries. Without an authoritative comparison source,
the ledger is a guess.

The RFC adds:

1. A storage-side import path that lands provider rows into
   `provider_invoices` idempotently.
2. A diff service that compares imported invoices against local rollups
   and line items by `(source, period_start, period_end)` plus optional
   project / api_key / workspace scoping.
3. Doctor and dashboard surfaces for the diff.

## Storage

Already shipped in 0.8:

```sql
CREATE TABLE llm_cost_tracker_provider_invoices (
  id            bigserial PRIMARY KEY,
  source        varchar  NOT NULL, -- "openai", "anthropic", "gemini", "csv", ...
  period_start  date     NOT NULL,
  period_end    date     NOT NULL,
  external_id   varchar  NOT NULL, -- provider's invoice / line / row id
  billed_amount numeric(20,8),
  currency      varchar  NOT NULL DEFAULT 'USD',
  metadata      jsonb    NOT NULL DEFAULT '{}',
  imported_at   timestamp NOT NULL,
  created_at    timestamp NOT NULL,
  updated_at    timestamp NOT NULL
);

CREATE UNIQUE INDEX ON llm_cost_tracker_provider_invoices (external_id);
CREATE INDEX        ON llm_cost_tracker_provider_invoices (source, period_start);
```

`metadata` carries the provider-specific dimensions that don't deserve a
column: `provider_project_id`, `provider_api_key_id`,
`provider_workspace_id`, `provider_organization_id`, `model`,
`pricing_mode`, `line_item_kind` (token vs. tool), `quantity`, `unit`,
`rate_basis`, raw provider payload digest.

OpenAI scopes projects under an organization, so `organization_id` is
recorded as `provider_organization_id` (informational, not used for
diff matching in v0.9). Anthropic exposes a flat workspace as the
top-level tenant identifier, recorded as `provider_workspace_id` and
used for diff matching when no project is present. Mixing the two would
mis-attribute cross-org tenants.

### Provider meter envelope

Not every provider row is the same kind of evidence. OpenAI exposes both
Usage API (counts, may not match financial truth) and Costs API (the
financial truth used for invoicing). Anthropic exposes Usage and Cost
APIs, with Priority Tier costs visible only via usage. Gemini ships free
quota rows alongside billed rows. Mixing these without a label produces
false totals.

Every importer MUST set the following keys in `metadata`:

| Key | Purpose | Values |
| --- | --- | --- |
| `row_type` | What kind of bookkeeping evidence this row carries | `cost`, `usage`, `credit`, `adjustment`, `free_quota`, `commitment` |
| `meter` | Which meter the row prices | `tokens`, `web_search`, `file_search_storage`, `container_session`, `code_execution_hour`, ... |
| `authority` | Where the row came from | `invoice`, `cost_api`, `usage_api`, `csv`, `estimated` |
| `match_basis` | Which dimension the diff can join on | `project`, `api_key`, `workspace`, `model`, `line_item`, `period_only` |

Diff sums only rows where `row_type == "cost"` against local cost. The
other row types are surfaced separately (free quota usage, credits,
adjustments) so operators can see what's outside the invoice and why.

### `external_id` namespacing

`external_id` is unique across the table — but provider IDs collide across
providers (OpenAI and Anthropic both use prefixed strings, generic CSVs
reuse short ids). Importers MUST prefix their row ids with `<source>:`
(`openai:row_123`, `anthropic:msg_abc`, `csv:line_42`). For providers that
don't expose stable row ids (bucketed Usage APIs, daily aggregates), the
importer composes a stable fingerprint from
`(period_start, period_end, dimension keys)` and prefixes it with the
source.

## Public API

```ruby
LlmCostTracker::Reconciliation.import(
  source: :openai,
  rows:    [...],   # provider-shaped hashes
  imported_at: Time.now.utc
) # => Reconciliation::ImportResult(inserted:, updated:, skipped:, errors:)

LlmCostTracker::Reconciliation.diff(
  source:       :openai,
  period_start: Date.new(2026, 5, 1),
  period_end:   Date.new(2026, 5, 31),
  scope:        { provider_project_id: "proj_abc" } # optional
) # => Reconciliation::DiffResult
```

`import` is idempotent: re-running with the same `external_id` updates the
existing row's `billed_amount` / `metadata` / `imported_at` instead of
inserting a duplicate. The unique index on `external_id` enforces this.

`diff` returns:

- `provider_total` — SUM of `billed_amount` for the period & scope,
  filtered to `metadata.row_type = "cost"`. Free-quota / usage / credit
  rows are excluded from the financial total and surfaced separately.
- `local_total` — SQL `SUM` of the source's local cost in the period
  window. For unscoped diffs whose period bounds align with month
  boundaries the diff reads `SUM(total_cost)` directly from
  `llm_cost_tracker_call_rollups` filtered by `(provider, currency,
  period_start)`. Scoped or partial-bucket diffs scan
  `llm_cost_tracker_call_line_items` joined to
  `llm_cost_tracker_calls` instead. Both compute via SQL `SUM(...)`,
  never by loading rows into Ruby.
- `delta_amount`, `delta_percent`
- `unmatched_provider_rows` — cost rows we can't tie to a local
  attribution dimension
- `unmatched_local_calls` — calls in the period without any provider
  invoice row that could explain them (batch lag, missed import, etc.)
- `non_cost_rows` — buckets of free-quota / credit / adjustment rows
  surfaced separately so operators see "outside the invoice" evidence.

Local calls are filtered by the `provider` name implied by `source`
(`:openai → "openai"`, `:anthropic → "anthropic"`, ...) so that scoping a
diff to OpenAI doesn't accidentally absorb Anthropic calls in the same
period.

## Importers

Each provider has its own adapter in `lib/llm_cost_tracker/reconciliation/`:

- `Reconciliation::Importer` — generic: validates `source`, normalizes
  rows, writes to `provider_invoices`.
- `Reconciliation::Sources::OpenaiUsage` — parses OpenAI Costs and Usage
  API responses (organization-level).
- `Reconciliation::Sources::AnthropicUsage` — Anthropic Usage / Cost API.
- `Reconciliation::Sources::GeminiBilling` — Gemini billing export.
- `Reconciliation::Sources::Csv` — generic CSV adapter for providers
  without an API or for users who already aggregate elsewhere.

Provider-API adapters are **strict**: invalid metadata raises and is
reported in `ImportResult.errors` rather than being silently coerced to
`{}`. The CSV adapter is forgiving because operators may hand-edit it.

Importers MUST be:

- **Idempotent** — re-running the same import upserts on `external_id`,
  never inserts duplicates.
- **Paginated and resumable** — provider Usage/Cost APIs are bucketed and
  cursor-driven; the import drives the cursor, persists position, and
  retries safely.
- **Off the hot path** — they are operational tools invoked through a
  rake task or explicit `LlmCostTracker::Reconciliation.import` call.
  Network access is allowed inside an importer, just not from
  `Tracker.record` / Faraday middleware / `Pricing.cost_for`.

### Resume state

Provider Usage/Cost APIs return data in pages or buckets driven by a
cursor or a `since` timestamp. A long-running import can be killed,
rate-limited, or restarted across deploys; the next run must pick up
where the previous one stopped without re-fetching the whole window.

State lives in a dedicated table, not in `provider_invoices.metadata`:

```sql
CREATE TABLE llm_cost_tracker_provider_invoice_imports (
  id            bigserial PRIMARY KEY,
  source        varchar  NOT NULL,
  cursor        varchar,            -- provider's pagination token, or last successful timestamp
  window_start  date,               -- inclusive bound the importer is currently processing
  window_end    date,               -- exclusive bound the importer is currently processing
  state         varchar  NOT NULL,  -- "running" | "completed" | "failed"
  last_error    text,
  rows_imported integer  NOT NULL DEFAULT 0,
  started_at    timestamp NOT NULL,
  finished_at   timestamp,
  created_at    timestamp NOT NULL,
  updated_at    timestamp NOT NULL
);

CREATE INDEX ON llm_cost_tracker_provider_invoice_imports (source, started_at);
```

Each importer run creates one row, advances `cursor` after each successful
page upsert, and marks the row `completed` on success or `failed` with
`last_error` populated. A subsequent run for the same source picks up
the cursor from the most recent row in any state — `failed` rows are
resumable, `completed` rows just give the natural floor for the next
window.

### Inserted/updated counts are best-effort

The current 2-step `SELECT existing → UPSERT` design exposes a small
race window: a concurrent importer can insert a row between the two
queries. `ImportResult#inserted` / `#updated` are reported as
best-effort and are accurate only when one importer runs at a time per
source. `total_imported` is exact. The race never produces duplicates —
the unique index on `external_id` enforces that.

## Doctor surface

`Doctor::InvoiceReconciliationCheck`:

- `:ok` when the latest closed period has imported invoices and
  `delta_percent.abs <= configured threshold` (default 5%).
- `:warn` when the threshold is exceeded.
- `:warn` when no invoice has been imported for the latest closed period
  in `Doctor::INVOICE_FRESHNESS_DAYS` (default 14) days.
- skipped when `provider_invoices` is empty (gem hasn't been used for
  reconciliation yet).

## Dashboard surface

A new `Reconciliation` page under the dashboard:

- Header: latest period, provider total, local total, delta.
- Per-source breakdown: OpenAI/Anthropic/Gemini rows.
- Drift list: unmatched provider rows, unmatched local calls.
- Last import timestamp + button to trigger a re-import via the configured
  importer (operator-only; route disabled if no importer is configured).

The dashboard reads from `provider_invoices` and `call_rollups`. No new
tables.

## Out of scope for v0.9

- Auto-correcting local `total_cost` from provider rows. The ledger stays
  authoritative for what we computed; provider invoices are an
  independent measurement. Drift is reported, not silently merged.
- Real-time webhook ingestion. v0.9 ships pull-based imports only.
- Multi-currency reconciliation. The diff assumes a single currency per
  source; multi-currency arrives with the rollup currency work landed in
  0.8.

## Migration

No new schema. The 0.8 placeholder table is sufficient for v0.9.

## Open questions

- **Project-level granularity.** Some providers attribute usage at
  org / project / api_key levels with overlapping totals. Needs a
  per-source decision on which level is authoritative. Default: project
  if present, then api_key, then organization-level.
- **Free-tier credit accounting.** Gemini ships separate "billed" and
  "free quota" rows. v0.9 imports both with a `metadata.tier` flag and the
  diff sums billed only.
- **Backfill window.** First import re-fetches up to 90 days. After that,
  imports re-fetch only the most recent closed period plus the current
  open period. Configurable via `Reconciliation.import(window:)`.
