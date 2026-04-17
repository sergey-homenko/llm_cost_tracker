# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
