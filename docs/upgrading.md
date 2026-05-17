# Upgrading

## v0.9.x → v0.10

v0.10 sharpens the v0.9 line: a pre-send budget gate, multi-currency-aware
pricing snapshots when a `prices_file` declares its currency, zero-config
Azure Foundry capture (`*.services.ai.azure.com` + `/openai/v1/...` paths),
a backfill task for calls that landed without pricing, and two optional
upgrade migrations for the reconciliation surface. One BREAKING change in
the initializer.

### Required: rename `durable_ingestion` (BREAKING)

`config.durable_ingestion = true | false` is replaced by
`config.ingestion = :inline | :async` (default `:inline`). The install
generator is renamed from `llm_cost_tracker:durable_ingestion` to
`llm_cost_tracker:async_ingestion`. Update
`config/initializers/llm_cost_tracker.rb`:

```ruby
LlmCostTracker.configure do |config|
  # Before:
  # config.durable_ingestion = true
  # After:
  config.ingestion = :async
end
```

v0.10 also adds a new optional `config.ingestion_pool_size` (default
`2`) to size the dedicated async-ingestion connection pool — set it
explicitly only if your PG / PgBouncer budget is tight.

The DB schema is unchanged — only the config surface changes.

### Optional: backfill calls priced after the fact

When a model lands in the ledger before its pricing entry is in the
bundled snapshot or your `prices_file`, the call records with no cost
and the Data Quality dashboard's "Unknown pricing by model" panel
flags it. After a `prices:refresh` (or after dropping a
`pricing_overrides` entry into the initializer), run:

```bash
bin/rails llm_cost_tracker:backfill_unknown_pricing
```

The task recomputes `total_cost`, the pricing snapshot, per-component
costs, and the rollup buckets for every call still missing a cost.
Idempotent — calls that already have a cost are skipped.

### Optional: reconciliation schema generators

If `config.reconciliation_enabled = true` and you have invoices
imported on a v0.9 install, the two reconciliation upgrade migrations
listed under `v0.8.x → v0.9` below now ship as separate generators
(`upgrade_provider_invoice_imports_provider`,
`upgrade_provider_invoices_metadata_index`). Run them in order on
existing installs. Doctor surfaces the missing `provider` column and
the missing GIN index on `provider_invoices.metadata` (PostgreSQL).

## v0.8.x → v0.9

v0.9 makes the rollup, inbox, and lease tables opt-in, splits ingestion
between an inline default and an opt-in async inbox, and ships
optional provider invoice reconciliation. Default installs ship with
three mandatory tables (`calls`, `call_line_items`, `call_tags`) plus
whatever opt-ins the host enables.

### Existing v0.9 (rolling preview) installs

Existing installs already have `call_rollups`, `ingestion_inbox_entries`,
and `ingestion_leases`. Their tables are still compatible — only the
defaults changed. Set the matching config flags in the initializer to
keep the previous behavior:

```ruby
LlmCostTracker.configure do |config|
  config.durable_ingestion = true # keep the write-ahead inbox + worker path
  config.cache_rollups     = true # keep budget reads on the rollups fast path
end
```

Without those flags, `Tracker.record` writes inline, budget reads scan
`llm_cost_tracker_calls` live, and the inbox/leases/rollups tables sit
unused (doctor warns until you either flip the flags or drop the
tables).

