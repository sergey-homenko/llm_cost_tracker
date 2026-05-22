# Operational Notes

Runtime constraints shape implementation decisions.

## Hot Paths

Hot-path code includes:

- Faraday middleware request and response handling
- stream collection
- `Tracker.record`
- `Pricing.calculate`
- `Pricing::ServiceCharges.charge_rate`
- ActiveRecord event persistence
- budget checks

Hot-path code must avoid:

- network calls
- schema discovery; runtime tracking assumes the current ledger schema
- full ledger aggregation
- unbounded stream buffers
- N+1 queries
- price-refresh work

## Pricing Freshness

Runtime pricing is local:

1. Ruby overrides
2. configured local price snapshot
3. bundled prices

Price update tasks are operational tooling. They can fetch the maintained LLM Cost Tracker price snapshot because the operator runs them intentionally. Request tracking must never depend on live provider pricing pages.

## Budget Reads

Monthly and daily budgets read live `SUM(total_cost)` from `llm_cost_tracker_calls` by default. When `config.cache_rollups = true` they switch to the `llm_cost_tracker_call_rollups` fast path (with its `(period, period_start, currency, provider)` unique index). When `config.ingestion = :async`, pending `llm_cost_tracker_ingestion_inbox_entries` totals are added on top so events that haven't drained yet still count toward guardrails.

Whichever combination is active, the rollup/calls aggregate and the pending inbox total should be read in one database statement so request-time budget checks do not undercount during the inbox-to-ledger handoff.

Per-call budgets are checked from the current event only.

## Async Ingestion

Async ingestion is opt-in via `config.ingestion = :async` plus the `llm_cost_tracker:async_ingestion` generator. With it off (the `:inline` default), `Tracker.record` writes inline through `Ledger::Store.insert` and the worker is dormant.

`Ingestion::Inbox` writes inside an open caller transaction need a separate database connection to survive caller rollbacks. If the pool cannot provide one, storage should raise instead of writing into the caller transaction.

The ingestor is database-leased and database-polled, with an opportunistic local wake after a successful inbox insert. The wake only reduces freshness latency in the process that wrote the row; correctness still comes from the shared database lease, retryable row locks, and adaptive polling across Puma, Sidekiq, Unicorn, deploy restarts, and multi-process hosts.

Freshness and durability are separate concerns. If the writing process exits before its local ingestor drains the row, another process can pick it up on a later poll. Budget reads include pending inbox totals, and operators can call `LlmCostTracker::Ingestion::Worker.flush!` when the ledger must be drained before continuing.

The ingestor should check for claimable rows before acquiring the leader lease. Empty queues should not create steady lease-table writes across an idle fleet.

Batch size is a conservative internal constant. Do not expose it as a
configuration knob until production measurements show that a supported workload
needs tuning.

Ingestors should claim only retryable rows. Rows that keep failing after the retry cap stay in `llm_cost_tracker_ingestion_inbox_entries` with `last_error` for operator inspection and must not block healthy rows behind them.

Process shutdown should stop the local ingestor thread without forcing every exiting process to drain the shared inbox. Operators can call `LlmCostTracker::Ingestion::Worker.flush!` when they intentionally want to wait for the async inbox to drain.

## Retention

Retention may delete old `llm_cost_tracker_calls`. When `config.cache_rollups = true`, retained call rollups are decremented in the same transaction so the budget aggregate stays consistent. Any migration or refactor that changes rollups must preserve the meaning of retained totals or clearly document a breaking change.

## Required Schema

Runtime tracking assumes the current ledger and ingestion schema. Missing schema belongs in doctor/setup failures, not per-event branching.

## Dashboard Queries

Dashboard queries can aggregate because they are user-initiated. They should still use:

- filtered scopes
- bounded pagination
- database-side grouping
- indexes that match common filters
- single aggregate queries for related counters

Avoid loading ledger rows into Ruby to count, sum, group, or sort.

Dashboard storage changes require measured need. Prefer bounded ranges, existing
ledger indexes, pagination, and database-side aggregates over new
dashboard-specific tables. Add a summary table only when a supported dashboard
query cannot be made acceptable with the existing ledger and call rollups.

## Streaming

Streaming capture must keep your app's stream behavior intact.

The middleware should collect enough data to parse final usage while bounding memory. When the byte cap is hit, the buffered prefix is still passed to the parser; the call falls back to unknown only when no usage can be extracted from the retained events.

## Release Checks

Run `bin/check` before committing code changes intended for release. It includes full RuboCop, full RSpec, project coverage, and patch coverage for the current diff.

Project coverage defaults to the Codecov target. Patch coverage defaults to 95% so local checks stay stricter than Codecov parser differences. Thresholds can be adjusted locally with `PROJECT_COVERAGE_MIN`, `PATCH_COVERAGE_MIN`, or `COVERAGE_BASE`.

For the closest match to the Codecov upload job, run `BUNDLE_GEMFILE=gemfiles/rails_8_1.gemfile bin/check`.

Docs-only changes do not require the full suite, but any code, generator, migration, parser, pricing, dashboard, or storage change does.

## Known Limitations

### Inbox batch lock timeout

`Ingestion::Batch` claims rows under a 30-second row-level lock without a heartbeat. If `persist` exceeds 30s, another worker can re-claim the same rows and try to insert them again; the `event_id` unique index on `llm_cost_tracker_calls` raises a duplicate-key error, the first worker's transaction rolls back, and the rows stay claimed (with bumped `attempts`) for retry. Default `BATCH_SIZE = 100` finishes well under 30s on any healthy database. Raising the batch size beyond production-measured persist latency invites re-claim contention — measure first.

### Reconciliation diff loads line items into Ruby

`Reconciliation::Diff` loads scoped line items into Ruby to group unmatched local calls by attribution dimension. Memory grows linearly with the number of matching line items in the window. For installs that bill at the scale where a single reconciliation window covers tens of millions of line items, this is an OOM risk. Diff is `config.reconciliation_enabled = true` experimental and runs on schedule, not per-request — typical installs stay well below the boundary. Narrow the window via `period_start` / `period_end` or smaller `scope:` filters if memory becomes a concern.
