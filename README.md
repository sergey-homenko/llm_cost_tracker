# LlmCostTracker

**Self-hosted LLM API cost tracking for Ruby and Rails apps.**

Track token usage and estimated costs for OpenAI, Anthropic, and Google Gemini calls from Faraday-based Ruby clients. Store the data in your own database, tag calls by user or feature, and get budget alerts without adding an external SaaS or proxy.

[![Gem Version](https://badge.fury.io/rb/llm_cost_tracker.svg)](https://rubygems.org/gems/llm_cost_tracker)
[![CI](https://github.com/sergey-homenko/llm_cost_tracker/actions/workflows/ruby.yml/badge.svg)](https://github.com/sergey-homenko/llm_cost_tracker/actions)

## Why?

Every Rails app integrating LLMs faces the same problem: **you don't know how much AI is costing you** until the invoice arrives. Full observability platforms like Langfuse and Helicone are powerful, but sometimes you just need a small Rails-native cost ledger that lives in your app database.

`llm_cost_tracker` takes a different approach:

- 🔌 **Faraday-native** — intercepts LLM HTTP responses without changing the response
- 🏠 **Self-hosted** — your data stays in your database
- 🧩 **Client-light** — works with raw Faraday and LLM gems that expose their Faraday connection
- 🏷️ **Attribution-first** — tag spend by feature, tenant, user, job, or environment
- 💸 **Budget-aware** — emit notifications and callbacks before spend surprises you

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

## Quick Start

### Option 1: Faraday Middleware

If your LLM client uses Faraday, add the middleware to that connection:

```ruby
conn = Faraday.new(url: "https://api.openai.com") do |f|
  f.use :llm_cost_tracker, tags: { feature: "chat", user_id: current_user.id }
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

### Option 2: Patch an existing client

Some LLM gems expose their Faraday connection. For example, with `ruby-openai`:

```ruby
# config/initializers/openai.rb
OpenAI.configure do |config|
  config.access_token = ENV["OPENAI_API_KEY"]

  config.faraday do |f|
    f.use :llm_cost_tracker, tags: { feature: "openai_default" }
  end
end
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

  # Alert callback
  config.on_budget_exceeded = ->(data) {
    SlackNotifier.notify(
      "#alerts",
      "🚨 LLM budget exceeded! $#{data[:monthly_total].round(2)} / $#{data[:budget]}"
    )
  }

  # Override pricing for custom/fine-tuned models (per 1M tokens)
  config.pricing_overrides = {
    "ft:gpt-4o-mini:my-org" => { input: 0.30, cached_input: 0.15, output: 1.20 }
  }
end
```

Pricing is best-effort and based on public provider pricing for standard token usage. Providers change pricing frequently, and some features have extra charges or tiered pricing. Use `pricing_overrides` for fine-tunes, gateway-specific model IDs, enterprise discounts, batch pricing, long-context premiums, and any model this gem does not know yet.

## Querying Costs (ActiveRecord)

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

# Daily cost trend
LlmCostTracker::LlmApiCall.daily_costs(days: 7)
# => { "2026-04-10" => 1.5, "2026-04-11" => 2.3, ... }

# Filter by feature
LlmCostTracker::LlmApiCall.by_tag("feature", "chat").this_month.total_cost

# Filter by user
LlmCostTracker::LlmApiCall.by_tag("user_id", "42").today.total_cost

# Custom date range
LlmCostTracker::LlmApiCall.between(1.week.ago, Time.current).cost_by_model
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
      values: { cost: event[:cost][:total_cost], tokens: event[:total_tokens] },
      tags: { provider: event[:provider], model: event[:model] }
    })
  }
end
```

## Adding a Custom Provider Parser

```ruby
class DeepSeekParser < LlmCostTracker::Parsers::Base
  def match?(url)
    url.to_s.include?("api.deepseek.com")
  end

  def parse(request_url, request_body, response_status, response_body)
    return nil unless response_status == 200

    response = safe_json_parse(response_body)
    usage = response["usage"]
    return nil unless usage

    {
      provider: "deepseek",
      model: response["model"],
      input_tokens: usage["prompt_tokens"] || 0,
      output_tokens: usage["completion_tokens"] || 0
    }
  end
end

# Register it
LlmCostTracker::Parsers::Registry.register(DeepSeekParser.new)
```

## Supported Providers

| Provider | Auto-detected | Models with pricing |
|----------|:---:|---|
| OpenAI | ✅ | GPT-5.2/5.1/5, GPT-5 mini/nano, GPT-4.1, GPT-4o, o1/o3/o4-mini |
| Anthropic | ✅ | Claude Opus 4.6/4.1/4, Sonnet 4.6/4.5/4, Haiku 4.5, Claude 3.x |
| Google Gemini | ✅ | Gemini 2.5 Pro/Flash/Flash-Lite, 2.0 Flash/Flash-Lite, 1.5 Pro/Flash |
| Any other | 🔧 | Via custom parser (see above) |

Supported endpoint families:

- OpenAI: Chat Completions, Responses, Completions, Embeddings
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

The middleware intercepts **outgoing** HTTP responses (not incoming Rails requests), parses the provider usage object, looks up pricing, and records the event. It never modifies requests or responses.

For streaming APIs, tracking depends on the final response body including provider usage data. If the client consumes server-sent events without exposing the final usage payload to Faraday, use manual tracking.

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
