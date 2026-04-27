# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- RubyLLM SDK integration for chat, embedding, and transcription calls.

### Changed

- SDK integrations now validate minimum versions and method contracts before installing wrappers.

## [0.5.1] - 2026-04-27

### Changed

- Renamed `llm_cost_tracker:prices:sync` to `llm_cost_tracker:prices:refresh` and `LlmCostTracker::PriceSync.sync` to `.refresh`.
- Price refresh now reads the maintained LLM Cost Tracker snapshot, supports `URL` overrides, and writes to `OUTPUT`, `config.prices_file`, or `config/llm_cost_tracker_prices.yml`.
- Price refresh validates snapshot schema and minimum gem version before replacing the local registry.
- Built-in price keys are provider-qualified while older unqualified local price keys continue to load.
- Built-in prices now include OpenAI cached-input rates, OpenAI batch rates, Anthropic/Gemini batch rates, additional OpenAI models, and refreshed provider rates.
- Price refresh writes registry files atomically.

## [0.5.0] - 2026-04-25

### Added

- Optional SDK integrations: `config.instrument :openai`, `:anthropic`, or `:all` patches the official `openai` and `anthropic` gems' resource methods to record usage automatically. Provider SDKs are not added as hard dependencies.
- `LlmCostTracker.with_tags` plus `TagContext` for thread- and fiber-isolated request-scoped tags that flow through middleware, SDK integrations, and `track` / `track_stream`.
- `LlmCostTracker::Doctor` and the `llm_cost_tracker:doctor` rake task for diagnosing storage, schema, optional columns, period totals, integrations, prices, and recent calls.
- `LlmCostTracker::PriceFreshness` helper plus a price-freshness doctor check that warns when bundled or local prices are stale.
- Technical documentation under `docs/technical/` covering architecture, data flow, extension points, module map, and operational notes.

### Changed

- Pricing fuzzy matching now only accepts dated snapshot suffixes instead of guessing new model families.
- Built-in prices include GPT-5.5 and GPT-5.4 variants and drop retired Claude and Gemini entries.
- Missing model identifiers now normalize to `unknown` instead of leaking nil into tracked events.
- `llm_cost_tracker:prices` now generates a full local price snapshot instead of an empty override file.
- Price sync workflow surfaces clearer error context for fetcher failures and skips refresh-plan entries with malformed pricing.
- README, cookbook, and technical docs clarify that `config.instrument` patches official SDKs only; `ruby-openai` (alexrudall) routes through the Faraday middleware via its constructor block, and `ruby_llm` is not auto-captured today because the gem does not expose a Faraday middleware hook.

## [0.4.1] - 2026-04-24

### Changed

- Batched ActiveRecord period rollup writes and budget total reads.
- Memoized schema capability checks and refreshed them on `reset_column_information`.
- Install migration adds `[:model, :tracked_at]` composite index and drops redundant single-column `:provider` / `:model` indexes.
- Data Quality now reads counters and usage sums through one aggregate query.
- Parser URL matching, stream-event extraction, and custom parser registration now share a smaller base/registry extension surface.
- Added cookbook recipes for `ruby-openai`, `anthropic-sdk-ruby`, `gemini-ai`, `langchainrb`, Azure OpenAI, and LiteLLM proxy setups.

### Fixed

- `llm_cost_tracker:add_period_totals` now imports legacy monthly rollups and backfills before adding the unique index.
- Budget docs now describe `:notify` across monthly, daily, and per-call budgets.

## [0.4.0] - 2026-04-24

### Changed

- BREAKING: Canonical usage and pricing now use `cache_read_input` / `cache_write_input` instead of `cached_input` / `cache_creation_input`.
- BREAKING: `Pricing.cost_for` now requires `provider:` and prefers provider-specific price entries before model-only entries.
- BREAKING: Fresh ActiveRecord installs include cache-read, cache-write, and hidden-output token/cost breakdown columns.
- BREAKING: ActiveRecord budget rollups now use `llm_cost_tracker_period_totals`.
- BREAKING: `llm_cost_tracker:add_monthly_totals` was replaced by `llm_cost_tracker:add_period_totals`.
- `llm_cost_tracker:add_usage_breakdown` generator for upgrading existing ActiveRecord installs.
- `llm_cost_tracker:add_period_totals` generator for upgrading existing ActiveRecord installs.
- Generic `pricing_mode` support with mode-prefixed local price keys.
- Data Quality now shows usage bucket totals and hidden-output share.
- Daily budget and per-call budget guardrails.

## [0.3.3] - 2026-04-24

### Added

- Monthly rollup totals for ActiveRecord budget checks, plus `llm_cost_tracker:add_monthly_totals` for upgrading existing installs.

### Changed

- ActiveRecord monthly totals now update through a single atomic upsert.
- Faraday stream capture overflow now records `usage_source: "unknown"` instead of dropping the tracked event.
- Budget `:notify` callbacks now fire only on the first event that crosses the monthly limit.

### Fixed

