# LlmCostTracker

**Provider-agnostic LLM API cost tracking for Ruby.**

Track token usage and costs for every LLM API call your app makes — OpenAI, Anthropic, Google Gemini, and any OpenAI-compatible provider. Works as Faraday middleware, so it plugs into **any** Ruby LLM client without code changes.

[![Gem Version](https://badge.fury.io/rb/llm_cost_tracker.svg)](https://rubygems.org/gems/llm_cost_tracker)
[![CI](https://github.com/sergey-homenko/llm_cost_tracker/actions/workflows/ruby.yml/badge.svg)](https://github.com/sergey-homenko/llm_cost_tracker/actions)

## Why?

Every Rails app integrating LLMs faces the same problem: **you don't know how much AI is costing you** until the invoice arrives. Existing solutions either lock you into a specific LLM gem (like `ruby_llm-monitoring`) or require external SaaS (Langfuse, Helicone).

`llm_cost_tracker` takes a different approach:

- 🔌 **Provider-agnostic** — intercepts HTTP responses at the Faraday level
- 🏠 **Self-hosted** — your data stays in your database
- 🧩 **Zero coupling** — works with `ruby-openai`, `anthropic-rb`, `ruby_llm`, or raw Faraday
- ⚡ **Zero config** — add the middleware, done

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

### Option 1: Faraday Middleware (automatic)

If your LLM client uses Faraday (most do), just add the middleware:

```ruby
conn = Faraday.new(url: "https://api.openai.com") do |f|
  f.use :llm_cost_tracker, tags: { feature: "chat", user_id: current_user.id }
  f.request :json
  f.response :json
  f.adapter Faraday.default_adapter
end

# Every request through this connection is now tracked automatically
response = conn.post("/v1/chat/completions", {
  model: "gpt-4o",
  messages: [{ role: "user", content: "Hello!" }]
})
```

### Option 2: Patch an existing client

Most LLM gems expose their Faraday connection. For example, with `ruby-openai`:

```ruby
# config/initializers/openai.rb
OpenAI.configure do |config|
  config.access_token = ENV["OPENAI_API_KEY"]

  config.faraday do |f|
    f.use :llm_cost_tracker, tags: { feature: "openai_default" }
  end
end
```

### Option 3: Manual tracking

For non-Faraday clients, track manually:

```ruby
LlmCostTracker.track(
  provider: :anthropic,
  model: "claude-sonnet-4-6",
  input_tokens: 1500,
  output_tokens: 320,
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
    "ft:gpt-4o-mini:my-org" => { input: 0.30, output: 1.20 }
  }
end
```

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
  #   cost: { input_cost: 0.000375, output_cost: 0.00042, total_cost: 0.000795, currency: "USD" },
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
| OpenAI | ✅ | GPT-4o, GPT-4o-mini, GPT-4-turbo, GPT-4, GPT-3.5-turbo, o1, o1-mini, o3-mini |
| Anthropic | ✅ | Claude Opus 4.6, Sonnet 4.6, Haiku 4.5, Claude 3.5 Sonnet, Claude 3 Opus |
| Google Gemini | ✅ | Gemini 2.5 Pro/Flash, 2.0 Flash, 1.5 Pro/Flash |
| Any other | 🔧 | Via custom parser (see above) |

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

The middleware intercepts **outgoing** HTTP responses (not incoming requests), parses the `usage` object from the LLM provider's response body, looks up pricing, and records the event. It never modifies requests or responses — it's read-only.

## Development

```bash
git clone https://github.com/sergey-homenko/llm_cost_tracker.git
cd llm_cost_tracker
bundle install
bundle exec rspec
```

## Contributing

Bug reports and pull requests are welcome on [GitHub](https://github.com/sergey-homenko/llm_cost_tracker).

## License

The gem is available as open source under the terms of the [MIT License](LICENSE.txt).
