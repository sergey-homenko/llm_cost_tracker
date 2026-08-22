# Configuration

Configuration is the contract between your app and the gem — capture,
attribution, pricing, budgets, SDK instrumentation. Set it up once at boot:

```ruby
LlmCostTracker.configure do |config|
  config.tags.default = -> { { environment: Rails.env } }
  config.pricing.file = Rails.root.join("config/llm_cost_tracker_prices.yml")
  config.instrument :openai
end
```

`configure` finalizes shared mutable settings. Runtime attempts to replace or
mutate finalized shared config raise instead of silently changing tracking
behavior mid-request.

Related options are grouped into namespaces — `budgets`, `tags`, `pricing`,
`ingestion`. The flat names that predate them still work and now emit a
deprecation warning naming their replacement; they are removed in 1.0.

## Core Options

| Option | Default | Purpose |
| --- | --- | --- |
| `enabled` | `true` | Turns capture on or off without removing middleware or integrations |
| `auto_enable_stream_usage` | `true` | Faraday middleware injects `stream_options: { include_usage: true }` on OpenAI / OpenAI-compatible chat-completions streaming requests so usage is captured automatically. See [Streaming](streaming.md). |

## Tag Options

| Option | Default | Purpose |
| --- | --- | --- |
| `tags.default` | `{}` | Hash or callable merged into every event |
| `tags.max_count` | `50` | Maximum number of stored tags after sanitization |
| `tags.max_value_bytesize` | `1024` | Maximum byte size for one stored tag value |
| `tags.redacted_keys` | common secret-like keys | Tag keys whose values are replaced before storage |
| `tags.breakdown_keys` | `[]` | Extra tag keys rendered by `llm_cost_tracker:report` |

`tags.default` callables run per event. Keep them fast and side-effect free.
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

`config.instrument :all` enables every built-in integration. The SDK
gem must already be loaded, satisfy the minimum supported version, and
expose the expected resource classes and methods, or `install!` raises.
Unknown integration names (typos like `:gemnii`) are accepted at config
time and logged once via `Logging.warn` at install time — they don't
crash boot, but the dashboard stays empty for that name.

Built-in integration names:

| Name | Minimum SDK | Captured calls |
| --- | --- | --- |
| `:openai` | `openai >= 0.59.0` | Responses, Chat Completions, streaming helpers |
| `:anthropic` | `anthropic >= 1.36.0` | Messages and beta Messages helpers |
| `:ruby_llm` | `ruby_llm >= 1.15.0` | Provider chat, embedding, transcription, image, and moderation calls |

The minimum is what `install!` enforces. CI resolves each SDK fresh on every
run, so the suite is exercised against the newest release the gemspec's
development dependencies allow. Versions between the minimum and that release
are supported but not covered by CI.

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

## Azure OpenAI Service

Azure OpenAI capture is built in — no configuration required. The Faraday
middleware matches URLs on `{resource}.openai.azure.com` and Foundry's
`{resource}.services.ai.azure.com`, both on the classic
`/openai/deployments/{deployment-id}/{operation}` path and the v1
`/openai/v1/{operation}` path, across chat/completions, completions,
embeddings, responses, moderations, audio/transcriptions,
audio/translations, audio/speech, images/generations, images/edits, and
images/variations. Responses parse with the same shape as OpenAI direct
and tag calls with `provider: "azure_openai"`. The OpenAI Ruby SDK is
also covered: if `OpenAI::Client.new` is initialized with an Azure
`base_url`, SDK-side capture in `record_response` detects the Azure
host and tags the same way.

Pricing for `azure_openai/<model>` resolves through the
`unique_providerless_model` match strategy in `Pricing::Matcher` to the
matching `openai/<model>` entry in the bundled price snapshot. That's correct for Global-tier
deployments in primary regions where Azure prices match OpenAI direct. If
your deployment uses Data Zone (data-residency) pricing or a regional
uplift that differs from Global, set per-key deltas via
`config.pricing.overrides` with the `azure_openai/<model>` prefix:

```ruby
config.pricing.overrides = {
  "azure_openai/gpt-4o-mini" => { input: 0.16, output: 0.64 }
}
```

## Pricing Options

| Option | Default | Purpose |
| --- | --- | --- |
| `pricing.file` | `nil` | Local JSON/YAML registry used ahead of bundled prices |
| `pricing.overrides` | `{}` | Ruby hash used ahead of local and bundled registries |
| `pricing.unknown_behavior` | `:warn` | `:ignore`, `:warn`, or `:raise` for unknown token pricing |

Pricing precedence is:

1. `pricing.overrides`
2. `pricing.file`
3. bundled `lib/llm_cost_tracker/prices.json`

Unknown-cost line items are still stored. They affect `cost_status` but
won't invent a total cost out of thin air.

## Budget Options

| Option | Default | Purpose |
| --- | --- | --- |
| `budgets.monthly` | `nil` | Monthly USD guardrail |
| `budgets.daily` | `nil` | Daily USD guardrail |
| `budgets.per_call` | `nil` | Single-event USD guardrail |
| `budgets.exceeded_behavior` | `:notify` | `:notify`, `:raise`, or `:block_requests` |
| `budgets.on_exceeded` | `nil` | Callable receiving the budget payload |

Budget payloads include `budget_type`, `total`, `budget`, `last_event`, and `stage` (`:pre_send` for preflight blocks under `:block_requests`, `:post_spend` for post-record checks). See [Budgets and Guardrails](budgets.md) for the pre-send estimate behavior.

## Storage

Two boolean flags decide which optional tables the gem touches. Both
default to `false`, so a fresh install ships with three mandatory
tables (`llm_cost_tracker_calls`, `llm_cost_tracker_call_line_items`,
`llm_cost_tracker_call_tags`).

| Option | Default | Purpose |
| --- | --- | --- |
| `ingestion.mode` | `:inline` | When `:async`, `Tracker.record` writes a write-ahead row to `llm_cost_tracker_ingestion_inbox_entries`; a background worker drains rows into the ledger. Survives caller transaction rollbacks and batches inserts. When `:inline` (default), events write inline from the request thread. |
| `ingestion.pool_size` | `2` | Size of the dedicated ActiveRecord connection pool the async ingestion worker uses for inbox writes (kept isolated from the request connection pool so a busy app doesn't deadlock its own tracking). Bump it if your Puma worker count × concurrent `Tracker.record` calls outgrows the default. Ignored when `ingestion.mode = :inline`. |
| `cache_rollups` | `false` | A *rollup* is a pre-aggregated daily/monthly total. When `true`, `Tracker.record` maintains those totals in `llm_cost_tracker_call_rollups` and budget and dashboard reads use them instead of scanning the ledger. When `false` (default), reads aggregate live from `llm_cost_tracker_calls`. |

Each opt-in needs a matching generator before flipping the flag:

```bash
bin/rails generate llm_cost_tracker:async_ingestion    # for ingestion.mode = :async
bin/rails generate llm_cost_tracker:call_rollups       # for cache_rollups = true
bin/rails db:migrate
```

`bin/rails llm_cost_tracker:doctor` warns when a table exists without
the matching flag (or vice versa) so the schema and config stay in
sync.

## Capture Verification

After installing and migrating, run:

```bash
bin/rails llm_cost_tracker:doctor
bin/rails llm_cost_tracker:verify_capture
```

`doctor` checks schema, prices, integration setup, and operational health.
`verify_capture` records a synthetic manual event and verifies notifications
plus ActiveRecord persistence (through the inline writer or the async
inbox depending on `config.ingestion.mode`).
