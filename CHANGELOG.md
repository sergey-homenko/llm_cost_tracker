# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `budget_exceeded_behavior = :block_requests` now also blocks before send when an estimate of the call's input cost plus prior spend would cross the daily / monthly limit, or when the estimate alone crosses `per_call_budget`. `BudgetExceededError` and `on_budget_exceeded` payloads gain a `stage` field (`:pre_send` or `:post_spend`). Calls to models with no pricing match skip the pre-send check. See [Budgets](docs/budgets.md).
- `bin/rails llm_cost_tracker:backfill_unknown_pricing` rake task recomputes cost, pricing snapshot, line-item costs, and rollup buckets for calls that landed with no pricing (e.g. a new model recorded before the next scraper refresh added its rates). The Data Quality dashboard's "Unknown pricing by model" panel points at this task. Idempotent — re-running only touches calls still missing a cost.
- Azure OpenAI Service is captured out of the box across both Azure OpenAI (`*.openai.azure.com`) and Microsoft Foundry (`*.services.ai.azure.com`) hostnames, and on both the classic `/openai/deployments/{name}/{operation}` path and the v1 `/openai/v1/{operation}` path. OpenAI Ruby SDK calls made with either base URL also tag as `provider: "azure_openai"`. Pricing resolves to the matching `openai/<model>` entry; regional / Data Zone uplifts are configurable via `config.pricing_overrides` with the `azure_openai/<model>` prefix. See [Configuration → Azure OpenAI Service](docs/configuration.md#azure-openai-service).
- `bin/rails generate llm_cost_tracker:upgrade_provider_invoice_imports_provider` writes the migration so two reconciliation importers sharing a `source` (e.g. `csv/openai` and `csv/anthropic`) no longer cross-pollute resume cursors.
- `bin/rails generate llm_cost_tracker:upgrade_provider_invoices_metadata_index` writes a migration adding a GIN index on `llm_cost_tracker_provider_invoices.metadata` (PostgreSQL only) so reconciliation metadata lookups don't seq-scan on large invoice sets. No-op on MySQL.
- A `prices_file` with `metadata.currency: "EUR"` (or any non-USD code) now flows through to the call's `pricing_snapshot.currency`, the `call_rollups.currency` bucket, every `call_line_items.currency` row (token and service-charge alike), and the header `cost.currency` instead of being hardcoded to USD. The bundled price snapshot and `pricing_overrides` still default to USD; mixed-currency line items continue to drop from the header total with a warning.

### Fixed

- OpenAI Chat Completions calls to the specialized search models (`gpt-4o-search-preview`, `gpt-4o-mini-search-preview`, `gpt-5-search-api`) record the per-call web-search fee as a line item at OpenAI's "Web search preview" rate (non-reasoning $25/1k, reasoning $10/1k). These models always search before responding, so the fee applies on every non-streaming call.
- Async ingestion writes through its own dedicated connection pool instead of competing with request-handling threads, so tracking an LLM call from inside a caller transaction no longer deadlocks under burst load and the inbox row still persists when the caller transaction rolls back. Tune via `config.ingestion_pool_size` if your PG / PgBouncer budget is tight.
- `mount LlmCostTracker::Engine => "/llm-costs"` works without adding `require "llm_cost_tracker/engine"` to `config/application.rb` — the engine is autoloaded.
- Upgrade migrations for the call_rollups and call_tags indexes build concurrently on PostgreSQL, so the upgrade no longer takes a long table-write lock on installs with millions of rows. The rollups upgrade keeps pre-upgrade aggregates (bucketed under empty provider) instead of wiping them.
- CSV exports stream in 500-row batches so peak memory stays flat at large export sizes while the user-selected sort order is preserved (`?sort=expensive`, `?sort=slow`, etc.).
- `bin/rails generate llm_cost_tracker:install` skips `config/initializers/llm_cost_tracker.rb` when it already exists instead of prompting Thor's "overwrite?" dialog, so re-running the generator in CI no longer hangs waiting on stdin.
- Async inbox entries no longer truncate on MySQL — large pricing snapshots and stack traces stay intact (MEDIUMTEXT instead of TEXT cap at 64 KB). PostgreSQL is unaffected.
- Logs no longer warn `unknown pricing for model X` when the call has no token pricing but at least one service charge was successfully priced. Misleading false-positive is gone for Anthropic web-search-style calls on models missing from the token-pricing table.
- `llm_cost_tracker:prune` rake task also prunes async inbox entries and finished provider invoice imports past the `DAYS` cutoff, so pending or quarantined rows no longer flush retroactively and old import-cursor rows don't linger forever.
- Azure OpenAI deployments using `audio/speech`, `images/edits`, `images/variations`, `moderations`, or `responses` endpoints are now captured by the Faraday parser; previously only `chat/completions`, `completions`, `embeddings`, `audio/transcriptions`, `audio/translations`, and `images/generations` matched.
- `prices:refresh` drops service-charge keys when a scraper stops emitting them, so stale charges no longer linger in the local price snapshot. Scrapers that don't parse a charges section (groq, gemini) preserve existing entries.

### Changed

- Schema: `llm_cost_tracker_provider_invoice_imports` gains a `provider` column and replaces the `(source, started_at)` index with `(source, provider, started_at)`. Existing installs run `bin/rails generate llm_cost_tracker:upgrade_provider_invoice_imports_provider && bin/rails db:migrate`.
- BREAKING: `config.durable_ingestion = true/false` is replaced by `config.ingestion = :inline | :async` (default `:inline`). `config.durable_ingestion_pool_size` is renamed to `config.ingestion_pool_size`, and the install generator is now `bin/rails generate llm_cost_tracker:async_ingestion`. Update `config/initializers/llm_cost_tracker.rb` accordingly.

## [0.9.0] - 2026-05-12

0.9 leans the default install: only `calls`, `call_line_items`, and `call_tags`
are mandatory. Durable ingestion, rollup-cached budget reads, and provider
invoice reconciliation are opt-in behind config flags and dedicated generators.
Plus expanded SDK capture (OpenAI embeddings/audio/images/moderation, RubyLLM
paint/moderate), correct handling of Anthropic data residency and Priority
Tier, and a security-hardened dashboard. Existing installs need a migration —
see [Upgrading](docs/upgrading.md).

### Added

- **Experimental:** opt-in provider invoice reconciliation. Set `config.reconciliation_enabled = true` and run `bin/rails generate llm_cost_tracker:reconciliation`. Public surface: `LlmCostTracker::Reconciliation.import / .diff`, `config.register_reconciliation_importer(:source) { … }`, rake tasks `llm_cost_tracker:reconcile:import` and `:reconcile:diff`. Doctor warns when drift exceeds 5% or imports go stale past 14 days. See [Configuration](docs/configuration.md#reconciliation-experimental-opt-in).
- Dashboard Data Quality page now shows a "Streaming health by provider" breakdown (streams, with-usage, unknown, unknown share) so a misconfigured OpenAI-compatible host shipping streams without `stream_options.include_usage` is visible at a glance.
- Dashboard tag detail page drills into a single value via `?tag_value=…` with total cost, call count, average per call, and a daily spend timeseries.
- Bundled rates for OpenAI embeddings (`text-embedding-3-small` / `-3-large` / `-ada-002`, including 50% batch discount) and token-priced transcription (`gpt-4o-transcribe`, `gpt-4o-mini-transcribe`). Token-priced transcription splits audio and text inputs at their separate rates. DALL-E and Whisper still record as zero-token visibility events until their per-image / per-minute pricing components land.
- OpenAI `gpt-image-1` / `gpt-image-1-mini` / `gpt-image-1.5` / `gpt-image-2` priced per image-token at their published standard rates, with `batch_*` shadow rates for the 50% batch tier. (Earlier preview snapshots stored only the batch rates, which silently halved image-generation costs.) The SDK integration extracts `usage.input_tokens_details.image_tokens` for image-as-input flows (edits / variations) and treats `usage.output_tokens` as image output. Requires the new `bin/rails generate llm_cost_tracker:upgrade_image_tokens` migration on v0.8 → v0.9 upgrades.
- OpenAI `tts-1` / `tts-1-hd` priced per character (request `input.length`). `gpt-4o-mini-tts` is left as a zero-cost visibility event because its tokens are not exposed to the client.
- OpenAI SDK integration now also patches `Embeddings#create`, `Images#generate` / `#edit` / `#create_variation`, `Audio::Transcriptions#create`, `Audio::Speech#create`, `Moderations#create`, and `Chat::Completions#stream`. Calls without provider-reported usage record as zero-token visibility events.
- RubyLLM SDK integration also records `Provider#paint` and `Provider#moderate`.
- `bin/rails generate llm_cost_tracker:upgrade_call_rollups_provider` writes the v0.8 → v0.9 migration that adds the `provider` column and swaps the unique index. Re-runs are no-ops.
- [EU AI Act record-keeping guide](docs/eu_ai_act.md) — maps the ledger fields and `llm_cost_tracker:prune` retention to Article 26(6) deployer obligations (≥ 6-month retention, traceability, attribution tags). Not legal advice.

### Fixed

- Subscriber failures during `Tracker.record` no longer lose the event — the ledger write happens first; subscriber errors are caught and logged.
- Header `total_cost` no longer mixes currencies. Mismatched service-line costs keep their per-line currency and are excluded from the header total (with a warning).
- Budget reads aggregate across all rollup currencies instead of being silently scoped to USD only.
- `bin/rails llm_cost_tracker:setup` no longer fails with `Missing Thor class for invoke llm_cost_tracker:prices`, is idempotent on re-runs, and surfaces a friendly error when the database is unreachable.
- Stream events are no longer lost when finalization raises. The collector retries on the next `finish!`. Abandoned streams (wrapped but never iterated) emit a usage event instead of disappearing.
- Faraday streaming overflow keeps the buffer accumulated up to the limit (matching the SDK collector) instead of dropping all events.
- Edits to `config.prices_file` are picked up without a gem reload — the lookup cache invalidates on file mtime changes.
- Models flagged with `_source: "manual"` in the local prices file are preserved through `prices:refresh` when the remote registry does not claim the same key.
- Anthropic Priority Tier no longer falls to `cost_status: unknown`. It's a throughput commitment, not a per-token surcharge — both the SDK integration and the Faraday parser treat `service_tier: "priority"` as standard pricing.
- Anthropic `data_residency` mode triggers on `inference_geo: "us"` only — the documented +1.1x uplift tier. Earlier preview ranges that listed `"eu"` were incorrect; EU data residency runs through Bedrock Frankfurt or Vertex Belgium with separate pricing, not the Anthropic API.
- Anthropic `web_fetch_request` is recorded with a `$0` rate (Anthropic bills web fetch via standard tokens, not per fetch). The scraper picks up the "no additional charges" wording so `prices:refresh` keeps it accurate.
- OpenAI `web_search_call` is now priced model-aware. The legacy `web_search_preview` tool routes to `web_search_preview_request_reasoning` ($10/1k for gpt-5/o-series) or `web_search_preview_request_non_reasoning` ($25/1k for everything else), matching OpenAI's three published web-search billing paths. `gpt-5-chat-latest` and dotted variants (`gpt-5.1-chat-latest`, `gpt-5.2-chat-latest`, …) are classified as non-reasoning despite the `gpt-5` prefix.
- Anthropic Cost API reconciliation now ingests rows against live admin payloads (preview builds expected obsolete field names and produced zero rows). `service_tier: "batch"` and `inference_geo: "us"` are the only dimensions that promote a row's `pricing_mode`.
- Reconciliation diff windows are anchored in UTC; non-UTC servers no longer skew the window.
- Reconciliation provider totals sum only invoices fully contained in the diff window. Partially overlapping invoices no longer count at their full `billed_amount`.
- Reconciliation diff window upper bound is now exclusive of midnight on the day after `period_end`. Calls tracked at exactly `00:00:00.000` of the next month no longer get counted in both periods.
- `Reconciliation.import` / `Reconciliation.diff` accept (and require, for unmapped sources) an explicit `provider:`. Built-in mappings cover `openai`, `openai_usage`, `anthropic`, `anthropic_usage`, `gemini`. CSV and other custom sources must pass `provider:` (or be derivable from a prior import's metadata) — the previous silent fall-through summed local calls across every provider.
- Reconciliation import errors no longer echo the exception verbatim into the dashboard flash. The full trace goes to logs; the alert shows the exception class only.
- `Reconciliation::Importer` works on MySQL/Trilogy installs (adapter-aware `upsert_all`).
- Reconciliation `external_id` is namespaced by `source/provider` for sources that carry multiple providers (e.g. `csv/openai:row-1` vs `csv/anthropic:row-1`). The same CSV row id imported under two providers no longer collides on the unique index. Native sources keep their `openai:` / `anthropic:` / `gemini:` prefix.
- Reconciliation dashboard groups latest-period and drill-down by source, provider, and currency. A second provider importing under the same source no longer hides its drift in the first provider's row.
- OpenAI Cost API reconciliation tags the organization id under `provider_workspace_id` so org-level scope filters work.
- Reconciliation diff drill-down is capped at the top 100 unmatched rows by amount with totals counted separately, so the dashboard stays responsive on large monthly reconciliations. Pass `DRILLDOWN_LIMIT=all` to `rake llm_cost_tracker:reconcile:diff` to see every row.
- Period totals fall back to live aggregation from `llm_cost_tracker_calls` when `cache_rollups = true` but the rollups table has no row for the period. Budget reads and dashboard totals no longer read zero during a rollup rebuild window after the v0.9 upgrade migration.
- OpenAI hosted-tool service line items (`web_search_call`, `file_search_call`, `code_interpreter_call`, `mcp_call`) are recorded when the SDK returns the type as a Symbol. Previously these line items were silently dropped on SDK-shaped responses.
- Image generation streams (`gpt-image-1.5`, `gpt-image-2`) and audio streams no longer overflow on a single base64 chunk; the final usage event is captured and tokens get priced.
- Interrupted Anthropic and Gemini streams record the right provider name instead of `provider: "unknown"`.
- Tag sanitizer redacts secrets before truncating, so the leading bytes of a secret can't survive a small `max_tag_value_bytesize`. Nested `[REDACTED]` markers stay whole regardless of the byte budget.
- `Pricing::Registry` rejects non-finite price values (`Infinity` / `NaN`) alongside negatives.
- Reconciliation `ProviderInvoiceImport.started_at` is the wall-clock import time. Backfills with a historical `imported_at` no longer invert `resume_cursor_for` ordering.
- Reconciliation install migration is re-runnable on installs that already carry the v0.8 placeholder tables.
- Pre-release v0.9 deployers who imported reconciliation rows before these fixes need `LlmCostTracker::ProviderInvoice.delete_all` and a re-import — the `external_id` prefix and the OpenAI organization-id field both changed shape.
- Budget reads survive the v0.9 upgrade migration's rollup truncation — a partial rollup row no longer hides historical pre-migration spend in the same period.
- Streaming requests that hit `unknown_pricing_behavior = :raise` after the response is received raise without recording a synthetic zero-token event.
- Reconciliation doctor checks each `source / provider / currency` combination separately; a stale Anthropic CSV import no longer hides behind a fresh OpenAI one on the same source.
- Reconciliation imports normalise `currency` to upper case so `usd` and `USD` no longer split the diff.
- Reconciliation dashboard and CLI render `n/a` for invoice rows imported with no `billed_amount` instead of `$0.00`.
- Reconciliation diff drill-down shows the actual unmatched rows even when most invoices match — small-amount unmatched rows are no longer hidden by a wall of matched big-amount rows.
- OpenAI SDK Responses calls bill image and text tokens separately for `gpt-image-*` models, matching the Faraday parser.
- OpenAI SDK integration captures the request when the caller passes a typed request object (anything that responds to `to_h`) instead of dropping it.
- Custom prices files with `Infinity` / `NaN` service-charge rates fail to load with a clear error instead of silently corrupting cost math.
- High-cardinality tag filters (`Call.by_tag(:tenant_id, …)`) now hit a composite index instead of scanning. Existing installs run `bin/rails generate llm_cost_tracker:upgrade_call_tags_key_value_index && bin/rails db:migrate`.
- Reconciliation diff over a large invoice set uses an index scan on the new `(source, currency, period_start)` composite.
- Doctor warns when provider invoice rows are stored with non-uppercase currency and points at the one-line backfill SQL, instead of the dashboard silently zeroing out diffs against legacy lowercase data.
- A request-level `pricing_mode` no longer overrides what the provider reports back on a streamed response. Provider-reported standard wins over a request that asked for priority.
- The new generators (`call_rollups`, `durable_ingestion`, `reconciliation`, `upgrade_call_rollups_provider`) are reachable through `bin/rails generate llm_cost_tracker:<name>`.
- Faraday streaming captures no longer silently degrade to `usage_source: :unknown`.
- Dashboard filters apply the default 30-day range when `from`/`to` params are missing.
- `provider_api_key_id` and `provider_workspace_id` are masked on the call detail page and CSV export. Host apps that added a `metadata` column written as a JSON string now flow through the same masking instead of rendering the raw column.
- Faraday parser tracks OpenAI `/v1/images/*` and `/v1/audio/transcriptions`/`/v1/audio/translations` so raw-Faraday image generations and transcriptions land in the ledger. `/v1/audio/speech` and `/v1/moderations` are also matched so `Tracker.enforce_budget!` gates them; they do not record a row because OpenAI does not return token usage for those endpoints.
- OpenAI SDK `Audio::Translations#create` is now patched alongside `Audio::Transcriptions#create`.
- OpenAI SDK `Images#generate` / `#edit` / `#create_variation` no longer double-counts cached input tokens.
- OpenAI SDK `Responses.create` and Faraday parser both route output to `image_output_tokens` for `gpt-image-*` models even when the response omits `output_tokens_details.image_tokens`.
- OpenAI SDK `Images#generate` / `#edit` / `#create_variation` no longer drops the text-output remainder when `output_tokens_details` reports only `image_tokens`. The remainder lands as `output_tokens`, matching the Faraday parser.
- RubyLLM `Provider#paint` for `gpt-image-*` models records image output tokens under `image_output_tokens` so image rates apply.
- RubyLLM integration treats Anthropic `service_tier: "priority"` as standard pricing (Priority Tier is committed throughput, not a surcharge). Previously these calls fell to `cost_status: unknown` because the literal `"priority"` was passed through as `pricing_mode`.
- Reconciliation diff falls back to live `llm_cost_tracker_call_line_items` aggregation when the rollup fast path finds no row for the period. Without the fallback, past-month diffs after the v0.9 `upgrade_call_rollups_provider` migration (which truncates rollups) would report `local_total = $0` until events repopulate the new schema.
- Provider-invoice reconciliation falls back to `match_basis: "model"` (was `period_only`) when an invoice carries only a model identifier.
- `prices:refresh` bootstraps a missing local pricing file instead of failing with `Errno::ENOENT`.
- Doctor's durable-inbox verification no longer leaves a synthetic inbox row behind when `Tracker.track` raises `BudgetExceededError`.
- Install-generator snippet in [Upgrading](docs/upgrading.md) for the reconciliation table now matches the shipped index (`(source, currency, period_start)`).
- Doctor catches schema drift on required columns, required indexes, and the foreign key on `call_line_items` before the first row is inserted.
- Service-charge rows render `n/a` instead of `$0.00` when `cost_status` is `unknown`, so unpriced charges don't masquerade as zero-cost.
- Enabling `:ruby_llm` together with `:openai` / `:anthropic` logs a warning at install — RubyLLM routes through HTTP, so calls would otherwise be double-counted. Pick one path per provider.

### Changed

- BREAKING: `bin/rails generate llm_cost_tracker:install --dashboard` no longer writes the `mount LlmCostTracker::Engine` line into `config/routes.rb`. The CLI prints the snippet wrapped in your auth instead — leaving the dashboard auto-mounted would expose spend, tags, and provider IDs to anyone who can reach the host. Add the route under your authentication block.
- BREAKING: `config.durable_ingestion` defaults to `false`. Tracking writes go directly to the ledger from the request thread; the durable inbox + worker + leases tables are no longer created by the install generator. Existing installs keep their tables — set `config.durable_ingestion = true` to keep the inbox path. Fresh installs that need durability run `bin/rails generate llm_cost_tracker:durable_ingestion` and flip the flag.
- BREAKING: `config.cache_rollups` defaults to `false`. Budget reads aggregate live from `llm_cost_tracker_calls`; the rollup table is no longer created by the install generator. Existing installs keep their table — set `config.cache_rollups = true` to keep the rollup fast path. Fresh installs run `bin/rails generate llm_cost_tracker:call_rollups` and flip the flag.
- BREAKING: `llm_cost_tracker_call_rollups` gains a `provider` column; unique index moves from `(period, period_start, currency)` to `(period, period_start, currency, provider)`. See [Upgrading](docs/upgrading.md).
- BREAKING: `llm_cost_tracker_calls` gains `image_input_tokens` and `image_output_tokens` columns (default 0) so OpenAI `gpt-image-*` models can bill image-token rates separately from text. Run `bin/rails generate llm_cost_tracker:upgrade_image_tokens && bin/rails db:migrate`. CSV exports include the new columns between `audio_input_tokens` / `output_tokens` and `audio_output_tokens` / `total_tokens` respectively — downstream consumers indexing by header name keep working; positional consumers shift by two.
- BREAKING: `LlmCostTracker::Call.by_tag(key, value)` encodes Hash and Array values with `JSON.generate` to match how `Ledger::Store` writes them. The previous `value.to_s` path produced `"{:k=>v}"`-shaped strings that never matched stored JSON, so filtering by nested attribution silently returned zero rows.
- Faraday middleware auto-injects `stream_options: { include_usage: true }` on OpenAI and OpenAI-compatible chat-completions streaming requests when the caller hasn't set it. Disable with `config.auto_enable_stream_usage = false`.
- Header `total_cost` and per-line-item rates can no longer disagree on the context-tier boundary or the resolved pricing mode.
- OpenAI-compatible chat-completions streams without a final usage chunk log a warning instead of recording silently as `usage_source: "unknown"`.
- `Tags::Sanitizer` redacts tag values matching known secret patterns (OpenAI/Anthropic, GitHub, AWS, JWT, Slack, Stripe, Google API key, `Bearer …`) regardless of tag key, recurses into nested Hash/Array leaves, and on tag-count overflow keeps the most recently added tags. `Tags::Context` sanitises at block entry so raw values never reach notification subscribers, the Faraday request env, or in-flight stream collectors.
- Engine dashboard adds CSRF protection on the reconciliation import endpoint, sets `Cache-Control: no-store` on CSV exports, registers `tag` / `tag_value` in `config.filter_parameters`, and emits `X-Frame-Options: DENY` / `Referrer-Policy: same-origin` / a baseline `Content-Security-Policy` on every dashboard response. CSV export is capped at 10,000 rows and respects the requested sort.
- Dashboard schema drift check runs once per process instead of on every request, cutting per-request DB metadata load. Code reloads in development still trigger a re-check.
- Dashboard dynamic widths (progress bars, budget fills, stack segments) render via a per-request CSP-nonced `<style>` block instead of inline `style="…"` attributes. Strict `style-src 'self' 'nonce-…'` no longer collapses the visualisations.

## [0.8.0] - 2026-05-07

0.8 is a storage rebuild. Tokens and tool/runtime charges share one shape
(`Billing::LineItem`) and live in a dedicated line items table. Per-component
cost columns and the standalone service charges table are gone. Several tables
were also renamed during the cycle. See [Upgrading](docs/upgrading.md) for the
migration path — there is no rolling-deploy upgrade.

### Added

- `llm_cost_tracker_call_line_items` — one row per priced component (text/audio/cached tokens, web search, code execution, grounding, container sessions, file search). Tokens and tool charges share one shape and one `cost_status` semantics.
- `llm_cost_tracker_call_tags` — normalized attribution. Tag filters and aggregations now JOIN through this table on PostgreSQL and MySQL alike.
- `llm_cost_tracker_provider_invoices` — placeholder table reserved for v0.9 invoice reconciliation.
- `Billing::LineItem` value object covering both token and service charges. `LineItem.from_token_usage` and explicit `component_key:` builders price token and tool/runtime quantities through the same path.
- `Pricing.price_line_items` — single pricing pass for token + tool/runtime line items, used by `Tracker.build_event`.
- Doctor schema checks for `llm_cost_tracker_call_line_items`, `llm_cost_tracker_call_tags`, and `llm_cost_tracker_provider_invoices`.
- Doctor sample-based drift checks: header `total_cost` vs `SUM(line_items.cost)` and stored line item cost vs `pricing_snapshot.rates` (RFC §Doctor).
- `currency` column on `llm_cost_tracker_call_rollups` (default `USD`) with a `(period, period_start, currency)` unique index. v0.8 stays single-currency; the schema is in place so v0.9 multi-currency rollups don't need another migration.
- `Billing::Components::REGISTRY` now loads from `lib/llm_cost_tracker/billing/components.yml`. Adding a billable component is one YAML row plus a price entry — no more 11-line `Component.new(...)` literals.
- Anthropic web search and code execution usage emitted as line items with `component_key: :web_search_request` / `:code_execution_request`. SDK integration emits the same line items from native SDK responses, not just Faraday-wrapped ones.
- OpenAI hosted web search, file search, and Code Interpreter container sessions emitted as line items via both Faraday and SDK integration paths.
- Gemini grounding queries emitted as line items.
- `provider_project_id`, `provider_api_key_id`, `provider_workspace_id`, `batch` capture dimensions on `LlmCostTracker.track` and the `Event` payload, persisted as columns on `llm_cost_tracker_calls`.
- `Pricing::EffectivePrices` permutes compound pricing modes (e.g. `priority_batch_data_residency`) when matching rates, so combined modes resolve correctly.
- `Pricing::Sync` registry-diff compares `service_charges` rates in addition to model rates.
- Dashboard polish pass: shared `_filters.html.erb` and `_sort.html.erb` partials, sticky table headers, button hover/active states, spacing/shadow scales, and a full `prefers-color-scheme` dark palette.
- Bundled audio and tool rates refreshed from current provider pricing.

### Changed

- BREAKING: Renamed `llm_api_calls` → `llm_cost_tracker_calls`, `llm_cost_tracker_period_totals` → `llm_cost_tracker_call_rollups`, `llm_cost_tracker_inbox_events` → `llm_cost_tracker_ingestion_inbox_entries`, `llm_cost_tracker_ingestor_leases` → `llm_cost_tracker_ingestion_leases`. Corresponding model `LlmCostTracker::PeriodTotal` renamed to `LlmCostTracker::CallRollup`; ingestion models live under `LlmCostTracker::Ingestion::InboxEntry` and `LlmCostTracker::Ingestion::Lease`.
- BREAKING: Per-component cost columns removed from `llm_cost_tracker_calls` (`input_cost`, `output_cost`, `cache_read_input_cost`, `cache_write_input_cost`, `cache_write_extended_input_cost`, `cache_write_1h_input_cost`, `audio_input_cost`, `audio_output_cost`). The header keeps `total_cost` only; per-component costs live in line items.
- BREAKING: `llm_cost_tracker_calls.tags` JSONB column removed in favor of `llm_cost_tracker_call_tags`. `Call#parsed_tags`, `Call.by_tags`, `Call.cost_by_tag`, `Call.group_by_tag`, and the dashboard tag explorer now read the normalized table.
- BREAKING: `llm_cost_tracker_service_charges` table removed. Tool/runtime rows are stored in `llm_cost_tracker_call_line_items` with `unit != 'token'`.
- BREAKING: `Billing::ServiceCharge` value object and `LlmCostTracker::ServiceCharge` AR model removed. Use `Billing::LineItem` and `LlmCostTracker::CallLineItem`.
- BREAKING: `Event#service_charges` removed. Filter `event.line_items` by `unit != :token` instead.
- BREAKING: `Call#service_charges` association removed. Use `call.line_items.where.not(unit: "token")`.
- BREAKING: `LlmCostTracker.track(service_charges:)` keyword renamed to `service_line_items:`. Hash keys: `component:` → `component_key:`, `source_key:` → `provider_field:`, `pricing_basis: PROVIDER_USAGE_BASIS` → `pricing_basis: :provider_usage`.
- BREAKING: `Billing::CostStatus.call(service_charges:)` keyword renamed to `service_line_items:`.
- BREAKING: `Pricing.cost_with_service_charges` public API removed; replaced internally by `Pricing.price_line_items`.
- BREAKING: Top-level delegators `LlmCostTracker.flush!`, `LlmCostTracker.shutdown!`, `LlmCostTracker.enforce_budget!` removed. Use `LlmCostTracker::Ingestion::Worker.flush!` / `.shutdown!` directly; budget enforcement is internal.
- BREAKING: `LlmCostTracker.track` requires explicit `tokens:` and accepts `tags:` as a hash; the previous keyword shape is no longer supported.
- BREAKING: Notification payload (`llm_request.llm_cost_tracker`) no longer carries `service_charges`. Subscribers read `line_items`.
- BREAKING: Inbox payload v0/v1 compatibility dropped; only v2 is accepted. Drain any pre-v2 entries on the prior gem version before bumping.
- BREAKING: Ruby 3.4+ required.
- BREAKING: Legacy upgrade generators removed (`add_billing`, `add_ingestion`, `add_call_rollups`, `add_capture_dimensions`, `add_latency_ms`, `add_provider_response_id`, `add_streaming`, `add_token_usage`, `upgrade_cost_precision`, `upgrade_schema_foundation`, `upgrade_tags_to_jsonb`). Doctor no longer suggests them.
- `llm_cost_tracker_call_tags.value` widened to TEXT (was VARCHAR), and the `[:key, :value]` composite index dropped in favor of `:key` only — value-equality filters scan the per-key bucket.
- `Configuration#pricing_overrides` validates shape at assignment time rather than at first read.
- Pricing computes a partial `total_cost` (with `cost_status: :partial`) when only some token components have rates; previously `total_cost` was nil whenever any component lacked a rate.
- `TokenUsage.build` clamps negative token counts to zero so anomalous provider payloads don't poison rollups.
- Stream collector buffer overflow keeps already-accumulated events instead of dropping them.
- Budget guardrail preflight time is excluded from SDK call latency measurements.
- Dashboard data-quality breakdown computes per-component cost from line items via JOIN; usage_rows accepts `component_costs:` hash.
- CSV export pulls tag JSON from `tag_records` instead of the dropped JSONB column.
- The fingerprinted dashboard stylesheet is served with `Cache-Control: no-store` in development so edits show up without a hard reload; production keeps the immutable cache.

### Fixed

- Railtie no longer requires removed legacy upgrade generators at boot, so installs on a clean app don't crash during eager-load.
- `Tracker` only flags unknown pricing when token quantities are positive — service-only events with zero tokens no longer raise `Pricing::Unknown`.
- `Billing::CostStatus.cost_status_for` coerces symbol/string status values consistently when building line items.
- Gemini `thoughtsTokenCount` is billed at the output token rate (already present in 0.7.3, kept for clarity given the rebuild).

### Removed

- Dead `Billing::LineItem.from_service_charge` constructor and the unused `Call.with_json_tags` scope.

## [0.7.3] - 2026-05-01

### Fixed

- Gemini API thinking tokens no longer get added to output tokens twice.

## [0.7.2] - 2026-05-01

### Added

- Groq auto-detection, price scraping, and bundled production text model prices.

### Changed

- Bundled prices refreshed from official provider pricing as of 2026-05-01.
- Bundled prices now include OpenAI Flex/Priority/regional processing, Gemini Flex/Priority, and Anthropic fast/data residency rates.

### Fixed

- Streaming capture now snapshots tags when the stream starts.

## [0.7.1] - 2026-04-30

### Changed

- BREAKING: ActiveRecord ledger write failures now raise directly; removed `storage_error_behavior` and `StorageError`.
- BREAKING: Removed custom parser and SDK integration registration APIs; use built-in capture or explicit `track` / `track_stream`.
- BREAKING: Usage and pricing APIs now use `TokenUsage`; removed `UsageBreakdown`, `add_usage_breakdown`, direct `Pricing` token arguments, and `Pricing::Cost`.
- BREAKING: `Tracker.record` now accepts `UsageCapture`, and notification payloads nest `token_usage`.
- BREAKING: Moved price registry and refresh APIs under `LlmCostTracker::Pricing`.
- BREAKING: ActiveRecord installs must run the current ledger and period-total migrations; doctor, dashboard setup, and flush now fail on stale schema.
- BREAKING: `cache_write_input_tokens` now stores only standard cache writes; 1-hour cache writes use `cache_write_1h_input_tokens` and `cache_write_1h_input_cost`.
- Dashboard model and data-quality pages now use canonical `TokenUsage` totals.
- OpenAI, Anthropic, and RubyLLM capture now populate `pricing_mode` from provider tier data.
- Pricing now handles Anthropic 1-hour cache-write TTLs, Gemini context-cache reads, stackable batch cache rates, and long-context tiers.
- Missing positive-token pricing-mode rates now return unknown pricing instead of falling back to standard prices.

## [0.7.0] - 2026-04-29

### Changed

- BREAKING: ActiveRecord is now the only storage path; removed `storage_backend`, `custom_storage`, `Storage.register`, `:log`, and `:custom`.
- BREAKING: PostgreSQL and MySQL are now the only supported database adapters; SQLite support was removed.
- Runtime dependencies now include Rails and ActiveRecord.

## [0.6.1] - 2026-04-29

### Fixed

- Exclude repository documentation from the published gem package.

## [0.6.0] - 2026-04-29

### Added

- Durable ActiveRecord ingestion through `llm_cost_tracker_inbox_events` and `llm_cost_tracker_ingestor_leases`.
- `llm_cost_tracker:add_ingestion` generator for upgrading existing ActiveRecord installs.
- `LlmCostTracker.flush!` and `LlmCostTracker.shutdown!` for draining or stopping durable ingestion.
- Doctor diagnostics for missing durable ingestion schema, stale pending inbox rows, and quarantined inbox rows.
- PostgreSQL and MySQL smoke checks for ActiveRecord durable ingestion.

### Changed

- Fresh ActiveRecord installs now include durable ingestion tables, event IDs, and production indexes.
- ActiveRecord budget totals now read stored period rollups plus pending inbox totals while durable ingestion is enabled.
- ActiveRecord writes now use a durable inbox before batching ledger inserts and period rollup updates when ingestion tables are present.
- Pricing lookup now caches normalized runtime price tables and model matches by configuration generation.
- Stream capture now estimates buffered event size without serializing every captured event.
- CSV export now selects only exported columns instead of loading full ActiveRecord objects.

### Fixed

- ActiveRecord rollups no longer double-count retried events when duplicate event IDs race across workers.
- Invalid inbox rows are retried and quarantined without blocking healthy rows behind them.
- Idle ingestors no longer acquire the leader lease while the inbox is empty.
- ActiveRecord inbox writes now fail honestly when a separate connection is unavailable inside a caller transaction.
- Ingestor shutdown/reset no longer lets an old sleeping thread resume as a second local ingestor.
- `flush!` now returns `false` instead of raising when its timeout expires during ingestion.
- ActiveRecord adapter family detection now works through known adapter class ancestry with an adapter-name fallback.
- CSV export now emits `{}` for invalid stored tag payloads.

## [0.5.3] - 2026-04-28

### Added

- Official OpenAI SDK streaming capture for Responses streams, Responses raw streams, Responses retrieve streams, and Chat Completions raw streams.
- Official Anthropic SDK streaming capture for Messages streams and raw streams.
- Capture verification via `llm_cost_tracker:verify_capture` and expanded doctor capture diagnostics.
- Pricing explanation via `LlmCostTracker::Pricing.explain` and `llm_cost_tracker:prices:explain`.
- Extensible storage and SDK integration registries via `Storage.register` and `Integrations.register`.

### Fixed

- OpenAI Responses stream parsing now reads final usage from completed response events.
- Incomplete price entries now return unknown pricing instead of raising `TypeError`.
- Retention pruning now keeps ActiveRecord period rollups in sync when deleting rows inside active budget windows.

## [0.5.2] - 2026-04-27

### Added

- RubyLLM SDK integration for chat, embedding, and transcription calls.
- Tag guardrails for redacted tag keys, maximum tag count, and maximum tag value byte size.

### Changed

- SDK integrations now validate minimum versions and method contracts before installing wrappers.
- `config.instrument :all` now includes RubyLLM.
- Dashboard date filters now reject one-sided, reversed, and over-366-day ranges.
- Dashboard provider/model/tag option lists and tag value breakdowns now cap rendered rows.
- Reports now cap rendered breakdown groups while keeping complete structured report data available.
- Stream capture now enforces a shared 1 MiB buffer cap and records unknown usage on overflow.
- Price refresh, price scrape, and local price registry reads now enforce response or file size caps.
- Retention pruning now rejects non-positive batch sizes and invalid cutoffs before deleting rows.
- The install generator now warns to mount the dashboard behind host-app admin authentication.

### Fixed

- OpenAI SDK integration now separates cached input tokens from regular input tokens.
- OpenAI and Gemini parsers now compute total tokens when provider responses omit totals.
- CSV export now prefixes formula-like values even when they have leading whitespace.
- Tag chips now truncate oversized values and tooltips.
- Report tag breakdown keys are validated at configuration time.

## [0.5.1] - 2026-04-27

### Changed

- Renamed `llm_cost_tracker:prices:sync` to `llm_cost_tracker:prices:refresh` and `LlmCostTracker::PriceSync.sync` to `.refresh`.
- Price refresh now reads the maintained LLM Cost Tracker snapshot, supports `URL` overrides, and writes to `OUTPUT`, `config.prices_file`, or `config/llm_cost_tracker_prices.yml`.
- Price refresh validates snapshot schema and minimum gem version before replacing the local registry.
- Built-in price keys are provider-qualified while older unqualified local price keys continue to load.
- Built-in prices now include OpenAI cached-input rates, OpenAI batch rates, Anthropic/Gemini batch rates, additional OpenAI models, and refreshed provider rates.
- Price refresh writes registry files atomically.

## [0.5.0] - 2026-04-25

### Added

- Optional SDK integrations: `config.instrument :openai`, `:anthropic`, or `:all` patches the official `openai` and `anthropic` gems' resource methods to record usage automatically. Provider SDKs are not added as hard dependencies.
- `LlmCostTracker.with_tags` plus `TagContext` for thread- and fiber-isolated request-scoped tags that flow through middleware, SDK integrations, and `track` / `track_stream`.
- `LlmCostTracker::Doctor` and the `llm_cost_tracker:doctor` rake task for diagnosing storage, schema, optional columns, period totals, integrations, prices, and recent calls.
- `LlmCostTracker::PriceFreshness` helper plus a price-freshness doctor check that warns when bundled or local prices are stale.
- Technical documentation under `docs/technical/` covering architecture, data flow, extension points, module map, and operational notes.

### Changed

- Pricing fuzzy matching now only accepts dated snapshot suffixes instead of guessing new model families.
- Built-in prices include GPT-5.5 and GPT-5.4 variants and drop retired Claude and Gemini entries.
- Missing model identifiers now normalize to `unknown` instead of leaking nil into tracked events.
- `llm_cost_tracker:prices` now generates a full local price snapshot instead of an empty override file.
- Price sync workflow surfaces clearer error context for fetcher failures and skips refresh-plan entries with malformed pricing.
- README, cookbook, and technical docs clarify that `config.instrument` patches official SDKs only; `ruby-openai` (alexrudall) routes through the Faraday middleware via its constructor block, and `ruby_llm` is not auto-captured today because the gem does not expose a Faraday middleware hook.

## [0.4.1] - 2026-04-24

### Changed

- Batched ActiveRecord period rollup writes and budget total reads.
- Memoized schema capability checks and refreshed them on `reset_column_information`.
- Install migration adds `[:model, :tracked_at]` composite index and drops redundant single-column `:provider` / `:model` indexes.
- Data Quality now reads counters and usage sums through one aggregate query.
- Parser URL matching, stream-event extraction, and custom parser registration now share a smaller base/registry extension surface.
- Added cookbook recipes for `ruby-openai`, `anthropic-sdk-ruby`, `gemini-ai`, `langchainrb`, Azure OpenAI, and LiteLLM proxy setups.

### Fixed

- `llm_cost_tracker:add_period_totals` now imports legacy monthly rollups and backfills before adding the unique index.
- Budget docs now describe `:notify` across monthly, daily, and per-call budgets.

## [0.4.0] - 2026-04-24

### Changed

- BREAKING: Canonical usage and pricing now use `cache_read_input` / `cache_write_input` instead of `cached_input` / `cache_creation_input`.
- BREAKING: `Pricing.cost_for` now requires `provider:` and prefers provider-specific price entries before model-only entries.
- BREAKING: Fresh ActiveRecord installs include cache-read, cache-write, and hidden-output token/cost breakdown columns.
- BREAKING: ActiveRecord budget rollups now use `llm_cost_tracker_period_totals`.
- BREAKING: `llm_cost_tracker:add_monthly_totals` was replaced by `llm_cost_tracker:add_period_totals`.
- `llm_cost_tracker:add_usage_breakdown` generator for upgrading existing ActiveRecord installs.
- `llm_cost_tracker:add_period_totals` generator for upgrading existing ActiveRecord installs.
- Generic `pricing_mode` support with mode-prefixed local price keys.
- Data Quality now shows usage bucket totals and hidden-output share.
- Daily budget and per-call budget guardrails.

## [0.3.3] - 2026-04-24

### Added

- Monthly rollup totals for ActiveRecord budget checks, plus `llm_cost_tracker:add_monthly_totals` for upgrading existing installs.

### Changed

- ActiveRecord monthly totals now update through a single atomic upsert.
- Faraday stream capture overflow now records `usage_source: "unknown"` instead of dropping the tracked event.
- Budget `:notify` callbacks now fire only on the first event that crosses the monthly limit.

### Fixed

- Treat `config.enabled = false` as a global kill switch for direct `track` and `track_stream` calls too.
- Deduplicate unknown-pricing warnings per model.
- Detect streaming requests from parsed JSON instead of raw body substring matching.
- Cap automatic SSE capture to avoid unbounded memory growth on large streaming responses.
- Warn that the generated PostgreSQL `tags -> jsonb` upgrade migration rewrites large tables and should run in a maintenance window.

## [0.3.2] - 2026-04-22

### Added

- Test coverage reporting via SimpleCov with LCOV upload to Codecov from CI.
- Repository governance files: `CODE_OF_CONDUCT.md`, `SECURITY.md`, `CONTRIBUTING.md`, and GitHub issue templates.

## [0.3.1] - 2026-04-22

### Added

- `provider_response_id` persistence, parser extraction, and Data Quality coverage for provider-issued response object IDs.

### Changed

- Simplified dashboard helpers, filter normalization, and view templates without changing dashboard behavior.
- Split `PriceSync` internals into smaller components and removed redundant internal wrapper layers.

### Fixed

- Removed inline dashboard JavaScript to keep the engine server-rendered.
- Reset ActiveRecord model column information in storage specs to avoid stale schema state across recreated tables.

## [0.3.0] - 2026-04-22

### Added

- Streaming capture across OpenAI, Anthropic, and Gemini, including `LlmCostTracker.track_stream` for non-Faraday clients.
- `stream` / `usage_source` persistence and dashboard coverage for streamed calls.
- `llm_cost_tracker:prices:sync` and `llm_cost_tracker:prices:check` for keeping local price snapshots current.
- `LlmCostTracker.enforce_budget!` and opt-in `enforce_budget:` keyword for `track` / `track_stream`.

### Changed

- Price refresh now uses structured JSON sources (LiteLLM primary, OpenRouter secondary) instead of scraping provider HTML pages.
- Synced price entries now carry source provenance (`_source`, `_source_version`, `_fetched_at`), while `_source: "manual"` entries remain untouched.
- Manual stream parsing now resolves parsers through the shared registry, so configured OpenAI-compatible providers work the same way as built-in ones.
- `LlmCostTracker.configure` now treats configuration as an immutable snapshot after the block returns; mutating or replacing shared fields through `LlmCostTracker.configuration` raises `FrozenError`.

### Removed

- Public `LlmCostTracker.configuration=` writer; use `LlmCostTracker.configure` to replace configuration snapshots.

## [0.2.0] - 2026-04-20

### Added

- `LlmCostTracker::Retention.prune(older_than:)` and `llm_cost_tracker:prune` rake task.
- Overview: budget projection, previous-period daily spend comparison, spend anomaly alerts.
- Call details: token and cost mix breakdowns.
- Dashboard CSS served as a fingerprinted, immutably-cached file via `LlmCostTracker::AssetsController`.
- Filter dropdowns for Provider and Model, scoped to the current slice.
- Pagination with per-page selector and Stripe-style page window.

### Changed

- Dashboard UI aligned to Tailwind UI Application UI: dot-indicator badges, value-first stat tiles, inset-shadow form inputs, white secondary buttons with `shadow-sm`.
- CSS fully namespaced under `lct-*`; removed bare `body` selector to avoid host-app leakage.

### Fixed

- Thread-safe price memoization (regression from 0.1.3).
- `by_tag` on MySQL JSON columns.
- CSV export escapes formula-prefixed values.
- Portable dashboard sorting across adapters.
- Dashboard shows database errors instead of install/setup guidance when the DB is unavailable.
- Tag key explorer uses SQL discovery on MySQL 8.0+.

## [0.2.0.alpha1, 0.2.0.alpha2] - 2026-04-20

### Breaking

- Require Ruby 3.3+ (was 3.1), Rails/ActiveRecord 7.1+ (was 7.0), Faraday 2.0+ (was 1.0).
- `Event`, `Cost`, and `ParsedUsage` are plain `Data.define` value objects; use method access (`event.cost.total_cost`) instead of Hash lookups. `ActiveSupport::Notifications` payloads are unchanged.
- Rename `LlmCostTracker::InvalidFilter` → `InvalidFilterError`.
- Drop `LlmApiCall.by_provider` / `by_model` scopes — use `where(provider:)` / `where(model:)`.
- `ReportData` no longer hardcodes a `"feature"` tag breakdown. Configure `config.report_tag_breakdowns = %w[feature env]` (or pass `tag_breakdowns:` to `ReportData.build` / `Report.generate`). Default is empty.

### Added

- `LlmApiCall.group_by_period(:day/:month)` — SQL-side period grouping.
- Opt-in `LlmCostTracker::Engine` dashboard (Rails 7.1+): overview with delta-vs-previous-period, provider rollup, models, filterable call list with CSV export and outlier sort modes, call details, tag key explorer, per-key tag breakdown, data quality. PostgreSQL/SQLite use adapter-specific SQL; MySQL 8.0+ uses JSON_TABLE-based tag discovery. Core middleware still works without Rails.

## [0.1.4] - 2026-04-18

### Breaking

- Drop `LlmApiCall.by_user` / `by_feature` scopes and `LlmApiCall#user_id` / `#feature` accessors. Use `by_tag("user_id", id)` / `by_tag("feature", name)` or `by_tags(...)`; read stored tags via `parsed_tags[...]`.
- Drop `ReportData#cost_by_feature` — use `cost_by_tags.fetch("feature")` or `LlmApiCall.cost_by_tag("feature")`.

### Added

- `group_by_tag(key)` / `cost_by_tag(key)` SQL aggregations across any tag key.
- Generic tag breakdowns in reports.

## [0.1.3] - 2026-04-18

### Fixed / Changed

- Mutex-guard `PriceRegistry.file_prices` and `Pricing.sorted_price_keys` memoization.
- Warn on unknown keys in local prices files.
- Document that budget guardrails skip events with unknown pricing.

### Added

- `llm_cost_tracker:prices` generator for a local price override template.
- Callable Faraday `tags:` for per-request Rails attribution via `Current`.
- `llm_cost_tracker:report` rake task.

### Internal

- Extract `Logging`, `TagQuery`, `TagsColumn`, `TagAccessors` helpers; `Cost`, `Event`, `ParsedUsage` value objects; storage backend objects; split `Report` into data + formatter; `OpenaiUsage` composition for OpenAI-compatible providers; move enum validation into `Configuration`; memoize merged prices table; restrict Gemini parser to `generateContent` / `streamGenerateContent`.

## [0.1.2] - 2026-04-18

### Added

- Auto-detect OpenRouter and DeepSeek as OpenAI-compatible.
- `openai_compatible_providers` config for private gateways.
- `BudgetExceededError` + `budget_exceeded_behavior` (`:notify`, `:raise`, `:block_requests`). `:block_requests` is best-effort under concurrency.
- `StorageError` + `storage_error_behavior`; `UnknownPricingError` + `unknown_pricing_behavior`.
- Built-in `prices.json` registry with metadata and source URLs; `prices_file` for local JSON/YAML overrides.
- `with_cost`, `without_cost`, `unknown_pricing` scopes.
- `latency_ms` tracking end-to-end; `with_latency`, `average_latency_ms`, `latency_by_model`, `latency_by_provider`.
- `jsonb` tags + GIN index on PostgreSQL in new migrations; adapter-aware `by_tag` (JSONB containment on PG, text fallback elsewhere); `by_tags` / `by_user` / `by_feature`.
- Generators: `upgrade_tags_to_jsonb`, `upgrade_cost_precision`, `add_latency_ms`.

### Changed

- Tags stored as Hash for JSON-backed columns, JSON text for fallback.
- Normalize provider-prefixed model IDs (e.g. `openai/gpt-4o-mini`) for price lookup.
- Widen generated cost columns to `precision: 20, scale: 8`.
- Count Gemini `thoughtsTokenCount` as output tokens.
- Warn on unreadable streaming/SSE response bodies.
- Route storage exceptions inheriting from `LlmCostTracker::Error` through `storage_error_behavior`.

## [0.1.1] - 2026-04-17

### Fixed

- Lazy-load ActiveRecord storage so `:active_record` persists events reliably.
- Stop double-counting the latest event in monthly budget callbacks.
- Track OpenAI Responses API (`/v1/responses`).
- Parse cached/cache-read/cache-creation token details across OpenAI, Anthropic, Gemini.
- Store tag values as strings so `by_tag("user_id", "42")` matches numeric IDs.

### Changed

- Refresh built-in pricing for current OpenAI, Anthropic, Gemini models.
- Cache-aware cost fields (cached input, cache reads, cache creation).
- Tighten OpenAI URL matching to supported endpoint families.

### Added

- ActiveRecord integration specs; RuboCop config + CI lint step; RubyGems MFA metadata.

## [0.1.0] - 2026-04-16

- Faraday middleware for LLM call interception.
- Parsers: OpenAI, Anthropic, Gemini. Built-in pricing for 20+ models with fuzzy matching.
- `ActiveSupport::Notifications` integration; ActiveRecord backend with scopes and aggregations.
- Manual `LlmCostTracker.track(...)` for non-Faraday clients.
- Per-user / per-feature tagging; monthly budget alerts with configurable callbacks.
- `rails generate llm_cost_tracker:install`; custom storage backend; pricing overrides.
