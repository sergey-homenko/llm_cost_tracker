# Operations

Production use depends on ActiveRecord health, bounded hot paths, and
current pricing snapshots. Async ingestion and rollups are opt-ins —
turn them on when scale or durability demands it (see [Storage in
Configuration](configuration.md#storage)).

## Production Defaults

- Size the ActiveRecord connection pool for your app's concurrency. If
  `config.ingestion.mode = :async`, add headroom for the local ingestor
  thread, which checks out an ordinary ActiveRecord connection. Inbox
  writes do not: every one of them goes through a pool the gem owns,
  sized by `config.ingestion.pool_size` (default 2), so that a staged
  event survives a caller rollback. Raise that setting, not the app
  pool, if inbox writes start queueing. The default inline path shares
  the caller's connection and joins its transaction.
- Keep `tags.default` callables fast and thread-safe.
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
- Keep the dashboard mount behind your app's authentication.
- Treat price files as immutable release config; refresh before image build or
  through an automation that opens a PR.

When `ingestion = :async` is on, a single app process can need more than
its request/job connection: the local ingestor thread checks out one of
its own, and every inbox write borrows from the gem's own pool
(`config.ingestion.pool_size`, default 2) so staged entries survive
caller rollbacks. Size the app pool for your concurrency plus the
ingestor thread, and `ingestion.pool_size` for concurrent captures.

## Ingestion Path

By default `Tracker.record` writes events synchronously through
`LlmCostTracker::Ledger::Store.insert` straight into the ledger
(`llm_cost_tracker_calls` + line items + tags) — no inbox, no worker,
nothing to drain.

Flip `config.ingestion.mode = :async` (after running
`bin/rails generate llm_cost_tracker:async_ingestion`) when you need:

- Multi-process safe staging — a crashed app worker leaves rows in the
  inbox that another process can pick up via the database lease.
- Insulation from caller transaction rollbacks — staged events survive
  `ActiveRecord::Rollback`.
- Batched inserts — the worker drains rows into
  `llm_cost_tracker_calls`, `llm_cost_tracker_call_line_items`, and
  `llm_cost_tracker_call_tags` in one transaction per batch. With
  `config.budgets.totals_source = :cache` the rollup cache is incremented after that
  transaction commits — a rollup failure is logged and never fails the
  batch; `bin/rails llm_cost_tracker:rebuild_rollups` recovers the cache.

Lifecycle hooks (no-ops in inline mode):

```ruby
LlmCostTracker::Ingestion::Worker.flush!(timeout: 5)
LlmCostTracker::Ingestion::Worker.shutdown!(timeout: 5, drain: true)
```

The default process `at_exit` hook stops the local ingestor without
forcing every exiting process to drain the shared inbox. Rows stay
in the database and another live process can claim them. Use
`flush!` or `shutdown!(drain: true)` when a job or release step must
wait for the ledger to catch up.

`shutdown!` is one-way for the calling process: subsequent
`Tracker.record` calls still enqueue to the inbox (so events aren't
lost), but the local worker thread won't respawn — another live
process picks them up, or a fresh process replaces this one. Don't
call `shutdown!` mid-process unless you intend that contract.

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

`doctor` is a dev/install-time signal. It checks current schema (calls,
line items, tags), the optional inbox/leases/rollups tables that match
your config flags, stale prices, and integration setup. Mismatches between
config flags and present tables (e.g. inbox table exists but
`ingestion = :inline`) surface as `:warn`. Runtime data conditions
(quarantined inbox rows) log to `Rails.logger` from the write path at
the moment they occur — production never runs `doctor` so those signals
must reach the host's own logger.

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

Pruning deletes old `llm_cost_tracker_calls`, then makes a second pass
over `llm_cost_tracker_ingestion_inbox_entries` with the same cutoff.
Dependent line items and tags are removed by the database via
`on_delete: :cascade`. When
`config.budgets.totals_source = :cache`, affected daily/monthly call rollups are
decremented in the same transaction.

## Data Shape

| Data | Storage |
| --- | --- |
| Calls | `llm_cost_tracker_calls` |
| Line items | `llm_cost_tracker_call_line_items` |
| Tags | `llm_cost_tracker_call_tags` |
| Call rollups (opt-in) | `llm_cost_tracker_call_rollups` |
| Async inbox (opt-in) | `llm_cost_tracker_ingestion_inbox_entries` |
| Worker lease (opt-in) | `llm_cost_tracker_ingestion_leases` |

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
`tags.redacted_keys`, and keep `tags.max_value_bytesize` low enough to catch
accidental payloads.

## Pricing Refresh

Runtime tracking never fetches provider pricing pages. Refresh tasks are
release-time or operator-initiated:

```bash
bin/rails llm_cost_tracker:prices:refresh
bin/rails llm_cost_tracker:prices:check
```

Refresh writes to `OUTPUT`, then `config.pricing.file`, then
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
