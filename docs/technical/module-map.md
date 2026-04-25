# Module Map

LLM Cost Tracker is organized around a small set of durable responsibilities. File layout does not need to mirror these modules perfectly, but new code should fit one of these boundaries.

## Public API and Configuration

Primary files:

- `lib/llm_cost_tracker.rb`
- `lib/llm_cost_tracker/configuration.rb`
- `lib/llm_cost_tracker/tag_context.rb`
- `lib/llm_cost_tracker/doctor.rb`
- `lib/llm_cost_tracker/logging.rb`
- `lib/llm_cost_tracker/errors.rb`

Responsibilities:

- Expose `configure`, `track`, `track_stream`, `with_tags`, and `enforce_budget!`.
- Keep configuration immutable after `configure` returns.
- Merge scoped tags and default tags without leaking state across threads.
- Report installation and pricing health through `llm_cost_tracker:doctor`.

This module should stay small. It can orchestrate other modules, but it should not contain provider parsing, SQL details, dashboard aggregation, or pricing-source logic.

## SDK Integrations

Primary files:

- `lib/llm_cost_tracker/integrations/*`

Responsibilities:

- Add optional instrumentation for Ruby SDKs without adding provider SDK dependencies.
- Install narrow, idempotent `Module#prepend` wrappers around stable SDK resource methods.
- Extract SDK response objects into canonical usage fields.
- Keep SDK-specific object handling out of `Tracker` and storage.

Integrations are for Ruby SDK object shapes. Parsers are for HTTP and stream payload shapes.

## Ingestion

Primary files:

- `lib/llm_cost_tracker/middleware/faraday.rb`
- `lib/llm_cost_tracker/stream_collector.rb`
- `lib/llm_cost_tracker/parsed_usage.rb`
- `lib/llm_cost_tracker/request_url.rb`
- `lib/llm_cost_tracker/parsers/*`

Responsibilities:

- Detect supported LLM HTTP requests.
- Parse provider responses and stream events into `ParsedUsage`.
- Translate provider-specific fields into canonical usage fields.
- Preserve app streaming behavior while teeing events for tracking.

Provider-specific code belongs here. The output boundary is `ParsedUsage`, not raw provider JSON.

## Canonical Ledger

Primary files:

- `lib/llm_cost_tracker/tracker.rb`
- `lib/llm_cost_tracker/event.rb`
- `lib/llm_cost_tracker/event_metadata.rb`
- `lib/llm_cost_tracker/usage_breakdown.rb`
- `lib/llm_cost_tracker/cost.rb`
- `lib/llm_cost_tracker/unknown_pricing.rb`

Responsibilities:

- Normalize provider, model, usage, tags, latency, streaming flags, and response IDs.
- Price canonical usage through `Pricing`.
- Emit `ActiveSupport::Notifications`.
- Persist the event through the configured storage backend.
- Run budget checks after successful storage.

This module must remain provider-agnostic. It should never branch on a specific provider model family.

## Pricing

Primary files:

- `lib/llm_cost_tracker/pricing.rb`
- `lib/llm_cost_tracker/price_registry.rb`
- `lib/llm_cost_tracker/price_freshness.rb`
- `lib/llm_cost_tracker/prices.json`
- `lib/llm_cost_tracker/price_sync/*`
- `lib/tasks/llm_cost_tracker.rake`

Responsibilities:

- Load bundled prices, local price snapshots, and Ruby overrides.
- Apply pricing precedence: `pricing_overrides`, `prices_file`, bundled prices.
- Calculate costs from canonical usage fields.
- Sync local snapshots from structured price sources.
- Validate large price changes and impossible prices.

Pricing sync must not perform boot-time or request-time network work. Runtime pricing uses bundled prices, local files, and in-memory caches.

## Storage

Primary files:

- `lib/llm_cost_tracker/llm_api_call.rb`
- `lib/llm_cost_tracker/period_total.rb`
- `lib/llm_cost_tracker/storage/active_record_store.rb`
- `lib/llm_cost_tracker/storage/active_record_rollups.rb`
- `lib/llm_cost_tracker/tags_column.rb`
- `lib/llm_cost_tracker/tag_key.rb`
- `lib/llm_cost_tracker/tag_query.rb`
- `lib/llm_cost_tracker/tag_accessors.rb`
- `lib/llm_cost_tracker/period_grouping.rb`

Responsibilities:

- Persist canonical events into ActiveRecord.
- Hide database-specific tag storage differences.
- Maintain period rollups for hot-path budget reads.
- Provide safe scopes for filters, periods, tags, unknown pricing, and reports.

Storage can know about database adapters and optional columns. It should not parse provider responses or fetch price data.

## Budgets and Retention

Primary files:

- `lib/llm_cost_tracker/budget.rb`
- `lib/llm_cost_tracker/retention.rb`
- `lib/llm_cost_tracker/storage/active_record_rollups.rb`

Responsibilities:

- Enforce monthly, daily, and per-call guardrails.
- Support preflight blocking where ActiveRecord rollups are available.
- Prune old ledger rows in batches.
- Keep budget checks bounded by maintained aggregates, not by full ledger scans.

Budget behavior is part of the hot path. Any change here must be measured against per-request overhead.

## Dashboard and Reporting

Primary files:

- `lib/llm_cost_tracker/report*.rb`
- `app/controllers/llm_cost_tracker/*`
- `app/services/llm_cost_tracker/dashboard/*`
- `app/helpers/llm_cost_tracker/*`
- `app/views/llm_cost_tracker/*`
- `app/assets/llm_cost_tracker/application.css`

Responsibilities:

- Render server-side dashboard pages.
- Aggregate spend, calls, providers, models, tags, latency, and data quality.
- Export filtered calls as CSV.
- Keep dashboard queries explicit and indexed.

Dashboard code may run grouped SQL because it is user-initiated reporting. It must stay server-rendered and must not introduce a JavaScript bundle.

## Rails Integration and Generators

Primary files:

- `lib/llm_cost_tracker/railtie.rb`
- `lib/llm_cost_tracker/engine.rb`
- `lib/llm_cost_tracker/assets.rb`
- `lib/llm_cost_tracker/generators/llm_cost_tracker/*`
- `config/routes.rb`

Responsibilities:

- Register rake tasks and Faraday middleware.
- Mount the isolated Rails engine.
- Generate migrations, initializer, dashboard route, and local price snapshots.
- Serve dashboard CSS as a fingerprinted engine asset.

Generator templates are public installation contracts. Treat them like API.

## Test Suites

Primary files:

- `spec/llm_cost_tracker/*`
- `spec/llm_cost_tracker/engine/*`
- `spec/llm_cost_tracker/dashboard/*`
- `spec/fixtures/pricing/*`
- `spec/support/*`

Responsibilities:

- Cover canonical behavior, parser boundaries, pricing precedence, storage rollups, dashboard rendering, generators, and concurrency.
- Keep request specs plain and stable.
- Run through `bin/check` before release work or commits that touch code.
