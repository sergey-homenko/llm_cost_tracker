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

Monthly and daily budgets should read `llm_cost_tracker_period_totals` when the table exists. Falling back to summing `llm_api_calls` is an upgrade compatibility path, not the preferred production path.

Per-call budgets are checked from the current event only.

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

## Streaming

Streaming capture must keep the host app's stream behavior intact.

The middleware should collect enough data to parse final usage while bounding memory. When usage never arrives or capture overflows, record an unknown-usage event so Data Quality can surface the gap.

## Release Checks

Run `bin/check` before committing code changes intended for release. It is the local equivalent of the release workflow checks and includes full RuboCop plus full RSpec.

Docs-only changes do not require the full suite, but any code, generator, migration, parser, pricing, dashboard, or storage change does.