- Treat `config.enabled = false` as a global kill switch for direct `track` and `track_stream` calls too.
- Deduplicate unknown-pricing warnings per model.
- Detect streaming requests from parsed JSON instead of raw body substring matching.
- Cap automatic SSE capture to avoid unbounded memory growth on large streaming responses.
- Warn that the generated PostgreSQL `tags -> jsonb` upgrade migration rewrites large tables and should run in a maintenance window.

## [0.3.2] - 2026-04-22

### Added

- Test coverage reporting via SimpleCov with LCOV upload to Codecov from CI.
- Repository governance files: `CODE_OF_CONDUCT.md`, `SECURITY.md`, `CONTRIBUTING.md`, and GitHub issue templates.

## [0.3.1] - 2026-04-22

### Added

- `provider_response_id` persistence, parser extraction, and Data Quality coverage for provider-issued response object IDs.

### Changed

- Simplified dashboard helpers, filter normalization, and view templates without changing dashboard behavior.
- Split `PriceSync` internals into smaller components and removed redundant internal wrapper layers.

### Fixed

- Removed inline dashboard JavaScript to keep the engine server-rendered.
- Reset ActiveRecord model column information in storage specs to avoid stale schema state across recreated tables.

## [0.3.0] - 2026-04-22

### Added

- Streaming capture across OpenAI, Anthropic, and Gemini, including `LlmCostTracker.track_stream` for non-Faraday clients.
- `stream` / `usage_source` persistence and dashboard coverage for streamed calls.
- `llm_cost_tracker:prices:sync` and `llm_cost_tracker:prices:check` for keeping local price snapshots current.
- `LlmCostTracker.enforce_budget!` and opt-in `enforce_budget:` keyword for `track` / `track_stream`.

### Changed

- Price refresh now uses structured JSON sources (LiteLLM primary, OpenRouter secondary) instead of scraping provider HTML pages.
- Synced price entries now carry source provenance (`_source`, `_source_version`, `_fetched_at`), while `_source: "manual"` entries remain untouched.
- Manual stream parsing now resolves parsers through the shared registry, so configured OpenAI-compatible providers work the same way as built-in ones.
- `LlmCostTracker.configure` now treats configuration as an immutable snapshot after the block returns; mutating or replacing shared fields through `LlmCostTracker.configuration` raises `FrozenError`.

### Removed

- Public `LlmCostTracker.configuration=` writer; use `LlmCostTracker.configure` to replace configuration snapshots.

## [0.2.0] - 2026-04-20

### Added

- `LlmCostTracker::Retention.prune(older_than:)` and `llm_cost_tracker:prune` rake task.
- Overview: budget projection, previous-period daily spend comparison, spend anomaly alerts.
- Call details: token and cost mix breakdowns.
- Dashboard CSS served as a fingerprinted, immutably-cached file via `LlmCostTracker::AssetsController`.
- Filter dropdowns for Provider and Model, scoped to the current slice.
- Pagination with per-page selector and Stripe-style page window.

### Changed

- Dashboard UI aligned to Tailwind UI Application UI: dot-indicator badges, value-first stat tiles, inset-shadow form inputs, white secondary buttons with `shadow-sm`.
- CSS fully namespaced under `lct-*`; removed bare `body` selector to avoid host-app leakage.

### Fixed

- Thread-safe price memoization (regression from 0.1.3).
- `by_tag` on MySQL JSON columns.
- CSV export escapes formula-prefixed values.
- Portable dashboard sorting across adapters.
- Dashboard shows database errors instead of install/setup guidance when the DB is unavailable.
- Tag key explorer uses SQL discovery on MySQL 8.0+.

## [0.2.0.alpha1, 0.2.0.alpha2] - 2026-04-20

### Breaking

- Require Ruby 3.3+ (was 3.1), Rails/ActiveRecord 7.1+ (was 7.0), Faraday 2.0+ (was 1.0).
- `Event`, `Cost`, and `ParsedUsage` are plain `Data.define` value objects; use method access (`event.cost.total_cost`) instead of Hash lookups. `ActiveSupport::Notifications` payloads are unchanged.
- Rename `LlmCostTracker::InvalidFilter` → `InvalidFilterError`.
- Drop `LlmApiCall.by_provider` / `by_model` scopes — use `where(provider:)` / `where(model:)`.
- `ReportData` no longer hardcodes a `"feature"` tag breakdown. Configure `config.report_tag_breakdowns = %w[feature env]` (or pass `tag_breakdowns:` to `ReportData.build` / `Report.generate`). Default is empty.

### Added

- `LlmApiCall.group_by_period(:day/:month)` — SQL-side period grouping.
- Opt-in `LlmCostTracker::Engine` dashboard (Rails 7.1+): overview with delta-vs-previous-period, provider rollup, models, filterable call list with CSV export and outlier sort modes, call details, tag key explorer, per-key tag breakdown, data quality. PostgreSQL/SQLite use adapter-specific SQL; MySQL 8.0+ uses JSON_TABLE-based tag discovery. Core middleware still works without Rails.

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
