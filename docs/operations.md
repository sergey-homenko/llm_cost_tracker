# Operations

Production use depends on ActiveRecord health, durable ingestion, bounded hot
paths, and current pricing snapshots.

## Production Defaults

- Size the ActiveRecord connection pool for the host app plus durable inbox writes.
- Keep `default_tags` callables fast and thread-safe.
- Mount the dashboard behind existing admin authentication.
- Run `llm_cost_tracker:doctor` after deploys that change the gem version or schema.
- Treat `:block_requests` as a guardrail, not a strict quota.

## Durable Ingestion

Capture writes a compact row to `llm_cost_tracker_inbox_events`; the background
worker drains rows into `llm_api_calls`, `llm_cost_tracker_service_charges`, and
period rollups in database transactions.

The inbox is the durability boundary. If the process exits after staging but
before draining, another process can claim the row later through the database
lease.

Use these lifecycle hooks when needed:

```ruby
LlmCostTracker.flush!(timeout: 5)
LlmCostTracker.shutdown!(timeout: 5, drain: true)
```

## Doctor and Verification

```bash
bin/rails llm_cost_tracker:doctor
bin/rails llm_cost_tracker:verify_capture
```

`doctor` checks current schema, durable ingestion tables, service charge storage,
period totals, stale prices, integration setup, and legacy audit columns.

`verify_capture` records a synthetic event and verifies both notifications and
ActiveRecord persistence.

## Retention

Retention is explicit:

```bash
DAYS=90 bin/rails llm_cost_tracker:prune
```

Optional batch size:

```bash
DAYS=90 BATCH_SIZE=500 bin/rails llm_cost_tracker:prune
```

Pruning deletes old `llm_api_calls`, deletes dependent service charges, and
decrements affected daily/monthly period totals in the same batch transaction.

## Data Shape

| Data | Storage |
| --- | --- |
| Calls | `llm_api_calls` |
| Service charges | `llm_cost_tracker_service_charges` |
| Tags | PostgreSQL JSONB with GIN index, or MySQL JSON |
| Period totals | `llm_cost_tracker_period_totals` |
| Durable inbox | `llm_cost_tracker_inbox_events` |
| Worker lease | `llm_cost_tracker_ingestor_leases` |

Column and index details are documented in [Data Model](data-model.md).

PostgreSQL is recommended for large tag-heavy ledgers because tag filters can use
JSONB and GIN indexes. MySQL-family adapters are supported through native JSON
and adapter-specific SQL.

## Pricing Refresh

Runtime tracking never fetches provider pricing pages. Refresh tasks are
operator-initiated:

```bash
bin/rails llm_cost_tracker:prices:refresh
bin/rails llm_cost_tracker:prices:check
```

Refresh writes to `OUTPUT`, then `config.prices_file`, then
`config/llm_cost_tracker_prices.yml`.

## Local Development Checks

Run before commits that touch code, generators, migrations, parsers, pricing,
dashboard, or storage:

```bash
bin/check
```

Docs-only changes can be reviewed without the full suite, but release branches
should still run `bin/check` before tagging.
