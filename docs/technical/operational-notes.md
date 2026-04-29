# Operational Notes

This file describes runtime constraints that should shape implementation decisions.

## Hot Paths

Hot-path code includes:

- Faraday middleware request and response handling
- stream collection
- `Tracker.record`
- `Pricing.cost_for`
- ActiveRecord event persistence
- budget checks

Hot-path code must avoid:

- network calls
- per-event schema discovery beyond memoized checks
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

Monthly and daily budgets should read `llm_cost_tracker_period_totals` when the table exists and add pending `llm_cost_tracker_inbox_events` totals while durable ingestion is enabled. Falling back to summing `llm_api_calls` is an upgrade compatibility path, not the preferred production path.

The stored period total and pending inbox total should be read in one database statement so request-time budget checks do not undercount during the inbox-to-ledger handoff.

Per-call budgets are checked from the current event only.

## Durable Ingestion

Inbox writes inside an open caller transaction need a separate database connection to survive caller rollbacks. If the pool cannot provide one, storage should fail honestly through `storage_error_behavior` instead of writing into the caller transaction and pretending the event is durable.

Ingestors should claim only retryable rows. Rows that keep failing after the retry cap stay in `llm_cost_tracker_inbox_events` with `last_error` for operator inspection and must not block healthy rows behind them.

Process shutdown should stop the local ingestor thread without forcing every exiting process to drain the shared inbox. Operators can call `LlmCostTracker.flush!` when they intentionally want to wait for the durable inbox to drain.

## Retention

Retention may delete old `llm_api_calls`. Period rollups are the durable budget aggregate. Any migration or refactor that changes rollups must preserve the meaning of retained totals or clearly document a breaking change.

## Optional Columns

The gem supports upgrade paths where older apps may not have every column yet. Optional column checks must be memoized and refreshed when ActiveRecord column information is reset.

Do not put table or column checks directly in loops that run for every event without caching.

## Dashboard Queries

Dashboard queries can aggregate because they are user-initiated. They should still use:

- filtered scopes
- bounded pagination
- database-side grouping
- indexes that match common filters
- single aggregate queries for related counters

Avoid loading ledger rows into Ruby just to count, sum, group, or sort.

The dashboard is not the center of the storage design. Prefer bounded ranges, existing ledger indexes, pagination, and database-side aggregates over new dashboard-specific tables. Add a summary table only when a measured supported dashboard query cannot be made acceptable with the existing ledger and period totals.

## Streaming

Streaming capture must keep the host app's stream behavior intact.

The middleware should collect enough data to parse final usage while bounding memory. When usage never arrives or capture overflows, record an unknown-usage event so Data Quality can surface the gap.

## Release Checks

Run `bin/check` before committing code changes intended for release. It includes full RuboCop, full RSpec, project coverage, and patch coverage for the current diff.

Project coverage defaults to the Codecov target. Patch coverage defaults to 95% so local checks stay stricter than Codecov parser differences. Thresholds can be adjusted locally with `PROJECT_COVERAGE_MIN`, `PATCH_COVERAGE_MIN`, or `COVERAGE_BASE`.

For the closest match to the Codecov upload job, run `BUNDLE_GEMFILE=gemfiles/rails_8_1.gemfile bin/check`.

Docs-only changes do not require the full suite, but any code, generator, migration, parser, pricing, dashboard, or storage change does.
