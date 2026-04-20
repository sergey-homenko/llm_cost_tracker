# LlmCostTracker

**Self-hosted LLM cost tracking for Ruby and Rails.** Intercepts Faraday LLM responses, prices them locally, stores events in your database. No proxy, no SaaS.

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

By tag key "env":
  production                  $119.300000
  staging                     $8.120000
```

## Why

Every Rails app with LLM integrations eventually runs into the same question: where did that invoice come from? Full observability platforms like Langfuse and Helicone cover a lot more than cost, and sometimes you just want a small Rails-native ledger that lives in your own database.

`llm_cost_tracker` is scoped to that. It plugs into Faraday, parses provider usage out of the response, looks up pricing locally, and writes an event. You end up with a ledger you can query with plain ActiveRecord, slice by any tag dimension, and optionally surface on a built-in dashboard. No proxy, no SaaS, no separate service to run.

It's not a tracing platform, prompt CMS, eval system, or gateway — and doesn't want to be. The goal is answering _"what did this app spend on LLM APIs, and where did that spend come from?"_ well enough that you stop worrying about it.

## Installation

```ruby
gem "llm_cost_tracker"
```

For ActiveRecord storage:

```bash
bin/rails generate llm_cost_tracker:install
bin/rails db:migrate
```

## Quick try (no database)

```ruby
require "llm_cost_tracker"

LlmCostTracker.configure { |c| c.storage_backend = :log }

LlmCostTracker.track(
  provider: :openai,
  model: "gpt-4o",
  input_tokens: 1000,
  output_tokens: 200,
  feature: "demo"
)
# => [LlmCostTracker] openai/gpt-4o tokens=1000+200 cost=$0.004500 tags={:feature=>"demo"}
```

## Usage

### Patch an existing client's Faraday connection

```ruby
# config/initializers/openai.rb
OpenAI.configure do |config|
  config.access_token = ENV["OPENAI_API_KEY"]

  config.faraday do |f|
    f.use :llm_cost_tracker, tags: -> {
      { user_id: Current.user&.id, workflow: Current.workflow, env: Rails.env }
    }
  end
end
```

`tags:` can be a callable so `Current` attributes are evaluated per request:

```ruby
class Current < ActiveSupport::CurrentAttributes
  attribute :user, :tenant, :workflow
end

# application_controller.rb
before_action do
  Current.user = current_user
  Current.workflow = "chat"
end
```

### Raw Faraday

```ruby
conn = Faraday.new(url: "https://api.openai.com") do |f|
  f.use :llm_cost_tracker, tags: -> { { feature: "chat", user_id: Current.user&.id } }
  f.request :json
  f.response :json
  f.adapter Faraday.default_adapter
end

conn.post("/v1/responses", { model: "gpt-5-mini", input: "Hello!" })
```

Place `llm_cost_tracker` inside the Faraday stack where it can see the final response body. For streaming APIs, tracking requires the final body to expose provider usage; otherwise the gem warns and skips — use manual tracking there.

### Manual tracking

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
  config.storage_backend = :active_record # :log (default), :active_record, :custom
  config.default_tags = { app: "my_app", environment: Rails.env }

  config.monthly_budget = 500.00
  config.budget_exceeded_behavior = :notify  # :notify, :raise, :block_requests
  config.storage_error_behavior   = :warn    # :ignore, :warn, :raise
  config.unknown_pricing_behavior = :warn    # :ignore, :warn, :raise

  config.on_budget_exceeded = ->(data) {
    SlackNotifier.notify("#alerts", "🚨 LLM budget $#{data[:monthly_total].round(2)} / $#{data[:budget]}")
  }

  config.prices_file = Rails.root.join("config/llm_cost_tracker_prices.yml")
  config.pricing_overrides = {
    "ft:gpt-4o-mini:my-org" => { input: 0.30, cached_input: 0.15, output: 1.20 }
  }

  # Built-in: openrouter.ai, api.deepseek.com
  config.openai_compatible_providers["llm.my-company.com"] = "internal_gateway"
end
```

Pricing is best-effort. OpenRouter-style IDs like `openai/gpt-4o-mini` are normalized to built-in names when possible. Use `prices_file` / `pricing_overrides` for fine-tunes, gateway-specific IDs, enterprise discounts, batch pricing, or models the gem doesn't know.

`storage_error_behavior = :warn` (default) lets LLM responses continue if storage fails; `:raise` exposes `StorageError#original_error`.

Unknown pricing still records token counts, but `cost` is `nil` and budget guardrails skip that event. Find unpriced models:

```ruby
LlmCostTracker::LlmApiCall.unknown_pricing.group(:model).count
```

### Keeping prices current

