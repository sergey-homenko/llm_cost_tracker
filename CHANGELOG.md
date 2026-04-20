# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `LlmCostTracker::Retention.prune(older_than:)` and `llm_cost_tracker:prune` rake task.

### Fixed

- Thread-safe price memoization (regression from 0.1.3).
- `by_tag` on MySQL JSON columns.
- CSV export escapes formula-prefixed values.

## [0.2.0.alpha1, 0.2.0.alpha2] - 2026-04-20

### Breaking

- Require Ruby 3.3+ (was 3.1), Rails/ActiveRecord 7.1+ (was 7.0), Faraday 2.0+ (was 1.0).
- `Event`, `Cost`, and `ParsedUsage` are plain `Data.define` value objects; use method access (`event.cost.total_cost`) instead of Hash lookups. `ActiveSupport::Notifications` payloads are unchanged.
- Rename `LlmCostTracker::InvalidFilter` → `InvalidFilterError`.
- Drop `LlmApiCall.by_provider` / `by_model` scopes — use `where(provider:)` / `where(model:)`.
- `ReportData` no longer hardcodes a `"feature"` tag breakdown. Configure `config.report_tag_breakdowns = %w[feature env]` (or pass `tag_breakdowns:` to `ReportData.build` / `Report.generate`). Default is empty.

### Added

- `LlmApiCall.group_by_period(:day/:month)` — SQL-side period grouping.
- Opt-in `LlmCostTracker::Engine` dashboard (Rails 7.1+): overview with delta-vs-previous-period, provider rollup, models, filterable call list with CSV export and outlier sort modes, call details, tag key explorer, per-key tag breakdown, data quality. PostgreSQL/SQLite use adapter-specific SQL; MySQL falls back to an in-Ruby scan capped at 50k rows. Core middleware still works without Rails.

## [0.1.4] - 2026-04-18

### Breaking

- Drop `LlmApiCall.by_user` / `by_feature` scopes and `LlmApiCall#user_id` / `#feature` accessors. Use `by_tag("user_id", id)` / `by_tag("feature", name)` or `by_tags(...)`; read stored tags via `parsed_tags[...]`.
- Drop `ReportData#cost_by_feature` — use `cost_by_tags.fetch("feature")` or `LlmApiCall.cost_by_tag("feature")`.

### Added

- `group_by_tag(key)` / `cost_by_tag(key)` SQL aggregations across any tag key.
- Generic tag breakdowns in reports.

## [0.1.3] - 2026-04-18

### Fixed / Changed

- Mutex-guard `PriceRegistry.file_prices` and `Pricing.sorted_price_keys` memoization.
- Warn on unknown keys in local prices files.
- Document that budget guardrails skip events with unknown pricing.

### Added

- `llm_cost_tracker:prices` generator for a local price override template.
- Callable Faraday `tags:` for per-request Rails attribution via `Current`.
- `llm_cost_tracker:report` rake task.

### Internal

- Extract `Logging`, `TagQuery`, `TagsColumn`, `TagAccessors` helpers; `Cost`, `Event`, `ParsedUsage` value objects; storage backend objects; split `Report` into data + formatter; `OpenaiUsage` composition for OpenAI-compatible providers; move enum validation into `Configuration`; memoize merged prices table; restrict Gemini parser to `generateContent` / `streamGenerateContent`.

## [0.1.2] - 2026-04-18

### Added

- Auto-detect OpenRouter and DeepSeek as OpenAI-compatible.
- `openai_compatible_providers` config for private gateways.
- `BudgetExceededError` + `budget_exceeded_behavior` (`:notify`, `:raise`, `:block_requests`). `:block_requests` is best-effort under concurrency.
- `StorageError` + `storage_error_behavior`; `UnknownPricingError` + `unknown_pricing_behavior`.
- Built-in `prices.json` registry with metadata and source URLs; `prices_file` for local JSON/YAML overrides.
- `with_cost`, `without_cost`, `unknown_pricing` scopes.
- `latency_ms` tracking end-to-end; `with_latency`, `average_latency_ms`, `latency_by_model`, `latency_by_provider`.
- `jsonb` tags + GIN index on PostgreSQL in new migrations; adapter-aware `by_tag` (JSONB containment on PG, text fallback elsewhere); `by_tags` / `by_user` / `by_feature`.
- Generators: `upgrade_tags_to_jsonb`, `upgrade_cost_precision`, `add_latency_ms`.

### Changed

- Tags stored as Hash for JSON-backed columns, JSON text for fallback.
- Normalize provider-prefixed model IDs (e.g. `openai/gpt-4o-mini`) for price lookup.
- Widen generated cost columns to `precision: 20, scale: 8`.
- Count Gemini `thoughtsTokenCount` as output tokens.
- Warn on unreadable streaming/SSE response bodies.
- Route storage exceptions inheriting from `LlmCostTracker::Error` through `storage_error_behavior`.

## [0.1.1] - 2026-04-17

### Fixed

- Lazy-load ActiveRecord storage so `:active_record` persists events reliably.
- Stop double-counting the latest event in monthly budget callbacks.
- Track OpenAI Responses API (`/v1/responses`).
- Parse cached/cache-read/cache-creation token details across OpenAI, Anthropic, Gemini.
- Store tag values as strings so `by_tag("user_id", "42")` matches numeric IDs.

### Changed

- Refresh built-in pricing for current OpenAI, Anthropic, Gemini models.
- Cache-aware cost fields (cached input, cache reads, cache creation).
- Tighten OpenAI URL matching to supported endpoint families.

### Added

- ActiveRecord integration specs; RuboCop config + CI lint step; RubyGems MFA metadata.

## [0.1.0] - 2026-04-16

- Faraday middleware for LLM call interception.
- Parsers: OpenAI, Anthropic, Gemini. Built-in pricing for 20+ models with fuzzy matching.
- `ActiveSupport::Notifications` integration; ActiveRecord backend with scopes and aggregations.
- Manual `LlmCostTracker.track(...)` for non-Faraday clients.
- Per-user / per-feature tagging; monthly budget alerts with configurable callbacks.
- `rails generate llm_cost_tracker:install`; custom storage backend; pricing overrides.