> v0.10 renamed `config.durable_ingestion = true` to
> `config.ingestion = :async` (BREAKING) — if you're jumping straight
> from v0.8 to v0.10, use the v0.10 names from the
> [v0.9.x → v0.10](#v09x--v010) section above.

If you imported reconciliation invoices on a rolling-preview build,
back-fill the data shape changes before running the diff or the
dashboard reports zero matches:

```sql
UPDATE llm_cost_tracker_provider_invoices SET currency = UPPER(currency);
```

The other two pre-release shape changes — `external_id` now namespaces
`source/provider` for cross-provider sources, and the OpenAI Cost API
tags the organization id under `provider_workspace_id` instead of
`provider_organization_id` — are easier to handle via
`LlmCostTracker::ProviderInvoice.delete_all` + a re-import.

### Fresh installs that need the opt-in tables

Run the matching generators only for the optional capabilities you
want:

```bash
# Async inbox + worker + leases (multi-process safe staging,
# survives caller transaction rollbacks). In v0.9 the generator was
# named `durable_ingestion`; v0.10 renamed it to `async_ingestion`.
bin/rails generate llm_cost_tracker:async_ingestion

# Pre-aggregated daily/monthly rollups for fast budget reads.
bin/rails generate llm_cost_tracker:call_rollups

bin/rails db:migrate
```

After migrating, set the matching `config.durable_ingestion = true` /
`config.cache_rollups = true` so the write path and budget reads use
the new tables. v0.10 users: substitute `config.ingestion = :async`
for the durable-ingestion flag (see the v0.9 → v0.10 section).

### Per-provider rollup column

If you opt in to `cache_rollups`, the `llm_cost_tracker_call_rollups`
table must have the v0.9 `provider` column and the
`(period, period_start, currency, provider)` unique index. Existing
v0.8 rollup tables are upgraded with:

```bash
bin/rails generate llm_cost_tracker:upgrade_call_rollups_provider
bin/rails db:migrate
```

Each step in the generated migration is guarded by `column_exists?` /
`index_exists?`, so re-running it on an already-upgraded schema is a
no-op. Pre-upgrade rollup rows are kept and back-filled with an empty
`provider` value (the new column's default), so existing aggregate
totals stay readable. New events write under their actual provider
key, so per-provider queries see only post-upgrade data until the
empty-provider bucket ages out of retention.

### Image-token columns on `llm_cost_tracker_calls`

v0.9 adds `image_input_tokens` and `image_output_tokens` columns to
`llm_cost_tracker_calls` so OpenAI's `gpt-image-*` family bills
correctly (text and image tokens have different per-1M rates). Doctor
flags the missing columns at startup; fix it with:

```bash
bin/rails generate llm_cost_tracker:upgrade_image_tokens
bin/rails db:migrate
```

The migration only adds columns (defaults to 0); it does not rewrite
existing rows. Independent of the rollups upgrade — order doesn't
matter.

### Optional invoice reconciliation

Reconciliation stays a separate opt-in (config flag plus its own
generator). It needs admin/org-level provider API keys (`sk-admin-…`,
GCP `billing.viewer`, etc.) that runtime apps typically don't have —
skip it entirely if you only use the gem for runtime tracking.

### Optional migration: invoice reconciliation

Run only if you plan to import provider-side invoices:

```bash
bin/rails generate llm_cost_tracker:reconciliation
bin/rails db:migrate
```

Or hand-write (PostgreSQL — for MySQL swap `t.jsonb :metadata, null:
false, default: {}` for `t.json :metadata, null: false`; MySQL JSON
columns don't accept a SQL-level default):

```ruby
require "llm_cost_tracker/ledger/schema/adapter"

class CreateLlmCostTrackerReconciliation < ActiveRecord::Migration[7.1]
  def change
    create_table :llm_cost_tracker_provider_invoices do |t|
      t.string :source, null: false
      t.date :period_start, null: false
      t.date :period_end, null: false
      t.string :external_id, null: false
      t.decimal :billed_amount, precision: 20, scale: 8
      t.string :currency, null: false, default: "USD"
      t.jsonb :metadata, null: false, default: {}
      t.datetime :imported_at, null: false
      t.timestamps
    end

    create_table :llm_cost_tracker_provider_invoice_imports do |t|
      t.string :source, null: false
      t.string :provider, null: false, default: ""
      t.string :cursor
      t.date :window_start
      t.date :window_end
      t.string :state, null: false
      t.text :last_error
      t.integer :rows_imported, null: false, default: 0
      t.datetime :started_at, null: false
      t.datetime :finished_at
      t.timestamps
    end

    add_index :llm_cost_tracker_provider_invoices, :external_id, unique: true
    add_index :llm_cost_tracker_provider_invoices, %i[source currency period_start]
    if LlmCostTracker::Ledger::Schema::Adapter.postgresql?(connection)
      add_index :llm_cost_tracker_provider_invoices, :metadata, using: :gin
    end
    add_index :llm_cost_tracker_provider_invoice_imports, %i[source provider started_at]
  end
end
```

### Reconciliation `provider:` is required for unmapped sources

Pre-0.9 `Reconciliation.import` / `.diff` silently summed local calls
across every provider when the `source` was anything other than
`openai` / `anthropic` / `gemini`. v0.9 derives the provider from a
small built-in mapping (`openai`, `openai_usage`, `anthropic`,
`anthropic_usage`, `gemini`) and requires an explicit `provider:` for
everything else. Update existing call sites:

```ruby
LlmCostTracker::Reconciliation.import(source: :csv, provider: :openai, rows: rows)
LlmCostTracker::Reconciliation.diff(source: :csv, provider: :openai,
                                    period_start: ..., period_end: ...)
```

Rake tasks accept `PROVIDER=`:

```bash
bin/rails llm_cost_tracker:reconcile:import SOURCE=csv PROVIDER=openai INPUT=invoice.json
```

Imports already in the database are recovered transparently — Doctor
and the dashboard read `metadata["provider"]` from the most recent
invoice for a source when no explicit provider is supplied. New
imports always write `metadata["provider"]`.

### Provider-scoped `ProviderInvoiceImport` resume state

`ProviderInvoiceImport.resume_cursor_for` /
`last_completed_window_for` now accept an optional `provider:` keyword
so two providers sharing the same `source` (e.g. `csv/openai` and
`csv/anthropic`) no longer mix resume cursors. The schema gains a
`provider` column with default `""` and a `(source, provider,
started_at)` index that replaces the old `(source, started_at)`:

```bash
bin/rails generate llm_cost_tracker:upgrade_provider_invoice_imports_provider
bin/rails db:migrate
```

Legacy rows back-fill to `provider = ""`. Callers passing
`resume_cursor_for(source)` without `provider:` keep their old
behaviour (latest cursor across all providers on that source).

### Optional GIN index on `provider_invoices.metadata` (PostgreSQL)

`Reconciliation::Diff#apply_metadata_scope` filters invoices with
`metadata @> '<criteria>'::jsonb` (JSONB containment) so the dynamic
metadata-scope filter stays fast on large invoice tables under
PostgreSQL. The default `jsonb_ops` GIN operator class accelerates
`@>` lookups, not `->>` text-extraction filters — direct
`metadata->>'key' = ?` queries still seq-scan. Fresh installs from
`0.10` and later get the index automatically; existing installs can
opt in:

```bash
bin/rails generate llm_cost_tracker:upgrade_provider_invoices_metadata_index
bin/rails db:migrate
```

The migration is a no-op on MySQL.

### Schema drift cache for the dashboard

The engine schema check (which renders the "Setup required" page when
tables drift) is computed once per process and invalidated through
`Rails.application.reloader.to_prepare`. Production picks the result up
on first request and reuses it; development re-checks on each code
reload. **Host test suites that mutate engine tables mid-suite** (e.g.
swapping schema between examples) should call
`LlmCostTracker::Dashboard::SetupState.reset!` to invalidate the cache.

### Re-import dashboard button

`LlmCostTracker.configuration.reconciliation_importers` accepts callables
that the dashboard exposes as a `Re-import <source>` button. **Register
importers that enqueue work (`MyImportJob.perform_later`), not callables
that block on the provider's API.** The button posts synchronously, so a
slow inline importer holds the request and dies on the first proxy /
Heroku 30-second cap.

```ruby
LlmCostTracker.configure do |config|
  config.register_reconciliation_importer(:openai) { OpenaiCostsImportJob.perform_later }
end
```

## v0.7.x → v0.8

**0.8 is a one-shot rebuild of the storage layer.** Per-component cost columns
and the separate `service_charges` table are gone. Tokens and tool/runtime
charges now share one shape and live in a dedicated line items table. Several
tables were also renamed during the v0.8 cycle (`llm_api_calls` →
`llm_cost_tracker_calls`, `llm_cost_tracker_period_totals` →
`llm_cost_tracker_call_rollups`, `llm_cost_tracker_inbox_events` →
`llm_cost_tracker_ingestion_inbox_entries`, `llm_cost_tracker_ingestor_leases` →
`llm_cost_tracker_ingestion_leases`).

There is no rolling-deploy path — drain the durable inbox on 0.7 first, then
deploy 0.8. Mixed-version processes will fight over schema and ingestion
contract.

### Prerequisites

- **Ruby 3.4+ is required.** v0.7 supported 3.2+; v0.8 enforces 3.4 in the
  gemspec. `bundle update llm_cost_tracker` will fail on older Ruby — bump the
  runtime first.
- **Drain the durable inbox on v0.7** before swapping versions. v0.8 dropped
  v0/v1 inbox payload compatibility; only v2 payloads are accepted. Any
  undrained rows produced by v0.6 or earlier will be rejected after the bump.

```bash
# On the v0.7 process, before bumping the gem:
bundle exec rails runner 'LlmCostTracker::Ingestion::Worker.flush!(timeout: 30)'
```

### What changed in storage

| Removed | Replaced by |
| --- | --- |
| `llm_cost_tracker_service_charges` (table) | `llm_cost_tracker_call_line_items` (filter `unit != 'token'`) |
| `calls.input_cost`, `calls.output_cost`, `calls.cache_*_cost`, `calls.audio_*_cost` | `call_line_items.cost` keyed by `kind` / `direction` / `cache_state` |
| `calls.tags` (JSONB / JSON) | `llm_cost_tracker_call_tags` (one row per `key=value`) |

Header columns retained: `total_cost`, all token counters, `latency_ms`,
`stream`, `usage_source`, `provider_response_id`, provider capture dimensions,
`tracked_at`.

New tables: `llm_cost_tracker_call_line_items`, `llm_cost_tracker_call_tags`,
`llm_cost_tracker_provider_invoices` (placeholder reserved for v0.9).

Renamed tables: `llm_api_calls` → `llm_cost_tracker_calls`;
`llm_cost_tracker_period_totals` → `llm_cost_tracker_call_rollups`;
`llm_cost_tracker_inbox_events` → `llm_cost_tracker_ingestion_inbox_entries`;
`llm_cost_tracker_ingestor_leases` → `llm_cost_tracker_ingestion_leases`.

### What changed in API

| Removed | Replaced by |
| --- | --- |
| `Billing::ServiceCharge` value object | `Billing::LineItem` (covers tokens + tool charges) |
| `LlmCostTracker::ServiceCharge` AR model | `LlmCostTracker::CallLineItem` |
| `LlmCostTracker::PeriodTotal` AR model | `LlmCostTracker::CallRollup` |
| `Event#service_charges` | `Event#line_items.reject(&:token?)` |
| `Call#service_charges` association | `Call#line_items.where.not(unit: "token")` |
| `LlmCostTracker.track(service_charges:)` | `LlmCostTracker.track(service_line_items:)` |
| Hash key `component:` | `component_key:` |
| Hash key `source_key:` | `provider_field:` |
| `pricing_basis: PROVIDER_USAGE_BASIS` | `pricing_basis: :provider_usage` |
| `Billing::CostStatus.call(service_charges:)` | `service_line_items:` |
| Top-level `LlmCostTracker.flush!`, `shutdown!`, `enforce_budget!` | Use `LlmCostTracker::Ingestion::Worker.flush!` / `.shutdown!`; `enforce_budget!` is internal |

Inbox payload version stays at `2`; line items are embedded in the existing
shape. v0/v1 payloads are no longer accepted — drain before the bump (see
Prerequisites).

`Call#parsed_tags`, `Call.by_tags`, `Call.by_tag`, `Call.cost_by_tag`, and
`Call.group_by_tag` now read `llm_cost_tracker_call_tags` instead of the JSONB
column. The Ruby API is unchanged; custom queries that joined directly against
`calls.tags` need to switch to the normalized table.

### Upgrade path

Because the storage rebuild touches header columns, child tables, and the
JSONB tag column at once, the gem does not ship an automated 0.7 → 0.8
migration. Two practical paths:

**Path A — drop and reinstall.** Suitable for small ledgers or apps where
historical data isn't critical. Path A **destroys all v0.7 ledger data**. Take
a backup first.

```bash
# 1. Back up the existing tables.
pg_dump -t 'llm_api_calls' \
        -t 'llm_cost_tracker_*' \
        $DATABASE_URL > lct_v07_backup.sql
# (MySQL: mysqldump $DB_NAME llm_api_calls llm_cost_tracker_period_totals \
#   llm_cost_tracker_service_charges llm_cost_tracker_inbox_events \
#   llm_cost_tracker_ingestor_leases > lct_v07_backup.sql)

# 2. On the v0.7 process, drain the durable inbox.
bundle exec rails runner 'LlmCostTracker::Ingestion::Worker.flush!(timeout: 30)'

# 3. Drop legacy tables (skip names that don't exist in your install).
bundle exec rails runner '
  c = ActiveRecord::Base.connection
  %w[
    llm_api_calls
    llm_cost_tracker_calls
    llm_cost_tracker_service_charges
    llm_cost_tracker_period_totals
    llm_cost_tracker_call_rollups
    llm_cost_tracker_inbox_events
    llm_cost_tracker_ingestor_leases
    llm_cost_tracker_ingestion_inbox_entries
    llm_cost_tracker_ingestion_leases
    llm_cost_tracker_provider_invoices
  ].each { |t| c.drop_table(t) if c.data_source_exists?(t) }'

# 4. Bump the gem.
bundle update llm_cost_tracker

# 5. Re-run the install (writes the v0.8 migration) and migrate.
bin/rails generate llm_cost_tracker:install --force
bin/rails db:migrate

# 6. Verify.
bin/rails llm_cost_tracker:doctor
```

You'll lose pre-0.8 history. Re-attribution starts from the next captured call.

**Path B — keep history.** For larger ledgers, write a one-off migration that:

1. **Creates the v0.8 tables** (`call_line_items`, `call_tags`,
   `provider_invoices`, plus renames `period_totals`/`inbox_events`/
   `ingestor_leases` if you're coming from a pre-rename install). Use the install
   template at
   `lib/llm_cost_tracker/generators/llm_cost_tracker/templates/create_llm_cost_tracker_calls.rb.erb`
   as the source of truth for column types and indexes — copy the
   `create_table` blocks for the new tables into your migration verbatim.

2. **Backfills `call_tags` rows from the JSONB / JSON `tags` column.**
   The Ruby path below is the canonical option on every adapter — it
   re-uses `LlmCostTracker::Ledger::Tags::Encoding.encode` so Hash /
   Array tag values are written as the same sorted-keys, no-whitespace
   `JSON.generate(...)` form that `Ledger::Store` writes for new calls.
   That's what `LlmCostTracker::Call.by_tag(key, nested_value)` looks
   up against the `(key, value)` composite index:

   ```ruby
   LlmCostTracker::Call.find_each(batch_size: 500) do |call|
     parsed = call.read_attribute_before_type_cast(:tags)
     parsed = JSON.parse(parsed) if parsed.is_a?(String)
     next if parsed.blank?
     rows = parsed.map do |k, v|
       {
         llm_cost_tracker_call_id: call.id,
         key: k.to_s,
         value: LlmCostTracker::Ledger::Tags::Encoding.encode(v)
       }
     end
     LlmCostTracker::CallTag.insert_all(rows) if rows.any?
   end
   ```

   PostgreSQL also has a pure-SQL shortcut, but **only if your `tags`
   column never stored nested Hash/Array values** (most installs).
   `jsonb_each_text` produces `text` representations whose whitespace
   layout for nested values doesn't match `JSON.generate` — running it
   on installs with nested tag values strands those rows behind
   `Call.by_tag`'s exact-match WHERE clause. For scalar-only `tags`
   (strings / numbers / booleans):

   ```sql
   INSERT INTO llm_cost_tracker_call_tags (llm_cost_tracker_call_id, key, value)
   SELECT c.id, kv.key, kv.value
   FROM llm_cost_tracker_calls c
   CROSS JOIN LATERAL jsonb_each_text(c.tags) AS kv(key, value);
   ```

3. **Backfills `call_line_items` rows.** The mapping from per-component cost
   columns to line items is non-trivial (kind / direction / cache_state /
   modality combinations). Easiest path: run a one-off Ruby script that, for
   each call, reconstructs a `Billing::LineItem.from_token_usage` set from the
   stored `*_tokens` columns and an effective price snapshot, then bulk-inserts
   into `llm_cost_tracker_call_line_items`. Tool/runtime rows already in the
   old `llm_cost_tracker_service_charges` map row-for-row to line items with
   `unit IN ('request', 'session', 'hour')`.

4. **Drops the legacy columns** on the calls table (`input_cost`,
   `output_cost`, `cache_read_input_cost`, `cache_write_input_cost`,
   `cache_write_extended_input_cost`, `cache_write_1h_input_cost`,
   `audio_input_cost`, `audio_output_cost`, `tags`) and the
   `llm_cost_tracker_service_charges` table.

Run it in a maintenance window. `bin/rails llm_cost_tracker:doctor` is the
source of truth for whether the schema matches the gem version.

### What to grep for in your code

The grep below targets removed APIs only — it intentionally omits the
`service_charges` key inside the bundled pricing config, which remains a
legitimate price-file section name.

```bash
git grep -nE \
  '(Billing::ServiceCharge|LlmCostTracker::ServiceCharge|PROVIDER_USAGE_BASIS|cost_with_service_charges|service_charges:|Event#service_charges|Call#service_charges|input_cost|output_cost|cache_[a-z_]*_cost|audio_[a-z_]*_cost)'
```

If you build raw `Billing::ServiceCharge.build(...)` calls, swap them for
`Billing::LineItem.build(component_key: ..., quantity: ...)`. If you read
`call.input_cost` etc. in app code, switch to summing line items by component:
`call.line_items.where(kind: 'text_token', direction: 'input').sum(:cost)`.

### Notifications

`llm_request.llm_cost_tracker` payload no longer carries `service_charges`.
Subscribers that read it must read `line_items` instead and filter by
`unit != "token"` for the tool/runtime portion.

## Releases before 0.8

The 0.x line before 0.8 used a different schema (per-component cost columns,
`service_charges` table, JSONB tags, `llm_api_calls`/`period_totals`/
`inbox_events` table names). Direct upgrades from 0.6.x or earlier go through
0.7 first, then 0.7 → 0.8 as above.

## Deploy hygiene

- Drain the durable inbox before swapping gem versions:
  `LlmCostTracker::Ingestion::Worker.flush!(timeout: 30)`.
- Run `bin/rails llm_cost_tracker:doctor` after migrating; it checks the
  current schema, line items table, tags table, provider invoices table,
  ingestion tables, and call rollups.
- `llm_cost_tracker:setup` is install-time only. Production deploys run
  committed migrations and `doctor`.