Built-in prices are in `lib/llm_cost_tracker/prices.json`. The gem never fetches pricing on boot. For production, generate a local overrides file and point the gem at it:

```bash
bin/rails generate llm_cost_tracker:prices
```

```json
{
  "metadata": { "updated_at": "2026-04-18", "currency": "USD", "unit": "1M tokens" },
  "models": {
    "my-gateway/gpt-4o-mini": { "input": 0.20, "cached_input": 0.10, "output": 0.80 }
  }
}
```

`pricing_overrides` has the highest precedence; use it for small Ruby-only tweaks, `prices_file` for broader tables.

## Budget enforcement

```ruby
config.storage_backend = :active_record
config.monthly_budget = 100.00
config.budget_exceeded_behavior = :block_requests
```

- `:notify` — fire `on_budget_exceeded` after an event pushes the month over budget.
- `:raise` — record the event, then raise `BudgetExceededError`.
- `:block_requests` — block preflight when the stored monthly total is already over budget; still raises post-response on the event that crosses the line. Needs `:active_record` storage.

```ruby
rescue LlmCostTracker::BudgetExceededError => e
  # e.monthly_total, e.budget, e.last_event
```

`:block_requests` is best-effort under concurrency, not a transactional cap. Use provider/gateway-level limits for strict quotas.

## Querying costs

```bash
bin/rails llm_cost_tracker:report
DAYS=7 bin/rails llm_cost_tracker:report
DAYS=90 bin/rails llm_cost_tracker:prune  # delete calls older than N days in batches
```

```ruby
LlmCostTracker::LlmApiCall.today.total_cost
LlmCostTracker::LlmApiCall.this_month.cost_by_model
LlmCostTracker::LlmApiCall.this_month.cost_by_provider

# Group / sum by any tag
LlmCostTracker::LlmApiCall.this_month.group_by_tag("feature").sum(:total_cost)
LlmCostTracker::LlmApiCall.this_month.cost_by_tag("feature")  # with "(untagged)" bucket

# Period grouping (SQL-side)
LlmCostTracker::LlmApiCall.this_month.group_by_period(:day).sum(:total_cost)
LlmCostTracker::LlmApiCall.group_by_period(:month).sum(:total_cost)
LlmCostTracker::LlmApiCall.daily_costs(days: 7)

# Latency
LlmCostTracker::LlmApiCall.with_latency.average_latency_ms
LlmCostTracker::LlmApiCall.this_month.latency_by_model

# Tag filters
LlmCostTracker::LlmApiCall.by_tag("feature", "chat").this_month.total_cost
LlmCostTracker::LlmApiCall.by_tags(user_id: 42, feature: "chat").this_month.total_cost

# Range
LlmCostTracker::LlmApiCall.between(1.week.ago, Time.current).cost_by_model
```

### Tag storage

New installs use `jsonb` + GIN on PostgreSQL:

```ruby
t.jsonb :tags, null: false, default: {}
add_index :llm_api_calls, :tags, using: :gin
```

On other adapters tags fall back to JSON in a text column. `by_tag` uses JSONB containment on PG, text matching elsewhere.

Upgrade an existing install:

```bash
bin/rails generate llm_cost_tracker:upgrade_tags_to_jsonb   # PG: text → jsonb + GIN
bin/rails generate llm_cost_tracker:upgrade_cost_precision  # widen cost columns
bin/rails generate llm_cost_tracker:add_latency_ms
bin/rails db:migrate
```

## Dashboard (optional)

Opt-in Rails Engine. Plain ERB, inline CSS, no JS. Requires Rails 7.1+; the core middleware works without Rails.

```ruby
# config/application.rb (or an initializer)
require "llm_cost_tracker/engine"

# config/routes.rb
mount LlmCostTracker::Engine => "/llm-costs"
```

Routes (GET-only; CSV export included):

- `/llm-costs` — overview: spend (with delta vs previous period), calls, avg cost/call, avg latency, unknown pricing, budget, daily trend, provider rollup, top models
- `/llm-costs/models` — by provider + model; sortable by spend, volume, avg cost, latency
- `/llm-costs/calls` — filterable + paginated; outlier sort modes (expensive, largest input/output, slowest, unknown pricing); CSV export
- `/llm-costs/calls/:id` — details
- `/llm-costs/tags` — tag keys present in the dataset (PG/SQLite native, MySQL via in-Ruby fallback)
- `/llm-costs/tags/:key` — breakdown by values of a given tag key
- `/llm-costs/data_quality` — unknown pricing share, untagged calls, missing latency

> ⚠️ **No built-in auth.** Tags carry whatever your app puts in them. Protect the mount point with your app's auth.

### Basic auth

