# Configuration

Configuration is the contract between the host app and the ledger: where events
go, which integrations are enabled, how attribution is attached, and how the app
reacts when storage, pricing, or budgets need attention.

The full option reference is moving here from the README. Until that migration is
complete, the README anchors below remain canonical.

## Canonical Sources

Until this page is expanded, use:

- [Quickstart](../README.md#quickstart)
- [Capturing calls](../README.md#capturing-calls)
- [Tags](../README.md#tags-who-burned-this-money)
- [Pricing](../README.md#pricing)
- [Budgets](../README.md#budgets)

## Scope

This page is scoped to:

- `storage_backend`: `:log`, `:active_record`, and `:custom`
- `default_tags`: static tags and per-request callable tags
- `instrument`: RubyLLM and official SDK integrations
- `prices_file` and `pricing_overrides`
- `monthly_budget`, `daily_budget`, and `per_call_budget`
- `budget_exceeded_behavior`
- `storage_error_behavior`
- `unknown_pricing_behavior`
- `openai_compatible_providers`
- `report_tag_breakdowns`

## Minimal Production Config

```ruby
LlmCostTracker.configure do |config|
  config.storage_backend = :active_record
  config.default_tags = -> { { environment: Rails.env } }
  config.prices_file = Rails.root.join("config/llm_cost_tracker_prices.yml")
  config.instrument :openai
end
```

Keep configuration at boot. Mutable shared settings are frozen after
`configure` returns so request-time code cannot silently change global tracking
behavior.

Enabled SDK integrations are fail-fast. The client gem must be loaded, meet the
minimum supported version, and expose the expected classes and methods before
LLM Cost Tracker installs its wrapper.
