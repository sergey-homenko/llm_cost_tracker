# LlmCostTracker

**See where your Rails app spends money on LLM APIs.**

Track cost by user, tenant, feature, provider, and model, all in your own database. No proxy. No SaaS required.

[![Gem Version](https://img.shields.io/gem/v/llm_cost_tracker.svg)](https://rubygems.org/gems/llm_cost_tracker)
[![CI](https://github.com/sergey-homenko/llm_cost_tracker/actions/workflows/ruby.yml/badge.svg)](https://github.com/sergey-homenko/llm_cost_tracker/actions)

```text
LLM Cost Report (last 30 days)

Total cost: $127.420000
Requests: 4,218
Avg latency: 812ms
Unknown pricing: 0

By model:
  gpt-4o                      $82.100000
  claude-sonnet-4-6           $31.200000
  gemini-2.5-flash            $14.120000

By tag (feature):
  chat                        $73.500000
  summarizer                  $29.220000
  translate                   $24.700000
```

## Why?

Every Rails app integrating LLMs faces the same problem: **you don't know how much AI is costing you** until the invoice arrives. Full observability platforms like Langfuse and Helicone are powerful, but sometimes you just need a small Rails-native cost ledger that lives in your app database.

`llm_cost_tracker` takes a different approach:

- 🔌 **Faraday-native** — intercepts LLM HTTP responses without changing the response
- 🏠 **Self-hosted** — your data stays in your database
- 🧩 **Client-light** — works with raw Faraday and LLM gems that expose their Faraday connection
- 🏷️ **Attribution-first** — tag spend by feature, tenant, user, job, or environment
- 🌐 **OpenAI-compatible** — auto-detect OpenRouter and DeepSeek, with custom compatible hosts configurable
- 🛑 **Budget guardrails** — notify, raise, or block requests when monthly spend is exhausted
- 📊 **Quick reports** — print a terminal cost report with one rake task

This gem is intentionally not a tracing platform, prompt CMS, eval system, or gateway. It focuses on the boring but valuable question: "What did this app spend on LLM APIs, and where did that spend come from?"

## Installation

Add to your Gemfile:

```ruby
gem "llm_cost_tracker"
```

For ActiveRecord storage (recommended for production):

```bash
bin/rails generate llm_cost_tracker:install
bin/rails db:migrate
```

## Try It In 30 Seconds

Try cost calculation without a database or migration:

```ruby
require "llm_cost_tracker"

LlmCostTracker.configure do |config|
  config.storage_backend = :log
end

LlmCostTracker.track(
  provider: :openai,
  model: "gpt-4o",
  input_tokens: 1000,
  output_tokens: 200,
  feature: "demo"
)
```

Output:

```text
[LlmCostTracker] openai/gpt-4o tokens=1000+200 cost=$0.004500 tags={:feature=>"demo"}
```

## Quick Start

Use the path that matches your app:

- Using `ruby-openai`, `ruby_llm`, or another client that exposes Faraday? Patch that client's Faraday connection.
- Using raw Faraday? Add the middleware directly.
- Using a client without Faraday access? Use manual tracking.

### Option 1: Patch An Existing Client

Some LLM gems expose their Faraday connection. For example, with `ruby-openai`:

```ruby
# config/initializers/openai.rb
OpenAI.configure do |config|
  config.access_token = ENV["OPENAI_API_KEY"]

  config.faraday do |f|
    f.use :llm_cost_tracker, tags: -> {
      {
        user_id: Current.user&.id,
        feature: Current.llm_feature || "chat"
      }
    }
  end
end
```

For Rails apps, `tags:` can be a callable so request-local values are evaluated per request:

```ruby
# app/models/current.rb
class Current < ActiveSupport::CurrentAttributes
  attribute :user, :tenant, :llm_feature
end

# app/controllers/application_controller.rb
before_action do
  Current.user = current_user
  Current.tenant = current_tenant if respond_to?(:current_tenant, true)
  Current.llm_feature = "chat"
end
```

### Option 2: Faraday Middleware

If your LLM client uses Faraday, add the middleware to that connection:

```ruby
conn = Faraday.new(url: "https://api.openai.com") do |f|
  f.use :llm_cost_tracker, tags: -> { { feature: "chat", user_id: Current.user&.id } }
  f.request :json
  f.response :json
  f.adapter Faraday.default_adapter
end

# Every supported LLM request through this connection is tracked
response = conn.post("/v1/responses", {
  model: "gpt-5-mini",
  input: "Hello!"
})
```

If a client does not expose its HTTP connection, use manual tracking or register a custom parser around the HTTP layer you control.

### Option 3: Manual tracking

For non-Faraday clients, track manually:

```ruby
LlmCostTracker.track(
  provider: :anthropic,
  model: "claude-sonnet-4-6",
  input_tokens: 1500,
  output_tokens: 320,
  cache_read_input_tokens: 1200,
  feature: "summarizer",
  user_id: current_user.id
)
```

## Configuration

```ruby
# config/initializers/llm_cost_tracker.rb
LlmCostTracker.configure do |config|
  # Storage: :log (default), :active_record, or :custom
  config.storage_backend = :active_record

  # Default tags on every event
  config.default_tags = { app: "my_app", environment: Rails.env }

  # Monthly budget in USD
  config.monthly_budget = 500.00
  config.budget_exceeded_behavior = :notify # :notify, :raise, or :block_requests
  config.storage_error_behavior = :warn # :ignore, :warn, or :raise
  config.unknown_pricing_behavior = :warn # :ignore, :warn, or :raise

  # Alert callback
  config.on_budget_exceeded = ->(data) {
    SlackNotifier.notify(
      "#alerts",
      "🚨 LLM budget exceeded! $#{data[:monthly_total].round(2)} / $#{data[:budget]}"
    )
  }

  # Override pricing for custom/fine-tuned models (per 1M tokens)
  config.prices_file = Rails.root.join("config/llm_cost_tracker_prices.yml")
  config.pricing_overrides = {
    "ft:gpt-4o-mini:my-org" => { input: 0.30, cached_input: 0.15, output: 1.20 }
  }

  # OpenAI-compatible APIs. OpenRouter and DeepSeek are included by default.
  config.openai_compatible_providers["llm.my-company.com"] = "internal_gateway"
end
```

Pricing is best-effort and based on public provider pricing for standard token usage. Providers change pricing frequently, and some features have extra charges or tiered pricing. OpenRouter-style model IDs such as `openai/gpt-4o-mini` are normalized to built-in model names when possible. Use `prices_file` or `pricing_overrides` for fine-tunes, gateway-specific model IDs, enterprise discounts, batch pricing, long-context premiums, and any model this gem does not know yet.

Storage errors are non-fatal by default:

```ruby
config.storage_error_behavior = :warn # default
config.storage_error_behavior = :raise # fail fast with StorageError
config.storage_error_behavior = :ignore # skip storage failures silently
```

With the default `:warn` behavior, tracking emits a warning and lets the LLM response continue if ActiveRecord or custom storage fails. `LlmCostTracker::StorageError` exposes `original_error` when `:raise` is enabled.

Unknown model pricing is visible by default:

```ruby
config.unknown_pricing_behavior = :warn # default
config.unknown_pricing_behavior = :raise # fail fast with UnknownPricingError
config.unknown_pricing_behavior = :ignore # keep tracking tokens silently
```

When pricing is unknown, the event can still be recorded with token counts, but `cost` is `nil` and budget guardrails are skipped for that event. Use `prices_file` or `pricing_overrides` to ensure all production models are priced. Check this ActiveRecord query for a list of unpriced models in your data:

```ruby
LlmCostTracker::LlmApiCall.unknown_pricing.group(:model).count
```

### Keeping Prices Current

Built-in prices live in `lib/llm_cost_tracker/prices.json`, with `updated_at`, `unit`, `currency`, and source URLs in the file metadata. The gem does not fetch pricing on boot; that keeps it self-hosted and avoids hidden external dependencies.

For production apps, keep a local JSON or YAML price file and point the gem at it:

```bash
bin/rails generate llm_cost_tracker:prices
```

```ruby
config.prices_file = Rails.root.join("config/llm_cost_tracker_prices.yml")
```

Example JSON:

```json
{
  "metadata": {
    "updated_at": "2026-04-18",
    "currency": "USD",
    "unit": "1M tokens"
  },
  "models": {
    "my-gateway/gpt-4o-mini": {
      "input": 0.20,
      "cached_input": 0.10,
      "output": 0.80
    }
  }
}
```

`pricing_overrides` still has the highest precedence, so you can use it for small Ruby-only overrides and keep broader provider tables in the file. A practical release rhythm is to refresh built-in `prices.json` quarterly and use `prices_file` for urgent provider changes between gem releases.

## Budget Enforcement

```ruby
LlmCostTracker.configure do |config|
  config.storage_backend = :active_record
  config.monthly_budget = 100.00
  config.budget_exceeded_behavior = :block_requests
end
```

Budget behavior options:

- `:notify` — default. Calls `on_budget_exceeded` after a tracked event pushes the month over budget.
- `:raise` — records the event, then raises `LlmCostTracker::BudgetExceededError` when the month is over budget.
- `:block_requests` — blocks Faraday LLM requests before the HTTP call when the ActiveRecord monthly total has already reached the budget. If a request pushes the month over budget, it also raises after recording the event.

`BudgetExceededError` exposes `monthly_total`, `budget`, and `last_event`:

```ruby
begin
  client.chat(...)
rescue LlmCostTracker::BudgetExceededError => e
  Rails.logger.warn("LLM budget exhausted: #{e.monthly_total} / #{e.budget}")
end
```

Pre-request blocking needs `storage_backend = :active_record` because the middleware must query your stored monthly total before sending the request. With `:log` or `:custom` storage, `:raise` and the post-response part of `:block_requests` still work for the event being tracked.

`:block_requests` is a best-effort guardrail, not a transactional hard quota. In highly concurrent deployments, multiple workers can pass the preflight check at the same time before any of them records its final cost. The request that first pushes the month over budget is stored before the post-response `BudgetExceededError` is raised; later Faraday requests are blocked during preflight once the stored monthly total is exhausted. Use provider-side limits or a gateway-level quota if you need strict cross-process caps.

## Querying Costs (ActiveRecord)

Print a quick terminal report:

```bash
bin/rails llm_cost_tracker:report

# Optional: change the window
DAYS=7 bin/rails llm_cost_tracker:report
```

Example:

```text
LLM Cost Report (last 30 days)

Total cost: $127.420000
Requests: 4,218
Avg latency: 812ms
Unknown pricing: 0

By provider:
  openai                      $96.220000
  anthropic                   $31.200000
```

Or query the ledger directly:

```ruby
# Today's total spend
LlmCostTracker::LlmApiCall.today.total_cost
# => 12.45

# Cost breakdown by model this month
LlmCostTracker::LlmApiCall.this_month.cost_by_model
# => { "gpt-4o" => 8.20, "claude-sonnet-4-6" => 4.25 }

# Cost by provider
LlmCostTracker::LlmApiCall.this_month.cost_by_provider
# => { "openai" => 8.20, "anthropic" => 4.25 }

# SQL-side cost breakdown by any tag key
calls = LlmCostTracker::LlmApiCall.this_month
calls.group_by_tag("feature").sum(:total_cost)
# => { "chat" => 7.10, "summarizer" => 1.10 }

# Convenience wrapper with "(untagged)" labels and float values
calls.cost_by_tag("feature")
# => { "chat" => 7.10, "summarizer" => 1.10 }

# SQL-side day/month cost trends
LlmCostTracker::LlmApiCall.this_month.group_by_period(:day).sum(:total_cost)
# => { "2026-04-17" => 1.5, "2026-04-18" => 2.3 }

LlmCostTracker::LlmApiCall.group_by_period(:month).sum(:total_cost)
# => { "2026-04" => 12.45 }

# Daily cost trend convenience wrapper
LlmCostTracker::LlmApiCall.daily_costs(days: 7)
# => { "2026-04-10" => 1.5, "2026-04-11" => 2.3, ... }

# Latency overview
LlmCostTracker::LlmApiCall.with_latency.average_latency_ms
LlmCostTracker::LlmApiCall.this_month.latency_by_model

# Filter by one tag
LlmCostTracker::LlmApiCall.by_tag("feature", "chat").this_month.total_cost

# Filter by another tag
LlmCostTracker::LlmApiCall.by_tag("user_id", "42").today.total_cost

# Filter by multiple tags
LlmCostTracker::LlmApiCall.by_tags(user_id: 42, feature: "chat").this_month.total_cost

# Find models without pricing
LlmCostTracker::LlmApiCall.unknown_pricing.group(:model).count
LlmCostTracker::LlmApiCall.with_cost.this_month.total_cost

# Custom date range
LlmCostTracker::LlmApiCall.between(1.week.ago, Time.current).cost_by_model
```

### Tag Storage

The install generator uses `jsonb` tags with a GIN index on PostgreSQL:

```ruby
t.jsonb :tags, null: false, default: {}
add_index :llm_api_calls, :tags, using: :gin
```

On SQLite, MySQL, and other adapters, tags fall back to JSON stored in a text column. The `by_tag` scope automatically uses PostgreSQL JSONB containment when the column supports it, and the text fallback otherwise. This works, but tag queries are less efficient than PostgreSQL JSONB containment.

If you installed `llm_cost_tracker` before JSONB tags were available and your app uses PostgreSQL, generate an upgrade migration:

```bash
bin/rails generate llm_cost_tracker:upgrade_tags_to_jsonb
bin/rails db:migrate
```

This converts the existing `tags` text column to `jsonb`, keeps existing tag data, and adds the GIN index.

If you installed an earlier version with `precision: 12, scale: 8` cost columns, widen them for larger production ledgers:

```bash
bin/rails generate llm_cost_tracker:upgrade_cost_precision
bin/rails db:migrate
```

If you installed before `latency_ms` was available, add the latency column:

```bash
bin/rails generate llm_cost_tracker:add_latency_ms
bin/rails db:migrate
```

## Rails Dashboard (Optional)

An opt-in Rails Engine mounts a read-only dashboard. Plain ERB, inline CSS, no JavaScript. Requires **Rails 7.1+**; the core middleware and `LlmCostTracker.track(...)` keep working without Rails.

```ruby
# config/application.rb (or an initializer)
require "llm_cost_tracker/engine"

# config/routes.rb
mount LlmCostTracker::Engine => "/llm-costs"
```

Routes:

- `GET /llm-costs` — overview: spend, calls, avg cost/call, avg latency, budget, daily trend, top models, cost by `feature`
- `GET /llm-costs/calls` — filterable, paginated call list
- `GET /llm-costs/calls/:id` — call details
- `GET /llm-costs/models` — calls aggregated by provider and model
- `GET /llm-costs/tags/:key` — calls aggregated by a tag value (e.g. `/llm-costs/tags/feature`)

All routes are GET-only. Invalid tag keys return 400.

> ⚠️ **Do not expose this dashboard publicly.** Tags may contain internal user, tenant, or feature identifiers. There is no built-in auth — protect the mount point with your app's existing auth.

### Basic Auth

```ruby
authenticated = ->(req) {
  ActionController::HttpAuthentication::Basic.authenticate(req) do |name, password|
    ActiveSupport::SecurityUtils.secure_compare(name, ENV.fetch("LLM_DASHBOARD_USER")) &
      ActiveSupport::SecurityUtils.secure_compare(password, ENV.fetch("LLM_DASHBOARD_PASSWORD"))
  end
}

constraints(authenticated) do
  mount LlmCostTracker::Engine => "/llm-costs"
end
```

### Devise

```ruby
authenticate :user, ->(user) { user.admin? } do
  mount LlmCostTracker::Engine => "/llm-costs"
end
```

## ActiveSupport::Notifications

Every tracked call emits an `llm_request.llm_cost_tracker` event:

```ruby
ActiveSupport::Notifications.subscribe("llm_request.llm_cost_tracker") do |*, payload|
  # payload =>
  # {
  #   provider: "openai",
  #   model: "gpt-4o",
  #   input_tokens: 150,
  #   output_tokens: 42,
  #   total_tokens: 192,
  #   latency_ms: 248,
  #   cost: {
  #     input_cost: 0.000375,
  #     cached_input_cost: 0.0,
  #     cache_read_input_cost: 0.0,
  #     cache_creation_input_cost: 0.0,
  #     output_cost: 0.00042,
  #     total_cost: 0.000795,
  #     currency: "USD"
  #   },
  #   tags: { feature: "chat", user_id: 42 },
  #   tracked_at: 2026-04-16 14:30:00 UTC
  # }

  StatsD.increment("llm.requests", tags: ["provider:#{payload[:provider]}"])
  StatsD.histogram("llm.cost", payload[:cost][:total_cost])
end
```

## Custom Storage Backend

```ruby
LlmCostTracker.configure do |config|
  config.storage_backend = :custom
  config.custom_storage = ->(event) {
    InfluxDB.write("llm_costs", {
      values: {
        cost: event.cost&.total_cost,
        tokens: event.total_tokens,
        latency_ms: event.latency_ms
      },
      tags: { provider: event.provider, model: event.model }
    })
  }
end
```

## OpenAI-Compatible Providers

```ruby
LlmCostTracker.configure do |config|
  # Built in:
  # "openrouter.ai" => "openrouter"
  # "api.deepseek.com" => "deepseek"
  config.openai_compatible_providers["gateway.example.com"] = "internal_gateway"
end
```

Any configured host is parsed with the OpenAI-compatible usage shape:

- `prompt_tokens` / `completion_tokens` / `total_tokens`
- `input_tokens` / `output_tokens` / `total_tokens`
- optional cached input details when the response includes them

This covers OpenRouter, DeepSeek, and private gateways that expose OpenAI-style Chat Completions, Responses, Completions, or Embeddings endpoints.

## Safety Guarantees

- `llm_cost_tracker` does not make external HTTP calls.
- It does not store prompt or response bodies.
- Faraday responses are not modified.
- Storage failures are non-fatal by default via `storage_error_behavior = :warn`.
- Budget and unknown-pricing errors are raised only when you opt into `:raise` or `:block_requests`.
- Pricing is local and best-effort; use `prices_file` or `pricing_overrides` for production-specific rates.
- Streaming/SSE calls are skipped with a warning when the final usage payload is not readable by Faraday.

## Production Checklist

- Use `storage_backend = :active_record` in production.
- Set `monthly_budget` and choose `budget_exceeded_behavior`.
- Treat `:block_requests` as best-effort in concurrent systems, not a strict quota.
- Keep `unknown_pricing_behavior = :warn` or `:raise` until pricing overrides are complete.
- Add `pricing_overrides` for custom, fine-tuned, gateway-specific, or newly released models.
- Tag calls with useful business context such as `tenant_id`, `user_id`, and `feature`.
- Check `LlmCostTracker::LlmApiCall.unknown_pricing.group(:model).count` after deploys.
- Track `latency_ms` and watch `latency_by_model` for slow or degraded providers.

## Known Limitations

- `:block_requests` is best-effort under concurrency. For hard caps, use an external quota system, provider-side limits, or a gateway-level budget.
- Streaming/SSE calls are tracked only when Faraday exposes a final response body with usage data. Otherwise the gem warns and skips automatic tracking.
- Anthropic cache creation TTL variants are not modeled separately yet; 1-hour cache writes may be underestimated compared with the default 5-minute cache write rate.
- OpenAI reasoning tokens are included in output-token totals when providers report them that way, but separate reasoning-token attribution is not stored yet.

## Adding a Custom Provider Parser

Use this for providers that are not OpenAI-compatible and return a different usage shape.

```ruby
class AcmeParser < LlmCostTracker::Parsers::Base
  def match?(url)
    url.to_s.include?("api.acme-llm.example")
  end

  def parse(request_url, request_body, response_status, response_body)
    return nil unless response_status == 200

    response = safe_json_parse(response_body)
    usage = response["usage"]
    return nil unless usage

    LlmCostTracker::ParsedUsage.build(
      provider: "acme",
      model: response["model"],
      input_tokens: usage["input"] || 0,
      output_tokens: usage["output"] || 0
    )
  end
end

# Register it
LlmCostTracker::Parsers::Registry.register(AcmeParser.new)
```

## Supported Providers

| Provider | Auto-detected | Models with pricing |
|----------|:---:|---|
| OpenAI | ✅ | GPT-5.2/5.1/5, GPT-5 mini/nano, GPT-4.1, GPT-4o, o1/o3/o4-mini |
| OpenRouter | ✅ | Uses OpenAI-compatible usage; provider-prefixed OpenAI model IDs are normalized when possible |
| DeepSeek | ✅ | Uses OpenAI-compatible usage; add `pricing_overrides` for DeepSeek model pricing |
| OpenAI-compatible hosts | 🔧 | Configure `openai_compatible_providers` |
| Anthropic | ✅ | Claude Opus 4.6/4.1/4, Sonnet 4.6/4.5/4, Haiku 4.5, Claude 3.x |
| Google Gemini | ✅ | Gemini 2.5 Pro/Flash/Flash-Lite, 2.0 Flash/Flash-Lite, 1.5 Pro/Flash |
| Any other | 🔧 | Via custom parser (see above) |

Supported endpoint families:

- OpenAI: Chat Completions, Responses, Completions, Embeddings
- OpenAI-compatible: Chat Completions, Responses, Completions, Embeddings
- Anthropic: Messages
- Google Gemini: `generateContent` responses with `usageMetadata`

## How It Works

```
Your App → Faraday → [LlmCostTracker Middleware] → LLM API
                              ↓
                     Parses response body
                     Extracts token usage
                     Calculates cost
                              ↓
               ActiveSupport::Notifications
               ActiveRecord / Log / Custom
```

The middleware intercepts **outgoing** HTTP responses (not incoming Rails requests), parses the provider usage object, looks up pricing, and records the event. It never modifies requests or responses. Put `llm_cost_tracker` inside the Faraday stack where it can see the final response body; if another middleware consumes or transforms streaming bodies, use manual tracking.

For streaming APIs, tracking depends on the final response body including provider usage data. If the client consumes server-sent events without exposing the final usage payload to Faraday, the gem logs a warning and skips tracking; use manual tracking for those calls.

## Development

```bash
git clone https://github.com/sergey-homenko/llm_cost_tracker.git
cd llm_cost_tracker
bundle install
bundle exec rspec
bundle exec rubocop
```

## Contributing

Bug reports and pull requests are welcome on [GitHub](https://github.com/sergey-homenko/llm_cost_tracker).

## License

The gem is available as open source under the terms of the [MIT License](LICENSE.txt).
