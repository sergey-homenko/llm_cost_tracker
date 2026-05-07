# Upgrading

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

   PostgreSQL:
   ```sql
   INSERT INTO llm_cost_tracker_call_tags (llm_cost_tracker_call_id, key, value)
   SELECT c.id, kv.key, kv.value::text
   FROM llm_cost_tracker_calls c
   CROSS JOIN LATERAL jsonb_each_text(c.tags) AS kv(key, value);
   ```

   MySQL doesn't ship a clean SQL idiom for iterating JSON object keys —
   easiest path is a Ruby script:
   ```ruby
   LlmCostTracker::Call.find_each(batch_size: 500) do |call|
     parsed = call.read_attribute_before_type_cast(:tags)
     parsed = JSON.parse(parsed) if parsed.is_a?(String)
     next if parsed.blank?
     rows = parsed.map { |k, v| { llm_cost_tracker_call_id: call.id, key: k.to_s, value: v.to_s } }
     LlmCostTracker::CallTag.insert_all(rows) if rows.any?
   end
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
