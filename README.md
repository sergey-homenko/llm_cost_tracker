# LLM Cost Tracker

A Rails-native ledger for what your LLM calls actually cost.

[![Gem Version](https://img.shields.io/gem/v/llm_cost_tracker.svg)](https://rubygems.org/gems/llm_cost_tracker)
[![CI](https://github.com/sergey-homenko/llm_cost_tracker/actions/workflows/ruby.yml/badge.svg)](https://github.com/sergey-homenko/llm_cost_tracker/actions)
[![codecov](https://codecov.io/gh/sergey-homenko/llm_cost_tracker/branch/main/graph/badge.svg)](https://codecov.io/gh/sergey-homenko/llm_cost_tracker)

If you have OpenAI, Anthropic, or Gemini in production and someone keeps asking "where did that bill come from?", this gem records every call into your own database, prices it locally, and gives you a dashboard you can mount in five minutes. No proxy, no SaaS account, no extra service to deploy.

It is not Langfuse, Helicone, or LiteLLM. It does not capture prompts, score completions, or replay traces. It does one thing: tells you which provider, which model, which feature, and which user burned how much money. That's the entire pitch.

Requires Ruby 3.3+, ActiveSupport 7.1+, Faraday 2.0+. ActiveRecord storage and the dashboard need Rails 7.1+.

![Dashboard overview](docs/dashboard-overview.png)

## Quickstart

Add to your Gemfile alongside whatever LLM client you already use:

```ruby
gem "llm_cost_tracker"
gem "openai"  # or "anthropic", "ruby_llm", or your existing client
```

Install, migrate, verify:

```bash
bin/rails generate llm_cost_tracker:install --dashboard --prices
bin/rails db:migrate
bin/rails llm_cost_tracker:doctor
```

Drop this into `config/initializers/llm_cost_tracker.rb`:

```ruby
LlmCostTracker.configure do |config|
  config.storage_backend = :active_record
  config.default_tags    = -> { { environment: Rails.env } }
  config.instrument :openai
end
```

Now every OpenAI call is recorded. Wrap calls in `with_tags` to attribute spend to a user, feature, or anything else you care about:

```ruby
LlmCostTracker.with_tags(user_id: Current.user&.id, feature: "chat") do
  client = OpenAI::Client.new(api_key: ENV["OPENAI_API_KEY"])
  client.responses.create(model: "gpt-4o", input: "Hello")
end
```

Visit `/llm-costs` for the dashboard. **Mount it behind your app's auth before deploying** — the gem doesn't ship with one, on purpose.

## What you get

- Local ActiveRecord ledger of every call: provider, model, token breakdown, cost, latency, tags, response IDs
- Auto-capture for RubyLLM and the official `openai` and `anthropic` Ruby SDKs, plus Faraday middleware for `ruby-openai`, the Gemini REST API, and any client you can inject middleware into
- Server-rendered dashboard (plain ERB, zero JavaScript) with overview, models, calls, tags, CSV export, and a data-quality page
- Local pricing snapshots refreshed daily from the official provider pricing pages, applied with `bin/rails llm_cost_tracker:prices:refresh`
- Monthly / daily / per-call budget guardrails with notify, raise, or block-requests behaviour
- Tag-based attribution that survives concurrency — Puma threads and Sidekiq fibers don't bleed into each other

## What it deliberately doesn't do

- **Doesn't run as a proxy.** Calls go directly from your app to the provider.
- **Doesn't store prompts or completions.** Token counts, model, cost, tags, response IDs only. Nothing else.
- **Doesn't promise invoice-grade accuracy.** It uses official provider pricing pages, but enterprise rates, batch discounts on unsupported endpoints, and modality tiers are not always modeled. `provider_response_id` is stored as a join key for whoever does that reconciliation.
- **Doesn't ship with auth on the dashboard.** It's a Rails Engine; mount it behind whatever your app already uses (Devise, basic auth, Cloudflare Access, your own session middleware).
- **Doesn't centralize multi-service visibility.** One Rails monolith — perfect fit. Six services in four languages — wrong tool, look at a proxy or API-layer gateway.

## Capturing calls

Three paths, in order of preference. Use the first one that fits your stack.

### 1. SDK integrations

Drop-in for RubyLLM and the official `openai` and `anthropic` gems. `config.instrument` patches tested SDK methods so you don't change a single call site:

```ruby
LlmCostTracker.configure do |config|
  config.instrument :openai      # or :anthropic / :ruby_llm
end

LlmCostTracker.with_tags(feature: "support_chat") do
  Anthropic::Client.new.messages.create(
    model: "claude-sonnet-4-6",
    max_tokens: 1024,
    messages: [{ role: "user", content: "Hello" }]
  )
end
```

Captures usage, model, latency, response ID, cache tokens, and reasoning tokens whenever the SDK exposes them. Provider SDKs are not added as gem dependencies — you install whichever you actually use.

Enabled integrations are checked at boot: the client gem must be loaded, meet the minimum supported version, and expose the expected classes and methods. If the contract check fails, boot raises instead of silently missing spend.

This patches **only** RubyLLM and the official Ruby SDKs. `ruby-openai` (alexrudall) and any custom client go through Faraday middleware below.

### 2. Faraday middleware

For `ruby-openai`, the Gemini REST API, custom Faraday clients, or anything OpenAI-compatible (OpenRouter, DeepSeek, LiteLLM proxies):

```ruby
conn = Faraday.new(url: "https://api.openai.com") do |f|
  f.use :llm_cost_tracker, tags: -> { { feature: "chat", user_id: Current.user&.id } }
  f.request :json
  f.response :json
  f.adapter Faraday.default_adapter
end
```

Tags can be a hash or a callable evaluated per request. Place the middleware where it sees the final response body — in practice, before the JSON parser.

Streaming works through the same path: the middleware tees the `on_data` callback so your code keeps receiving chunks normally, and the final usage gets recorded once the stream finishes. OpenAI streams need `stream_options: { include_usage: true }` for the final usage event.

Per-client setup snippets for `ruby-openai`, Azure OpenAI, LiteLLM proxy, and Gemini live in [`docs/cookbook.md`](docs/cookbook.md).

### 3. Manual `track` / `track_stream`

When you have a client that doesn't expose Faraday and isn't an official SDK — internal gateways, homegrown wrappers, batch jobs replaying historical usage:

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

For streaming the same way, `track_stream` accepts a block, parses provider events automatically, and records once the stream finishes. Full reference in [`docs/streaming.md`](docs/streaming.md).

## Tags: who burned this money

Tags answer the only question that matters in attribution: which feature, which user, which job, which tenant. They're free-form strings, indexed (JSONB on Postgres, fallback elsewhere), and queryable from both Ruby and the dashboard.

```ruby
LlmCostTracker.with_tags(user_id: current_user.id, feature: "support_chat", trace_id: request.uuid) do
  client.chat(parameters: { model: "gpt-4o", messages: [...] })
end
```

`with_tags` is thread- and fiber-isolated, so concurrent requests in Puma or jobs in Sidekiq don't bleed into each other. A `default_tags` callable on configuration runs on every event for things you always want — `environment`, `region`, deployment SHA. Explicit tags passed to `track` win over scoped tags, scoped tags win over defaults.

What you put in tags is **your** input — they're queryable strings. Don't put prompts, completions, emails, or secrets there. Use IDs.

## Pricing

Built-in prices live in `lib/llm_cost_tracker/prices.json` and are refreshed daily from official provider pricing pages by an automated CI workflow that opens a PR on every change. Most apps run on bundled prices and never think about this.

When you want to control updates yourself — for negotiated rates, gateway-specific model IDs, or pinned reviews — generate a local snapshot:

```bash
bin/rails generate llm_cost_tracker:prices
```

```ruby
config.prices_file = Rails.root.join("config/llm_cost_tracker_prices.yml")
```

Refresh on demand from the maintained snapshot:

```bash
bin/rails llm_cost_tracker:prices:refresh
```

Explain why a model is priced or unknown:

```bash
PROVIDER=openai MODEL=gpt-4o bin/rails llm_cost_tracker:prices:explain
```

Precedence is `pricing_overrides` → `prices_file` → bundled. Provider-qualified keys like `openai/gpt-4o-mini` win over model-only keys. Full pricing reference: [`docs/pricing.md`](docs/pricing.md).

## Budgets

Budgets are guardrails, not transactional caps:

```ruby
config.monthly_budget           = 500.00
config.daily_budget             = 50.00
config.per_call_budget          = 2.00
config.budget_exceeded_behavior = :block_requests   # or :notify, :raise
config.on_budget_exceeded       = ->(data) { SlackNotifier.notify("#alerts", "...") }
```

`:block_requests` reads ledger totals before a call goes out and stops it if you're already over. Under concurrency multiple workers can pass preflight at the same time and collectively overshoot — this catches the next call after the overshoot becomes visible, not the overshoot itself. For a strict cap, use a provider-side limit or a transactional counter outside the gem.

Full behavior, error class, and preflight details: [`docs/budgets.md`](docs/budgets.md).

## Querying

When you want to slice spend from a console, scheduled job, or your own admin page:

```ruby
LlmCostTracker::LlmApiCall.this_month.cost_by_model
LlmCostTracker::LlmApiCall.this_month.cost_by_tag("feature")
LlmCostTracker::LlmApiCall.daily_costs(days: 7)
LlmCostTracker::LlmApiCall.by_tags(user_id: 42, feature: "chat").this_month.total_cost
```

A text report is also one rake task away:

```bash
DAYS=7 bin/rails llm_cost_tracker:report
```

Full scope and helper reference: [`docs/querying.md`](docs/querying.md).

## Dashboard

Mount the engine wherever you want — it's plain ERB, no JavaScript bundle, no asset pipeline gymnastics:

```ruby
# config/routes.rb
mount LlmCostTracker::Engine => "/llm-costs"
```

Pages: overview (spend trend, budget status, anomaly banner), models, calls (filterable, paginated, CSV export), tags, data quality. Reads `llm_api_calls`, so use `:active_record` storage if you want to mount it.

Auth is your job. Examples for basic auth and Devise: [`docs/dashboard.md`](docs/dashboard.md).

## Supported providers

| Provider | Auto-detected | Coverage |
|---|:---:|---|
| OpenAI | Yes | GPT-5.5/5.4/5.2/5.1/5 + pro/mini/nano variants, GPT-4.1, GPT-4o, o1/o3/o4-mini |
| Anthropic | Yes | Claude Opus 4.7/4.6/4.5/4.1/4, Sonnet 4.6/4.5/4, Haiku 4.5 |
| Google Gemini | Yes | Gemini 2.5 Pro/Flash/Flash-Lite, 2.0 Flash/Flash-Lite |
| OpenRouter | Yes | OpenAI-compatible usage; provider-prefixed model IDs are normalized |
| DeepSeek | Yes | OpenAI-compatible usage; add `pricing_overrides` for DeepSeek-specific rates |
| Other OpenAI-compatible hosts | Configurable | Register the host via `config.openai_compatible_providers` |
| Anything else | Configurable | Custom parser — see [`docs/extending.md`](docs/extending.md) |

RubyLLM chat, embedding, and transcription calls are captured through RubyLLM's provider layer when `config.instrument :ruby_llm` is enabled.

Endpoints covered end-to-end: OpenAI Chat Completions / Responses / Completions / Embeddings, Anthropic Messages, Gemini `generateContent` and `streamGenerateContent`, plus their OpenAI-compatible equivalents. Streaming is captured for Faraday paths and official OpenAI / Anthropic SDK stream helpers whenever the provider emits final-usage events.

## Privacy

By design, **no prompt or response content is ever stored.** Per call, the ledger holds: provider, model, token counts, cost, latency, tags, response ID, timestamp. That's it. No request bodies, no headers, no completions. Warning logs strip query strings before logging URLs.

Tags carry whatever your app passes — they are application-controlled input, treat them accordingly. Use `user_id`, not the user's email; use a feature key, not the input prompt.

## Documentation

Deeper guides live in `docs/`. Reference pages are being filled out as content
moves out of this README; the inline sections above remain canonical where a page
is still brief.

- [Configuration reference](docs/configuration.md)
- [Pricing & price refresh](docs/pricing.md)
- [Budgets & guardrails](docs/budgets.md)
- [Querying & reports](docs/querying.md)
- [Dashboard mounting](docs/dashboard.md)
- [Streaming capture](docs/streaming.md)
- [Extending](docs/extending.md)
- [Production operations](docs/operations.md)
- [Upgrading](docs/upgrading.md)
- [Cookbook — per-client recipes](docs/cookbook.md)
- [Architecture & design rules](docs/architecture.md)

## Known limitations

- `:block_requests` is best-effort under concurrency, not a transactional cap.
- Streaming usage capture relies on the provider emitting a final-usage event. Missing events are stored with `usage_source: "unknown"` so they appear on the data-quality page rather than vanishing.
- `provider_response_id` is stored only when the provider exposes a stable ID. Gemini is best-effort and varies by endpoint.
- Cache write TTL variants on Anthropic (1h vs 5min writes) are not modeled separately yet.

## Development

```bash
bundle install
bin/check       # rubocop + rspec + coverage gate
```

Architecture rules and conventions for contributions live in [`AGENTS.md`](AGENTS.md) and [`docs/architecture.md`](docs/architecture.md).

## License

MIT — see [LICENSE.txt](LICENSE.txt).
