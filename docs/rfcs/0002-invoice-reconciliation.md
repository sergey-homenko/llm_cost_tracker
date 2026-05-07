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
  source        varchar  NOT NULL, -- "openai", "anthropic", "gemini", "openrouter", ...
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
`provider_workspace_id`, `model`, `pricing_mode`, `line_item_kind` (token
vs. tool), `quantity`, `unit`, `rate_basis`, raw provider payload digest.

`external_id` MUST be globally unique within the table — most providers
expose a row id; for sources that don't, the importer composes a stable
key from `(source, period_start, period_end, dimension fingerprint)`.

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

- `provider_total` — sum of `billed_amount` for the period & scope
- `local_total` — sum of `total_cost` from `llm_cost_tracker_call_rollups`
  for the same period; falls back to a line-items SUM when the period is
  unbounded
- `delta_amount`, `delta_percent`
- `unmatched_provider_rows` — invoice rows we can't tie to a local
  attribution dimension
- `unmatched_local_calls` — calls in the period without any provider
  invoice row that could explain them (batch lag, missed import, etc.)

## Importers

Each provider has its own adapter in `lib/llm_cost_tracker/reconciliation/`:

- `Reconciliation::Importer` — abstract: validates `source`, normalizes
  rows, writes to `provider_invoices`.
- `Reconciliation::Sources::OpenaiUsage` — parses OpenAI Usage API
  responses (organization/usage and organization/costs).
- `Reconciliation::Sources::AnthropicUsage` — Anthropic Usage / Cost API.
- `Reconciliation::Sources::GeminiBilling` — Gemini billing export.
- `Reconciliation::Sources::Csv` — generic CSV adapter for providers
  without an API or for users who already aggregate elsewhere.

Importers MUST NOT run on the hot path. They are operational tools invoked
through a rake task or explicit `LlmCostTracker::Reconciliation.import`
call. Network access is allowed inside an importer, just not from
`Tracker.record` / Faraday middleware / `Pricing.cost_for`.

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
