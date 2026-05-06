# Operations

Production use depends on ActiveRecord health, durable ingestion, bounded hot
paths, and current pricing snapshots.

## Production Defaults

- Size the ActiveRecord connection pool for the host app plus durable inbox writes.
- Keep `default_tags` callables fast and thread-safe.
- Mount the dashboard behind existing admin authentication.
- Run `llm_cost_tracker:doctor` after deploys that change the gem version or schema.
- Treat `:block_requests` as a guardrail, not a strict quota.

## Deployment Checklist

Before building or releasing production images:

- Commit generated migrations and any `config/llm_cost_tracker_prices.yml`
  refresh in the application repository.
- Run app migrations before new processes serve traffic on a schema-changing gem
  version.
- Run `llm_cost_tracker:doctor` after the migration and before considering the
  deploy healthy.
- Run `llm_cost_tracker:verify_capture` in a release job or smoke job that can
  write to the production database safely.
- Keep the dashboard mount behind host-app authentication.
- Treat price files as immutable release config; refresh before image build or
  through an automation that opens a PR.

One app process can need more than its request/job connection. The local
ingestor thread can check out a connection, and capture inside an open caller
transaction uses a separate connection so staged inbox entries survive caller
rollbacks. Size pools for the host app concurrency plus those tracker paths.

## Durable Ingestion

Capture writes a compact row to `llm_cost_tracker_ingestion_inbox_entries`; the
background worker drains rows into `llm_cost_tracker_calls`,
`llm_cost_tracker_call_line_items`, `llm_cost_tracker_call_tags`, and the call
rollups in one transaction per batch.

The inbox is the durability boundary. If the process exits after staging but
before draining, another process can claim the row later through the database
lease.

Use these lifecycle hooks when needed:

```ruby
LlmCostTracker::Ingestion::Worker.flush!(timeout: 5)
LlmCostTracker::Ingestion::Worker.shutdown!(timeout: 5, drain: true)
```

The default process `at_exit` hook stops the local ingestor without forcing every
exiting process to drain the shared inbox. Rows remain durable in the database
and another live process can claim them. Use `flush!` or `shutdown!(drain: true)`
when a job or release step must wait for the ledger to catch up.

## Ruby Concurrency

Threaded Rails servers and fiber schedulers are supported. Scoped tags use
`ActiveSupport::IsolatedExecutionState`, so isolation follows the host Rails
isolation mode. Stream collectors snapshot tag context at creation time, which
keeps tags stable when a stream finishes in another thread or fiber.

Ractors are not a supported runtime boundary for this gem. Rails, ActiveRecord
connections, Faraday middleware registration, configuration objects, Mutex-backed
caches, and the local ingestor thread all assume normal process/thread Rails
execution. If an application uses Ractors for CPU-bound work, keep provider calls
and tracking in the main Rails execution context, or send plain usage data back
and call `LlmCostTracker.track` there.

## Doctor and Verification

```bash
bin/rails llm_cost_tracker:doctor
bin/rails llm_cost_tracker:verify_capture
```

`doctor` checks current schema, durable ingestion tables, line item and tag
tables, call rollups, stale prices, integration setup, and legacy audit columns.

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

Pruning deletes old `llm_cost_tracker_calls`. Dependent line items and tags are
removed by the database via `on_delete: :cascade`. Affected daily/monthly call
rollups are decremented in the same transaction.

## Data Shape

| Data | Storage |
| --- | --- |
| Calls | `llm_cost_tracker_calls` |
| Line items | `llm_cost_tracker_call_line_items` |
| Tags | `llm_cost_tracker_call_tags` |
| Call rollups | `llm_cost_tracker_call_rollups` |
| Provider invoices | `llm_cost_tracker_provider_invoices` |
| Durable inbox | `llm_cost_tracker_ingestion_inbox_entries` |
| Worker lease | `llm_cost_tracker_ingestion_leases` |

Column and index details are documented in [Data Model](data-model.md).

Tag queries join through `llm_cost_tracker_call_tags`, so the same query shape
works on PostgreSQL and MySQL.

## Tags Hygiene

Tags are operational attribution, not a safe place for personal data or
free-form request content. They live in `llm_cost_tracker_call_tags`, render on
the dashboard overview, call details, and tag pages, and ship in CSV export.
Anyone with dashboard or database access can see them.

Use stable internal IDs, feature names, tenant slugs, job names, and environment
labels. Avoid emails, names, prompts, completions, support conversation bodies,
API keys, bearer tokens, or high-cardinality text. Add known sensitive keys to
`redacted_tag_keys`, and keep `max_tag_value_bytesize` low enough to catch
accidental payloads.

## Pricing Refresh

Runtime tracking never fetches provider pricing pages. Refresh tasks are
release-time or operator-initiated:

```bash
bin/rails llm_cost_tracker:prices:refresh
bin/rails llm_cost_tracker:prices:check
```

Refresh writes to `OUTPUT`, then `config.prices_file`, then
`config/llm_cost_tracker_prices.yml`.

## Pricing in Production

Treat the pricing registry as immutable app config. Do not refresh prices from a
running app container, a boot hook, or a release phase that mutates one live
filesystem.

Recommended production paths:

- Commit `config/llm_cost_tracker_prices.yml` and update it through a reviewed
  PR before deploy.
- Run `llm_cost_tracker:prices:check` in CI when the committed file should stay
  current with the maintained snapshot.
- Skip the local file when bundled gem prices are fresh enough for your release
  cadence.

For container deploys, refresh before building the image or in an automation that
opens a PR. Running `prices:refresh` inside one pod can leave replicas using
different price registries until the next restart or deploy.

## Local Development Checks

Run before commits that touch code, generators, migrations, parsers, pricing,
dashboard, or storage:

```bash
bin/check
```

Docs-only changes can be reviewed without the full suite, but release branches
should still run `bin/check` before tagging.
