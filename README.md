# LLM Cost Tracker

Self-hosted LLM cost tracking for Rails.

[![Gem Version](https://img.shields.io/gem/v/llm_cost_tracker.svg)](https://rubygems.org/gems/llm_cost_tracker)
[![CI](https://github.com/sergey-homenko/llm_cost_tracker/actions/workflows/ruby.yml/badge.svg)](https://github.com/sergey-homenko/llm_cost_tracker/actions)
[![codecov](https://codecov.io/gh/sergey-homenko/llm_cost_tracker/branch/main/graph/badge.svg)](https://codecov.io/gh/sergey-homenko/llm_cost_tracker)

Every call your app makes to OpenAI, Anthropic, Gemini, RubyLLM, or any
OpenAI-compatible API gets logged: tokens, cost, latency, tags. Calls go
app → provider direct. No proxy.

Not Langfuse, Helicone, or LiteLLM. No prompts, no traces, no replay. Spend
attribution only.

Requires Ruby 3.4+, Rails 7.1+, PostgreSQL or MySQL.

![Dashboard overview](docs/dashboard-overview.png)

## Quickstart

```ruby
# Gemfile
gem "llm_cost_tracker"
gem "openai"
```

```bash
bin/rails llm_cost_tracker:setup
```

Runs the install generator, drops a price snapshot, migrates the database, and verifies via `llm_cost_tracker:doctor`.

```ruby
# config/initializers/llm_cost_tracker.rb
LlmCostTracker.configure do |config|
  config.default_tags = -> { { environment: Rails.env } }
  config.instrument :openai
end
```

Tag your calls — that's how you find out who burned the money:

```ruby
LlmCostTracker.with_tags(user_id: Current.user&.id, feature: "chat") do
  client = OpenAI::Client.new(api_key: ENV["OPENAI_API_KEY"])
  client.responses.create(model: "gpt-4o", input: "Hello")
end
```

Mount the dashboard in `config/routes.rb`, behind your auth:

```ruby
authenticate :admin do
  mount LlmCostTracker::Engine => "/llm-costs"
end
```

The engine ships without authentication on purpose.

## What lands in the ledger

- **Calls.** Provider, model, total tokens, total cost, latency, status.
- **Line items.** Per-component breakdown — text/audio/cached tokens, tool
  charges (web search, code execution, grounding, container sessions).
- **Tags.** Whatever attribution you pass — user, feature, tenant, env.
- **Provider IDs.** Response, project, API key, workspace — for downstream
  audits.
- **Pricing snapshot.** So historical numbers don't drift when prices change.

## Capture surfaces

| Surface | Path |
| --- | --- |
| OpenAI | Official SDK or Faraday |
| Anthropic | Official SDK or Faraday |
| Azure OpenAI | Faraday (auto-detected on `*.openai.azure.com`) |
| Google Gemini | Faraday |
| RubyLLM | Provider layer |
| `ruby-openai` | Faraday |
| OpenRouter, DeepSeek, Groq, LiteLLM-style gateways | OpenAI-compatible Faraday |
| Anything else | `LlmCostTracker.track` |

Streams capture when the provider emits final usage. OpenAI Faraday streams
need `stream_options: { include_usage: true }`.

## What it isn't

- No proxy. Direct calls only.
- No prompts. Token counts and metadata only.
- No traces, evals, or prompt management. Different product, different gem.
- Not multi-service. Built for a Rails monolith.

## Manual tracking

For batch jobs, internal gateways, or anything without an SDK/Faraday hook:

```ruby
LlmCostTracker.track(
  provider: :anthropic,
  model: "claude-sonnet-4-6",
  tokens: { input: 1500, output: 320 },
  tags: { feature: "summarizer", user_id: current_user.id }
)
```

## Docs

- [Configuration](docs/configuration.md)
- [Pricing](docs/pricing.md)
- [Budgets](docs/budgets.md)
- [Data model](docs/data-model.md)
- [Querying](docs/querying.md)
- [Dashboard](docs/dashboard.md)
- [Streaming](docs/streaming.md)
- [Cookbook](docs/cookbook.md)
- [Extending](docs/extending.md)
- [Operations](docs/operations.md)
- [Architecture](docs/architecture.md)
- [EU AI Act record-keeping](docs/eu_ai_act.md)
- [Upgrading](docs/upgrading.md)
- [Changelog](CHANGELOG.md)

## Development

```bash
bundle install
bin/check
```

## License

MIT — see [LICENSE.txt](LICENSE.txt).
