# Upgrading

## v0.7.x → v0.8

**0.8 is a one-shot rebuild of the storage layer.** Per-component cost columns
and the separate `service_charges` table are gone. Tokens and tool/runtime
charges now share one shape and live in a dedicated line items table.

There is no rolling-deploy path — drain the durable inbox on 0.7 first, then
deploy 0.8. Mixed-version processes will fight over schema and ingestion
contract.

### What changed in storage

| Removed | Replaced by |
| --- | --- |
| `llm_cost_tracker_service_charges` (table) | `llm_cost_tracker_call_line_items` (filter `unit != 'token'`) |
| `calls.input_cost`, `calls.output_cost`, `calls.cache_*_cost`, `calls.audio_*_cost` | `call_line_items.cost` keyed by kind / direction / cache_state |
| `calls.tags` (JSONB) | `llm_cost_tracker_call_tags` (one row per `key=value`) |

`calls.total_cost` stays — it's the denormalized header total used for budget
queries and sort columns.

New tables: `llm_cost_tracker_call_line_items`, `llm_cost_tracker_call_tags`,
`llm_cost_tracker_provider_invoices` (reserved for v0.9).

### What changed in API

| Removed | Replaced by |
| --- | --- |
| `Billing::ServiceCharge` value object | `Billing::LineItem` (covers tokens + tool charges) |
| `LlmCostTracker::ServiceCharge` AR model | `LlmCostTracker::CallLineItem` |
| `Event#service_charges` | `Event#line_items.reject(&:token?)` |
| `Call#service_charges` association | `Call#line_items.where.not(unit: "token")` |
| `LlmCostTracker.track(service_charges:)` | `LlmCostTracker.track(service_line_items:)` |
| Hash key `component:` | `component_key:` |
| Hash key `source_key:` | `provider_field:` |
| `pricing_basis: PROVIDER_USAGE_BASIS` | `pricing_basis: :provider_usage` |
| `Billing::CostStatus.call(service_charges:)` | `service_line_items:` |

Inbox payload version stays at `2`; line items are embedded in the existing
shape.

### Upgrade path

Because the storage rebuild touches header columns, child tables, and the
JSONB tag column at once, the gem does not ship an automated 0.7 → 0.8
migration. Two practical paths:

**Path A — drop and reinstall.** Suitable for small ledgers or apps where
historical data isn't critical:

```bash
# 0.7 process: drain pending events
bundle exec rails runner 'LlmCostTracker::Ingestion::Worker.flush!(timeout: 30)'

# Bump the gem
bundle update llm_cost_tracker

# Drop legacy tables, run the new install, migrate
bin/rails generate llm_cost_tracker:install --force
bin/rails db:migrate
bin/rails llm_cost_tracker:doctor
```

You'll lose pre-0.8 history. Re-attribute new traffic going forward; no schema
mismatch to worry about.

**Path B — hand-rolled migration.** For larger ledgers, write a one-off
migration that:

1. Creates the new tables (`call_line_items`, `call_tags`,
   `provider_invoices`) — copy the bodies from the install template at
   `lib/llm_cost_tracker/generators/llm_cost_tracker/templates/create_llm_cost_tracker_calls.rb.erb`.
2. Backfills `call_tags` rows from the JSONB `tags` column.
3. Backfills `call_line_items` rows from per-component cost columns and from
   `llm_cost_tracker_service_charges`.
4. Drops the legacy columns (`input_cost`, `output_cost`, `cache_*_cost`,
   `audio_*_cost`, `tags`) and the `llm_cost_tracker_service_charges` table.

Run it in a maintenance window. `bin/rails llm_cost_tracker:doctor` is the
source of truth for whether the schema matches the gem version.

### What to grep for in your code

```bash
git grep -nE 'service_charges?|ServiceCharge|input_cost|output_cost|cache_[a-z_]*_cost|audio_[a-z_]*_cost'
```

If you build raw `Billing::ServiceCharge.build(...)` calls, swap them for
`Billing::LineItem.build(component_key: ..., quantity: ...)`. If you read
`call.input_cost` etc. in app code, switch to summing line items by component.

### Notifications

`llm_request.llm_cost_tracker` payload no longer carries `service_charges`.
Subscribers that read it must read `line_items` instead and filter by
`unit != "token"` for the tool/runtime portion.

## Releases before 0.8

The 0.x line before 0.8 used a different schema (per-component cost columns,
service_charges table, JSONB tags). Direct upgrades from 0.6.x or earlier go
through 0.7 first, then 0.7 → 0.8 as above.

## Deploy hygiene

- Drain the durable inbox before swapping gem versions:
  `LlmCostTracker::Ingestion::Worker.flush!(timeout: 30)`.
- Run `bin/rails llm_cost_tracker:doctor` after migrating; it checks the
  current schema, line items table, tags table, ingestion tables, and call
  rollups.
- `llm_cost_tracker:setup` is install-time only. Production deploys run
  committed migrations and `doctor`.
