# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.2] - 2026-04-18

### Added

- Auto-detect OpenRouter and DeepSeek as OpenAI-compatible providers.
- Add `openai_compatible_providers` configuration for private OpenAI-compatible gateways.
- Add `BudgetExceededError` and `budget_exceeded_behavior` for best-effort budget guardrails.
- Add `:raise` and `:block_requests` budget behaviors; `:block_requests` is not a hard cap under concurrency.
- Add `StorageError` and `storage_error_behavior` so storage failures do not have to break host LLM calls.
- Add `UnknownPricingError` and `unknown_pricing_behavior` for unknown model pricing.
- Add built-in `prices.json` registry with metadata and source URLs.
- Add `prices_file` configuration for local JSON/YAML pricing overrides.
- Add `with_cost`, `without_cost`, and `unknown_pricing` ActiveRecord scopes.
- Add `latency_ms` tracking for Faraday calls, manual tracking, notifications, and ActiveRecord storage.
- Add `with_latency`, `average_latency_ms`, `latency_by_model`, and `latency_by_provider`.
- Use PostgreSQL `jsonb` storage for tags in newly generated migrations.
- Add a GIN index on `llm_api_calls.tags` for PostgreSQL installs.
- Add adapter-aware `by_tag` querying with JSONB containment on PostgreSQL and text fallback elsewhere.
- Add `by_tags`, `by_user`, and `by_feature` scopes for common attribution queries.
- Add `llm_cost_tracker:upgrade_tags_to_jsonb` generator for existing PostgreSQL installs.
- Add `llm_cost_tracker:upgrade_cost_precision` generator for widening stored cost columns.
- Add `llm_cost_tracker:add_latency_ms` generator for existing installs.

### Changed

- Store tags as a Hash for JSON-backed columns and as JSON text for fallback columns.
- Keep internal usage metadata such as cache token counts out of stored attribution tags.
- Normalize provider-prefixed model IDs like `openai/gpt-4o-mini` for built-in price lookup.
- Normalize configured OpenAI-compatible host keys to lowercase after configuration.
- Avoid double fuzzy-match passes during price lookup.
- Widen generated cost decimal columns to `precision: 20, scale: 8`.
- Count Gemini `thoughtsTokenCount` as output tokens for better thinking-mode cost estimates.
- Warn when Faraday exposes an unreadable streaming/SSE response body.
- Document tag storage behavior, budget guardrail limits, known limitations, common tag scopes, and upgrade flows.
- Clarify that budget errors raised after a response occur after the event has been recorded.
- Route custom storage exceptions that inherit from `LlmCostTracker::Error` through `storage_error_behavior`.

## [0.1.1] - 2026-04-17

### Fixed

- Lazy-load ActiveRecord storage so `storage_backend = :active_record` persists events reliably.
- Avoid double-counting the latest ActiveRecord event in monthly budget callbacks.
- Track OpenAI Responses API usage via `/v1/responses`.
- Parse OpenAI cached input token details for cache-aware cost estimates.
- Parse Anthropic cache read and cache creation token usage under canonical metadata keys.
- Parse Gemini cached content token usage when present.
- Store ActiveRecord tag values as strings so `by_tag("user_id", "42")` works for numeric IDs.

### Changed

- Refresh built-in pricing for current OpenAI, Anthropic, and Gemini models.
- Add cache-aware cost calculation fields for cached input, cache reads, and cache creation.
- Tighten OpenAI URL matching to supported endpoint families only.
- Reposition README around self-hosted Rails/Ruby cost tracking for Faraday-based clients.

### Added

- Add ActiveRecord integration specs for persistence, tag querying, and budget callbacks.
- Add RuboCop configuration, rake task, and CI lint step.
- Require MFA metadata for RubyGems publishing.

## [0.1.0] - 2026-04-16

### Added

- Faraday middleware for automatic LLM API call interception
- Provider parsers: OpenAI, Anthropic, Google Gemini
- Built-in pricing table for 20+ models
- Fuzzy model name matching (e.g. `gpt-4o-2024-08-06` → `gpt-4o`)
- ActiveSupport::Notifications integration
- ActiveRecord storage backend with scopes and aggregations
- Manual `LlmCostTracker.track()` for non-Faraday clients
- Per-user / per-feature tagging
- Monthly budget alerts with configurable callbacks
- Rails generator: `rails generate llm_cost_tracker:install`
- Custom storage backend support
- Pricing overrides via configuration
