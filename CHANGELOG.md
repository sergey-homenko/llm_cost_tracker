# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

0.9 adds per-provider rollups, opt-in provider invoice reconciliation, and
proactive `stream_options.include_usage` injection for OpenAI and
OpenAI-compatible streaming. Existing installs need a migration — see
[Upgrading](docs/upgrading.md).

### Added

- **Experimental:** opt-in provider invoice reconciliation. Two opt-ins required (`config.reconciliation_enabled = true` plus `bin/rails generate llm_cost_tracker:reconciliation`). Public surface: `LlmCostTracker::Reconciliation.import / .diff / .enabled?`, `config.register_reconciliation_importer(:source) { … }`, rake tasks `llm_cost_tracker:reconcile:import` and `:reconcile:diff`, new optional table `llm_cost_tracker_provider_invoice_imports`. See [Configuration](docs/configuration.md#reconciliation-experimental-opt-in).
- `Doctor::InvoiceReconciliationCheck` warns when reconciliation drift exceeds 5% or imports go stale past 14 days.
- Dashboard Data Quality page shows a "Streaming health by provider" breakdown (streams, with-usage, unknown, unknown share) so a misconfigured OpenAI-compatible host shipping streams without `stream_options.include_usage` is visible at a glance.
- Dashboard tag detail page drills into a single value via `?value=…` with total cost, call count, average per call, and a daily spend timeseries; the breakdown table exposes a "Trend" link per row.
- Anthropic `web_fetch_request` server tool is recorded as a billable line item in both Faraday and SDK paths, with a matching bundled rate.
- `bin/rails generate llm_cost_tracker:upgrade_call_rollups_provider` writes the v0.8 → v0.9 migration that adds the `provider` column and swaps the unique index. Each step is gated by `column_exists?` / `index_exists?` so the migration is a no-op on already-upgraded schemas.
- Bundled rates for OpenAI embeddings (`text-embedding-3-small` / `-3-large` / `-ada-002`, including 50% batch discount) and token-priced transcription models (`gpt-4o-transcribe`, `gpt-4o-mini-transcribe`). Per-image (DALL-E), per-minute (Whisper), and per-character (TTS) endpoints still record as zero-token visibility events — they need new pricing components and are tracked separately.
- OpenAI `Audio::Transcriptions#create` extracts `usage.input_token_details.audio_tokens` into `audio_input_tokens`, so token-priced transcription models price audio and text inputs at their separate bundled rates.
- `config.durable_ingestion = false` (new default) writes events synchronously from the request thread; the durable inbox + worker + leases are now opt-in via `config.durable_ingestion = true` plus `bin/rails generate llm_cost_tracker:durable_ingestion`. Default installs ship with two fewer tables (`llm_cost_tracker_ingestion_inbox_entries`, `llm_cost_tracker_ingestion_leases`).
- `config.cache_rollups = false` (new default) drops the rollup write path. Budget reads aggregate live from `llm_cost_tracker_calls` instead. Apps that want the indexed rollup fast path opt in via `config.cache_rollups = true` plus `bin/rails generate llm_cost_tracker:call_rollups`. Default installs ship with one fewer table (`llm_cost_tracker_call_rollups`).

### Fixed

- Tracker writes to the durable inbox before firing `ActiveSupport::Notifications.instrument`. A raising subscriber no longer crashes the call before the event is persisted; subscriber failures are caught and logged.
- Header `total_cost` no longer mixes currencies. Service line items in a currency that doesn't match the header pricing snapshot are excluded from the header total (with a warning logged); per-line costs keep their original currency.
- Budget reads sum across all rollup currencies instead of being silently scoped to USD-only rows, so non-USD pricing snapshots reach guardrail checks.
- `bin/rails llm_cost_tracker:setup` no longer fails with `Missing Thor class for invoke llm_cost_tracker:prices`. The task is now idempotent on re-runs and surfaces a friendly error when the database is unreachable.
- Stream events are no longer lost when `Tracker.record` raises during stream finalization. The collector clears the recording slot in an `ensure` block so retries (including those triggered by `Thread#kill` / `Timeout::Error` / signal-driven raises) persist on the next `finish!`. `StreamTracker` mirrors the same retry semantics.
- Streams that are wrapped but never iterated to completion now emit a usage event via an `ObjectSpace` finalizer instead of disappearing silently.
- Faraday-side stream overflow now keeps the buffer accumulated up to the limit (matching `StreamCollector` behaviour) rather than dropping all events on overflow.
- Edits to `config.prices_file` are picked up without a gem reload — the lookup cache invalidates on file mtime changes. The lookup cache is now bounded to prevent unbounded growth from user-supplied model strings.
- `Pricing::Sync.refresh` preserves models flagged with `_source: "manual"` in the local file, so locally curated rates survive subsequent remote refreshes.
- `Pricing.normalize_mode` treats Symbol input the same as String input. `:"standard-only"` no longer slips past `STANDARD_MODE_VALUES` and forces a known model into unknown pricing.
- Anthropic SDK integration only marks a call as `data_residency` when `inference_geo == "eu"` (the documented +10% surcharge tier), removing a false positive on unrelated US-region inference.
- Anthropic Priority Tier no longer falls to `cost_status: unknown`. Anthropic's Priority Tier is committed throughput, not a per-token surcharge — both the SDK integration and the Faraday parser now treat `service_tier: "priority"` as standard pricing for token cost.
- `web_fetch_request` is recorded with a `$0` bundled rate (Anthropic explicitly bills web fetch via standard tokens, not per fetch). The Anthropic scraper detects the "Web fetch usage has no additional charges" sentence and emits `0.0` so the rate stays accurate across `prices:refresh` runs.
- `Pricing::Scrape::Orchestrator` merges scraped service-charge rates into the existing catalog instead of replacing the provider hash. Manually-curated entries (e.g. an internal-gateway tool charge that no public page documents) survive `prices:refresh` runs.
- Anthropic `data_residency` mode triggers on both `inference_geo: "us"` and `"eu"` (Anthropic offers data residency in either region; the +10% uplift applies in both).
- Faraday middleware now requires `stringio` so the streaming buffer tap installs cleanly. Without the require, the tap raised `NameError: uninitialized constant StringIO` and silently degraded streaming captures to `usage_source: :unknown`.
- Railtie registers the new `llm_cost_tracker:call_rollups`, `llm_cost_tracker:durable_ingestion`, `llm_cost_tracker:reconciliation`, and `llm_cost_tracker:upgrade_call_rollups_provider` generators so host apps can invoke them through `bin/rails generate`.
- Engine `ApplicationController#ensure_current_schema` only enforces the `llm_cost_tracker_call_rollups` schema when `config.cache_rollups = true`. Default installs no longer get blocked by the missing optional table.
- `Reconciliation::Importer#perform_import` only passes `unique_by:` to `upsert_all` when the connection adapter supports `INSERT ... ON CONFLICT` targets (mirrors the core rollup writer). MySQL/Trilogy installs no longer crash on import.
- `Reconciliation::Diff` gates the rollup fast path on `config.cache_rollups` and `CallRollup.table_exists?` so reconciliation no longer assumes an opt-in table is present.
- `Capture::StreamCollector` no longer lets a request-level `pricing_mode` override a provider-reported standard tier. When the captured event came from real provider usage (`stream_final`, `sdk_response`, `sdk_stream`, `response`, `manual`), the captured mode wins even when it's nil (provider explicitly said standard).
- Reconciliation diff windows are anchored in UTC. App servers in non-UTC timezones (e.g. Europe/Kiev) no longer skew the window by their local offset.
- Reconciliation provider totals sum only invoices fully contained in the diff window. Partially overlapping invoices (e.g. a full-month bill on a half-month window) are no longer counted at their full `billed_amount`.
- Reconciliation import errors are no longer echoed verbatim into the dashboard flash. The full exception is logged; the alert shows the exception class only.
- Dashboard filters apply the default 30-day range when `from`/`to` params are missing; backend behavior now matches the form's visual default.
- `provider_api_key_id` and `provider_workspace_id` are masked on the call detail page and CSV export, matching the existing reconciliation drill-down.
- Pricing modes captured from in-stream events win over the request-level mode when recording, so message-level `service_tier` / `inference_geo` from Anthropic SDK streams reach the ledger.
- Doctor catches schema drift on `created_at` (line items), `created_at` + `updated_at` (rollups), and the ingestion inbox / lease tables before the first row is inserted. Schema checks for `call_line_items` and `call_tags` now also verify required indexes and the `ON DELETE CASCADE` foreign key.
- Service-charge rows render `n/a` instead of `$0.00` when `cost_status` is `unknown`, so unpriced charges don't masquerade as zero-cost.
- OpenAI SDK integration now also patches `Embeddings#create`, `Images#generate` / `#edit` / `#create_variation`, `Audio::Transcriptions#create`, `Audio::Speech#create`, `Moderations#create`, and `Chat::Completions#stream`. Token-bearing calls record real usage; calls without a `usage` field record zero-token visibility events.
- RubyLLM SDK integration also records `Provider#paint` and `Provider#moderate`. Image events read tokens from `Image#usage` when present and stay zero-token otherwise (cost stays `unknown` until image pricing lands). Moderation calls are recorded as zero-token visibility events.
- Enabling `:ruby_llm` together with `:openai` / `:anthropic` logs a warning at install — RubyLLM routes through HTTP, so calls to those providers would otherwise be double-counted (once via SDK patch, once via Faraday parser). Pick one path per provider.

### Changed

- BREAKING: `bin/rails generate llm_cost_tracker:install --dashboard` no longer writes the `mount LlmCostTracker::Engine` line into `config/routes.rb`. The CLI prints the snippet wrapped in your auth instead — leaving the dashboard auto-mounted without auth would expose spend, tags, and provider IDs to anyone who can reach the host. Add the route under your authentication block.
- BREAKING: `config.durable_ingestion` defaults to `false`. Tracking writes go directly to the ledger from the request thread; the durable inbox + worker + leases tables are no longer created by the install generator. Existing installs that want to keep the durable inbox path must set `config.durable_ingestion = true` in the initializer (their existing `llm_cost_tracker_ingestion_*` tables remain compatible). Fresh installs that need durability run `bin/rails generate llm_cost_tracker:durable_ingestion` and flip the flag.
- BREAKING: `config.cache_rollups` defaults to `false`. Budget reads aggregate live from `llm_cost_tracker_calls`; the rollup table is no longer created by the install generator. Existing installs that want fast budget reads on large ledgers must set `config.cache_rollups = true` in the initializer (their existing `llm_cost_tracker_call_rollups` table remains compatible). Fresh installs run `bin/rails generate llm_cost_tracker:call_rollups` and flip the flag.
- BREAKING: `llm_cost_tracker_call_rollups` gains a `provider` column; unique index moves from `(period, period_start, currency)` to `(period, period_start, currency, provider)`. See [Upgrading](docs/upgrading.md).
- Faraday middleware auto-injects `stream_options: { include_usage: true }` on OpenAI and OpenAI-compatible chat-completions streaming requests when the caller hasn't set it. Explicit values are preserved. Disable with `config.auto_enable_stream_usage = false`.
- OpenAI-compatible chat-completions streams without a final usage chunk log a warning instead of recording silently as `usage_source: "unknown"`.
- `Tags::Sanitizer` redacts tag values matching known secret patterns (OpenAI / Anthropic, GitHub, AWS access key id, JWT, Slack, Stripe, Google API key, `Bearer …`) regardless of the tag key. Patterns now recurse into nested Hash and Array leaves; on tag-count overflow the most recently added tags win (innermost `with_tags` block) instead of being dropped first. `Tags::Context` also sanitises secrets at block entry so raw values never reach `ActiveSupport::Notifications` subscribers, the Faraday request env, or the in-flight stream collector.
- Engine dashboard adds CSRF protection on the reconciliation import endpoint, sets `Cache-Control: no-store` on CSV exports, registers `tag` / `tag_value` in `config.filter_parameters` so URL-supplied tag values stop landing in Rails request logs, and emits `X-Frame-Options: DENY` / `Referrer-Policy: same-origin` / a baseline `Content-Security-Policy` header on every dashboard response. The CSV export now streams via `find_each` instead of buffering the full result set in memory.

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
