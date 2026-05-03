# Configuration

Configuration is the host app contract for capture, attribution, pricing,
budgets, and SDK instrumentation. Configure once at boot:

```ruby
LlmCostTracker.configure do |config|
  config.default_tags = -> { { environment: Rails.env } }
  config.prices_file = Rails.root.join("config/llm_cost_tracker_prices.yml")
  config.instrument :openai
end
```

`configure` finalizes shared mutable settings. Runtime attempts to replace or
mutate finalized shared config raise instead of silently changing tracking
behavior mid-request.

## Core Options

| Option | Default | Purpose |
| --- | --- | --- |
| `enabled` | `true` | Turns capture on or off without removing middleware or integrations |
| `default_tags` | `{}` | Hash or callable merged into every event |
| `log_level` | `:info` | Warning verbosity for unknown pricing and capture failures |
| `max_tag_count` | `50` | Maximum number of stored tags after sanitization |
| `max_tag_value_bytesize` | `1024` | Maximum byte size for one stored tag value |
| `redacted_tag_keys` | common secret-like keys | Tag keys whose values are replaced before storage |
| `report_tag_breakdowns` | `[]` | Extra tag keys rendered by `llm_cost_tracker:report` |

`default_tags` callables run per event. Keep them fast and side-effect free.
Explicit `tags:` passed to `track` win over scoped tags, and scoped tags win over
defaults.

## SDK Integrations

Enable supported SDK integrations with `instrument`:

```ruby
LlmCostTracker.configure do |config|
  config.instrument :openai
  config.instrument :anthropic
  config.instrument :ruby_llm
end
```

`config.instrument :all` enables every built-in integration. Enabled
integrations are fail-fast: the SDK gem must already be loaded, satisfy the
minimum supported version, and expose the expected resource classes and methods.

Built-in integration names:

| Name | Minimum SDK | Captured calls |
| --- | --- | --- |
| `:openai` | `openai >= 0.59.0` | Responses, Chat Completions, streaming helpers |
| `:anthropic` | `anthropic >= 1.36.0` | Messages and beta Messages helpers |
| `:ruby_llm` | `ruby_llm >= 1.14.1` | Provider chat, embedding, and transcription calls |

## OpenAI-Compatible Hosts

OpenAI-compatible capture is shape-based. Built-in mappings cover OpenRouter,
DeepSeek, and Groq:

```ruby
config.openai_compatible_providers["openrouter.ai"] = "openrouter"
config.openai_compatible_providers["api.deepseek.com"] = "deepseek"
config.openai_compatible_providers["api.groq.com"] = "groq"
```

Register custom gateway hosts when they speak OpenAI-compatible request and
response shapes:

```ruby
config.openai_compatible_providers["llm.internal.example"] = "internal_gateway"
```

This maps capture identity only. Gateway-specific prices belong in
`prices_file` or `pricing_overrides`.

## Pricing Options

| Option | Default | Purpose |
| --- | --- | --- |
| `prices_file` | `nil` | Local JSON/YAML registry used ahead of bundled prices |
| `pricing_overrides` | `{}` | Ruby hash used ahead of local and bundled registries |
| `unknown_pricing_behavior` | `:warn` | `:ignore`, `:warn`, or `:raise` for unknown token pricing |

Pricing precedence is:

1. `pricing_overrides`
2. `prices_file`
3. bundled `lib/llm_cost_tracker/prices.json`

Unknown service charges are still stored. They affect `cost_status` but do not
invent a total cost.

## Budget Options

| Option | Default | Purpose |
| --- | --- | --- |
| `monthly_budget` | `nil` | Monthly USD guardrail |
| `daily_budget` | `nil` | Daily USD guardrail |
| `per_call_budget` | `nil` | Single-event USD guardrail |
| `budget_exceeded_behavior` | `:notify` | `:notify`, `:raise`, or `:block_requests` |
| `on_budget_exceeded` | `nil` | Callable receiving the budget payload |

Budget payloads include `budget_type`, `total`, `budget`, and `last_event`.

## Capture Verification

After installing and migrating, run:

```bash
bin/rails llm_cost_tracker:doctor
bin/rails llm_cost_tracker:verify_capture
```

`doctor` checks schema, prices, integration setup, and operational health.
`verify_capture` records a synthetic manual event and verifies notifications plus
durable ActiveRecord persistence.
