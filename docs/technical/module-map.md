# Module Map

LLM Cost Tracker is organized around stable responsibilities. File layout does
not need to mirror this map perfectly, but new code should fit one boundary.

## Public API and Configuration

Primary files:

- `lib/llm_cost_tracker.rb`
- `lib/llm_cost_tracker/configuration.rb`
- `lib/llm_cost_tracker/tags/*`
- `lib/llm_cost_tracker/doctor.rb`
- `lib/llm_cost_tracker/doctor/*`
- `lib/llm_cost_tracker/logging.rb`
- `lib/llm_cost_tracker/errors.rb`

Responsibilities:

- Expose `configure`, `track`, `track_stream`, and `with_tags`.
- Keep configuration immutable after `configure`.
- Merge scoped tags and default tags without leaking across threads or fibers.
- Report installation, integration, pricing, ingestion, and schema health.

This module can orchestrate other modules, but should not contain provider
parsing, SQL details, dashboard aggregation, or pricing-source logic.

## Capture

Primary files:

- `lib/llm_cost_tracker/middleware/faraday.rb`
- `lib/llm_cost_tracker/capture/stream_tracker.rb`
- `lib/llm_cost_tracker/capture/stream_collector.rb`
- `lib/llm_cost_tracker/usage_capture.rb`
- `lib/llm_cost_tracker/parsers/base.rb`, `lib/llm_cost_tracker/parsers.rb` (registry)
- `lib/llm_cost_tracker/providers/<vendor>/parser.rb`

Responsibilities:

- Detect supported LLM HTTP requests.
- Preserve streaming behavior while teeing events for tracking.
- Parse provider responses and stream events into `UsageCapture`.
- Translate provider-specific fields into canonical token usage, pricing mode, response identity, and service line items.

Provider-specific response shape handling belongs here. The output boundary is
`UsageCapture`, not raw provider JSON.

## SDK Integrations

Primary files:

- `lib/llm_cost_tracker/integrations/*`

Responsibilities:

- Add optional instrumentation for Ruby SDKs without provider SDK dependencies.
- Install narrow, idempotent `Module#prepend` wrappers.
- Extract SDK response objects into canonical usage fields.
- Keep SDK-specific object handling out of `Tracker`, storage, and pricing.

Integrations are for Ruby SDK object shapes. Parsers are for HTTP and stream
payload shapes.

## Billing Components

Primary files:

- `lib/llm_cost_tracker/billing/components.rb`
- `lib/llm_cost_tracker/billing/cost_status.rb`
- `lib/llm_cost_tracker/billing/line_item.rb`
- `lib/llm_cost_tracker/token_usage.rb`

Responsibilities:

- Own the billable component registry.
- Own token usage value objects.
- Classify costs as `free`, `complete`, `partial`, or `unknown`.
- Represent priced and unpriced line items (tokens + tool/runtime charges) before persistence.

`Billing::Components` is the master source of billable component metadata.

## Pricing

Primary files:

- `lib/llm_cost_tracker/pricing.rb`
- `lib/llm_cost_tracker/pricing/*`
- `lib/llm_cost_tracker/prices.json`
- `lib/tasks/llm_cost_tracker.rake`
- `scripts/price_scrape/*`

Responsibilities:

- Load bundled prices, local price snapshots, and Ruby overrides.
- Apply pricing precedence: overrides, local file, bundled prices.
- Calculate token costs from canonical `TokenUsage`.
- Price known service line items when the registry has a reliable rate (`charge_rate`).
- Explain unknown or incomplete pricing.
- Refresh local snapshots from the maintained LLM Cost Tracker registry.

Pricing refresh must not run at boot or request time.

## Canonical Event Build

Primary files:

- `lib/llm_cost_tracker/tracker.rb`
- `lib/llm_cost_tracker/event.rb`
- `lib/llm_cost_tracker/budget.rb`

Responsibilities:

- Normalize model identity, usage source, tags, latency, stream flags, and response IDs.
- Apply token and service line item pricing.
- Build pricing snapshot and cost status.
- Emit `ActiveSupport::Notifications`.
- Persist events through `Ledger::Store.insert` (default) or `Ingestion::Inbox` when `config.ingestion = :async`.
- Run budget checks after the event is persisted.

This module must remain provider-neutral.

## Ingestion and Ledger

Primary files:

- `lib/llm_cost_tracker/ingestion.rb`
- `lib/llm_cost_tracker/ingestion/*`
- `lib/llm_cost_tracker/ledger.rb`
- `lib/llm_cost_tracker/ledger/*`
- `app/models/llm_cost_tracker/ingestion/*`
- `app/models/llm_cost_tracker/*`

Responsibilities:

- Persist events inline by default; stage to the async inbox and drain via the worker when `config.ingestion = :async`.
- Claim retryable inbox entries through database leases (async mode only).
- Persist call headers, line items, and tag rows atomically.
- Maintain call rollups for hot-path budget reads when `config.cache_rollups = true`; otherwise budget reads aggregate live from `llm_cost_tracker_calls`.
- Hide PostgreSQL and MySQL-family SQL differences.
- Provide safe scopes for filters, periods, tags, unknown pricing, and reports.

Storage knows database adapters and current schema. It should not parse provider
responses or fetch price data.

## Retention

Primary files:

- `lib/llm_cost_tracker/retention.rb`
- `lib/llm_cost_tracker/ledger/rollups.rb`
- `lib/llm_cost_tracker/ledger/rollups/*`

Responsibilities:

- Prune old ledger rows in batches.
- Let `on_delete: :cascade` clean up dependent line items and tag rows.
- Keep daily and monthly call rollups consistent when `config.cache_rollups = true`.

## Dashboard and Reporting

Primary files:

- `lib/llm_cost_tracker/report.rb`
- `lib/llm_cost_tracker/report/*`
- `app/controllers/llm_cost_tracker/*`
- `app/services/llm_cost_tracker/dashboard/*`
- `app/helpers/llm_cost_tracker/*`
- `app/views/llm_cost_tracker/*`
- `app/assets/llm_cost_tracker/application.css`

Responsibilities:

- Render server-side dashboard pages.
- Aggregate spend, calls, providers, models, tags, latency, pricing status, and tool/runtime charge coverage.
- Export filtered calls as CSV.
- Keep dashboard queries explicit, bounded, and indexed.

Dashboard code may run grouped SQL because it is user-initiated reporting. It
must stay server-rendered and must not introduce a JavaScript bundle.

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

Generator templates are public installation contracts.

## Test Suites

Primary files:

- `spec/llm_cost_tracker/*`
- `spec/llm_cost_tracker/engine/*`
- `spec/scripts/*`
- `spec/support/*`

Responsibilities:

- Cover canonical behavior, parser boundaries, pricing precedence, storage rollups, dashboard rendering, generators, price scrapers, and concurrency.
- Keep request specs plain and stable.
- Run through `bin/check` before release work or commits that touch code.