```ruby
authenticated = ->(req) {
  ActionController::HttpAuthentication::Basic.authenticate(req) do |name, password|
    ActiveSupport::SecurityUtils.secure_compare(name, ENV.fetch("LLM_DASHBOARD_USER")) &
      ActiveSupport::SecurityUtils.secure_compare(password, ENV.fetch("LLM_DASHBOARD_PASSWORD"))
  end
}
constraints(authenticated) { mount LlmCostTracker::Engine => "/llm-costs" }
```

### Devise

```ruby
authenticate :user, ->(user) { user.admin? } do
  mount LlmCostTracker::Engine => "/llm-costs"
end
```

## ActiveSupport::Notifications

```ruby
ActiveSupport::Notifications.subscribe("llm_request.llm_cost_tracker") do |*, payload|
  # payload =>
  # {
  #   provider: "openai", model: "gpt-4o",
  #   input_tokens: 150, output_tokens: 42, total_tokens: 192, latency_ms: 248,
  #   cost: {
  #     input_cost: 0.000375, cached_input_cost: 0.0,
  #     cache_read_input_cost: 0.0, cache_creation_input_cost: 0.0,
  #     output_cost: 0.00042, total_cost: 0.000795, currency: "USD"
  #   },
  #   tags: { feature: "chat", user_id: 42 },
  #   tracked_at: 2026-04-16 14:30:00 UTC
  # }
end
```

## Custom storage backend

```ruby
config.storage_backend = :custom
config.custom_storage = ->(event) {
  InfluxDB.write("llm_costs",
    values: { cost: event.cost&.total_cost, tokens: event.total_tokens, latency_ms: event.latency_ms },
    tags:   { provider: event.provider, model: event.model }
  )
}
```

## OpenAI-compatible providers

```ruby
config.openai_compatible_providers["gateway.example.com"] = "internal_gateway"
```

Configured hosts are parsed with the OpenAI-compatible usage shape (`prompt_tokens` / `completion_tokens` / `total_tokens`, `input_tokens` / `output_tokens`, and optional cached-input details). Covers OpenRouter, DeepSeek, and private gateways exposing Chat Completions / Responses / Completions / Embeddings.

## Custom parser

For providers with a non-OpenAI usage shape:

```ruby
class AcmeParser < LlmCostTracker::Parsers::Base
  def match?(url)
    url.to_s.include?("api.acme-llm.example")
  end

  def parse(request_url, request_body, response_status, response_body)
    return nil unless response_status == 200

    usage = safe_json_parse(response_body)&.dig("usage")
    return nil unless usage

    LlmCostTracker::ParsedUsage.build(
      provider: "acme",
      model: safe_json_parse(response_body)["model"],
      input_tokens: usage["input"] || 0,
      output_tokens: usage["output"] || 0
    )
  end
end

LlmCostTracker::Parsers::Registry.register(AcmeParser.new)
```

## Supported providers

| Provider | Auto-detected | Models with pricing |
|---|:---:|---|
| OpenAI | ✅ | GPT-5.2/5.1/5, GPT-5 mini/nano, GPT-4.1, GPT-4o, o1/o3/o4-mini |
| OpenRouter | ✅ | OpenAI-compatible usage; provider-prefixed OpenAI model IDs normalized when possible |
| DeepSeek | ✅ | OpenAI-compatible usage; add `pricing_overrides` for DeepSeek models |
| OpenAI-compatible hosts | 🔧 | Configure `openai_compatible_providers` |
| Anthropic | ✅ | Claude Opus 4.6/4.1/4, Sonnet 4.6/4.5/4, Haiku 4.5, Claude 3.x |
| Google Gemini | ✅ | Gemini 2.5 Pro/Flash/Flash-Lite, 2.0 Flash/Flash-Lite, 1.5 Pro/Flash |
| Any other | 🔧 | Custom parser |

Endpoints: OpenAI Chat Completions / Responses / Completions / Embeddings; OpenAI-compatible equivalents; Anthropic Messages; Gemini `generateContent` with `usageMetadata`.

## Safety

- No external HTTP calls.
- No prompt or response bodies stored.
- Faraday responses not modified.
- Storage failures non-fatal by default (`storage_error_behavior = :warn`).
- Budget / unknown-pricing errors are raised only when you opt in.

## Known limitations

- `:block_requests` is best-effort under concurrency; use an external quota system for hard caps.
- Streaming/SSE tracked only when Faraday exposes a final body with usage.
- Anthropic cache TTL variants (1h vs 5min writes) not modeled separately.
- OpenAI reasoning tokens included in output totals; separate reasoning-token attribution not stored.

## Development

```bash
bundle install
bundle exec rspec
bundle exec rubocop
```

## License

MIT. See [LICENSE.txt](LICENSE.txt).
