# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
