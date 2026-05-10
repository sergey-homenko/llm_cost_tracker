# Configuration

Configuration is the contract between your app and the gem — capture,
attribution, pricing, budgets, SDK instrumentation. Set it up once at boot:

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
| `auto_enable_stream_usage` | `true` | Faraday middleware injects `stream_options: { include_usage: true }` on OpenAI / OpenAI-compatible chat-completions streaming requests so usage is captured automatically. See [Streaming](streaming.md). |

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

Unknown-cost line items are still stored. They affect `cost_status` but
won't invent a total cost out of thin air.

## Budget Options

| Option | Default | Purpose |
| --- | --- | --- |
| `monthly_budget` | `nil` | Monthly USD guardrail |
| `daily_budget` | `nil` | Daily USD guardrail |
| `per_call_budget` | `nil` | Single-event USD guardrail |
| `budget_exceeded_behavior` | `:notify` | `:notify`, `:raise`, or `:block_requests` |
| `on_budget_exceeded` | `nil` | Callable receiving the budget payload |

Budget payloads include `budget_type`, `total`, `budget`, and `last_event`.

## Storage

Two boolean flags decide which optional tables the gem touches. Both
default to `false`, so a fresh install ships with three mandatory
tables (`llm_cost_tracker_calls`, `llm_cost_tracker_call_line_items`,
`llm_cost_tracker_call_tags`).

| Option | Default | Purpose |
| --- | --- | --- |
| `durable_ingestion` | `false` | When `true`, `Tracker.record` writes a write-ahead row to `llm_cost_tracker_ingestion_inbox_entries`; a background worker drains rows into the ledger. Survives caller transaction rollbacks and batches inserts. When `false` (default), events write inline from the request thread. |
| `cache_rollups` | `false` | When `true`, `Tracker.record` maintains daily/monthly aggregates in `llm_cost_tracker_call_rollups`; budget reads and reconciliation diffs use the rollups fast path. When `false` (default), budget reads aggregate live from `llm_cost_tracker_calls`. |

Each opt-in needs a matching generator before flipping the flag:

```bash
bin/rails generate llm_cost_tracker:durable_ingestion  # for durable_ingestion = true
bin/rails generate llm_cost_tracker:call_rollups       # for cache_rollups = true
bin/rails db:migrate
```

`bin/rails llm_cost_tracker:doctor` warns when a table exists without
the matching flag (or vice versa) so the schema and config stay in
sync.

## Reconciliation (Experimental, Opt-In)

Provider invoice reconciliation is off by default. Enable it explicitly
when you have admin/org-level provider keys (`sk-admin-…`, Anthropic
admin keys, GCP `billing.viewer`) and a separate place to run them —
not the runtime app server.

| Option | Default | Purpose |
| --- | --- | --- |
| `reconciliation_enabled` | `false` | Master switch. When `false`, `Reconciliation.import` / `.diff` raise, the dashboard tab is hidden, doctor ignores reconciliation schema, and the `Reconciliation` namespace is not loaded at all. |
| `reconciliation_importers` | `{}` | Hash of callable importers per source. Used by the dashboard re-import button. Set via `register_reconciliation_importer(:source) { ... }`. |

Two opt-ins are required — the config flag and a separate generator:

```ruby
LlmCostTracker.configure do |config|
  config.reconciliation_enabled = true
  config.register_reconciliation_importer(:openai) { OpenaiCostsImportJob.perform_later }
end
```

```bash
bin/rails generate llm_cost_tracker:reconciliation
bin/rails db:migrate
```

Without both opt-ins, the gem stays a pure runtime tracker. See
[Upgrading](upgrading.md) for the migration path.

## Capture Verification

After installing and migrating, run:

```bash
bin/rails llm_cost_tracker:doctor
bin/rails llm_cost_tracker:verify_capture
```

`doctor` checks schema, prices, integration setup, and operational health.
`verify_capture` records a synthetic manual event and verifies notifications
plus ActiveRecord persistence (through the inline writer or the durable
inbox depending on `config.durable_ingestion`).
