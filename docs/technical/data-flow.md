# Data Flow

Normal path from an application LLM call to stored ledger data:

## Faraday Requests

1. Your app sends an HTTP request through Faraday.
2. `LlmCostTracker::Middleware::Faraday` checks whether a parser matches the request URL.
3. For non-streaming responses, the middleware passes request and response data to the parser.
4. For streaming responses, the middleware tees `on_data`, collects stream events, and parses final usage when the stream completes.
5. Tags are snapshotted before the request enters the adapter.
6. The parser returns `Event` with canonical `Usage::TokenUsage`, `pricing_mode`, and any service `Charges::LineItem`s the provider exposed.
7. `Tracker.record` prices and persists the event.

## SDK Integrations

1. Your app enables an integration with `config.instrument`.
2. `LlmCostTracker::Integrations` checks the SDK version, target classes, and target methods once at install time.
3. `LlmCostTracker::Integrations` prepends a narrow wrapper to supported SDK resource methods.
4. Your app keeps calling the provider SDK normally.
5. For streaming calls on the `openai` and `anthropic` gems, the wrapper passes the SDK stream through `Capture::StreamTracker` so the app still consumes the same stream object; on RubyLLM 1.x a streaming `complete` is recorded from the final response it returns.
6. Streaming wrappers snapshot tags before returning the stream to the app.
7. The wrapper measures latency, extracts usage and provider tier data from the SDK response object or collected stream events, and sends `Event` to `Tracker.record`.
8. If an explicitly enabled SDK is not loaded or does not satisfy the install contract, boot raises before the app silently misses usage.

On RubyLLM 2.x the integration subscribes to RubyLLM's `ActiveSupport::Notifications` events instead. An operation event such as `chat.ruby_llm` opens a fiber-local frame when it starts, each `usage.ruby_llm` provider attempt joins the innermost open frame, and when the operation finishes each attempt becomes its own `Event`. Attempts of operations the integration has no event for are recorded at once; other attempts outside any frame are skipped. `RubyLLM::Batch#messages` and `#results` open a frame of their own, which drops the attempts RubyLLM reports as it delivers the results, and when they return, each result becomes an `Event` at batch rates, parsed from its result body like a blocking attempt, or from RubyLLM's token counts for an embedding, and stored once under its response id, or else its batch id and position; a result object the process already recorded is skipped before parsing. Read-only wrappers on protocol methods (`build_chunk`, `stream_transcription` and the `parse_*` methods RubyLLM documents for custom providers, and `transcribe`) hand the frame the protocol's provider, whose `api_base` stands in for the request host when no response was read, mark a transcription given a block as streamed, and hand the attempt's stream events, last transcription event or raw response to the frame for the provider parsers, or, for Bedrock Converse, the integration's own usage reader (a one-shot operation that fails after its raw response was read prices that response on its last attempt), and record a Gemini context cache when `RubyLLM.cache` creates one; an attempt without them is priced from RubyLLM's token counts.

## Explicit Tracking

1. Your app calls `LlmCostTracker.track` with known usage totals, or `LlmCostTracker.track_stream` with stream events.
2. `track` accepts explicit `tokens:` and `tags:`, builds `Event`, and sends it to `Tracker.record`.
3. `track_stream` snapshots tags when the stream collector is created.
4. `track_stream` uses `Capture::StreamCollector`, then every parser registered for the provider name (`Parsers.all_for_provider`) when events need parsing, keeping the first result with known usage.
5. `Tracker.record` prices and persists the event.

## Canonical Event Build

`Event.build` normalizes the raw capture — a blank model identifier becomes `unknown`, and usage source, stream flag and response identity are settled there. `Tracker.record` then normalizes tags and latency and drives the rest:

1. `Event` carries provider identity, model identity, stream metadata, response identity, provider grouping dimensions, `pricing_mode`, and `Usage::TokenUsage`.
3. `Pricing::Calculation` (built via `Pricing::Calculation.for`) prices token counters with the normalized `pricing_mode`, plus `off_peak` when the matched entry's `_off_peak_windows` cover the call's time, applies the same rates to token line items, and prices each service line item from a rate on the matched model's registry entry (such as `transcription_minute`) or else `Pricing::ServiceRates.charge_rate`, when the registry has a reliable rate for the captured quantity basis, and each `model_iteration` line item at the token rates of the model in its `details`. When a `billed_request` line item (OpenRouter's `usage.cost`, xAI's `usage.cost_in_usd_ticks`, or Perplexity's `usage.cost.total_cost`) is present, token rates are not applied and its amount and status become the call's. It exposes the header cost (or `nil` for unknown pricing), the rate snapshot, and the priced line items.
4. `Charges::CostStatus` combines token pricing and service line pricing into `free`, `complete`, `partial`, or `unknown`.
5. Tags are merged from the current or captured tag context, middleware tags, and explicit tags.
5. Persistence runs through `Ledger::Store.insert` (default) or `Ingestion::Inbox` when `config.ingestion.mode = :async`.
6. The persisted event is emitted through `ActiveSupport::Notifications`. Under `pricing.unknown_model_behavior = :raise`, an unpriced event, or one with an unpriced `model_iteration` model, raises `LlmCostTracker::UnknownPricingError` once the budget checks below have run, unless one of them raised first.
7. Budget checks run next. `enforce_budget: true` on `LlmCostTracker.track` makes them raise even when the configured behavior is `:notify`; the call is already recorded and the error carries `stage: :post_spend`. `LlmCostTracker.track_stream` instead checks before your block runs and raises `stage: :pre_send`.

## Ledger Storage

When `config.ingestion.mode = :inline` (default):

1. `Ledger::Store.insert` writes the call header, line items, and tag rows in a single transaction on the caller's ActiveRecord connection. Inside an open caller transaction the write runs in a savepoint: a failed ledger write rolls back only its own rows, while a caller-side `ActiveRecord::Rollback` still discards the tracked event with the rest of the work. Switch to `config.ingestion.mode = :async` if you need ledger writes to survive caller rollbacks. Budget reads and batch de-duplication use the same savepoint guard (`Ledger::Isolation`).
2. When `config.budgets.totals_source = :cache`, rollup rows are incremented after the ledger write; inside a joinable caller transaction, only once it commits, so an open transaction never holds the rollup row lock and a rollback skips the increment. Inside non-joinable transactions such as transactional test fixtures, the increment runs immediately in a savepoint. Increments retry on deadlock or lock timeout only outside a transaction; inside one, a failure is logged without failing the ledger write. Otherwise rollups are skipped entirely.
3. On MySQL a deadlock rolls back the caller's whole transaction, which a savepoint cannot prevent, so inside a caller transaction the gem raises `LlmCostTracker::TransactionAbortedError` instead of letting the caller carry on outside the transaction it thinks is open.
4. Each call tracked inside a caller transaction uses one savepoint, a PostgreSQL subtransaction; more than 64 in one transaction overflow PostgreSQL's per-backend subtransaction cache and slow the database, so capture large batch results outside a transaction.
5. Budget reads aggregate live from `llm_cost_tracker_calls`. Under `config.budgets.totals_source = :cache` a monthly read sums only today's calls and adds the daily rollup rows of the month's earlier days.

When `config.ingestion.mode = :async`:

1. `Ingestion::Inbox.save` writes a compact inbox event row.
2. `Ingestion::Worker` claims retryable inbox entries through a database lease and drains batches into `llm_cost_tracker_calls`.
3. `Ingestion::Batch` writes the call headers, line items and tag rows and deletes the drained inbox rows in one transaction, then increments rollups and scores per-tag budgets outside it.
4. Budget reads add pending inbox totals on top of the calls aggregate.

The persistence write (inbox row in async mode, ledger rows in inline mode) is the durability boundary. In async mode, ledger freshness is eventually consistent unless the caller explicitly waits with `LlmCostTracker::Ingestion::Worker.flush!`.

## Dashboard Reads

1. Controllers build a filtered `LlmCostTracker::Call` scope.
2. Dashboard services run targeted aggregate queries.
3. Helpers render filters, charts, pagination, CSV links, and numeric formatting.
4. Views render plain ERB with the engine CSS asset.

Dashboard reads do not mutate ledger state. They can be heavier than request-time code, but they still need explicit grouping and indexes.

## Pricing Refresh

1. `llm_cost_tracker:prices:refresh` chooses `ENV["OUTPUT"]`, then `config.pricing.file`, then `config/llm_cost_tracker_prices.yml`.
2. `Pricing::Sync::Fetcher` fetches the maintained LLM Cost Tracker price snapshot.
3. `Pricing::Sync` validates schema compatibility, gem-version compatibility, model price shape, and tool/runtime charge sections. The price bot holds back entries an older gem would misprice until the snapshot's `metadata.min_gem_version` covers the gem that prices them.
4. `Pricing::Sync::SnapshotGuard` compares the snapshot with the local file; zeroed prices, removed `input`/`output` rates, 100-fold moves, or a currency switch stop the write unless the refresh is forced.
5. `RegistryWriter` writes a local JSON or YAML registry.
6. Runtime pricing loads the local file once and memoizes it. The file's mtime is recorded as the source version; changing the file in a running process has no effect until the process restarts or Rails reloads the app.

The gem never fetches pricing from the network during normal request tracking.

The daily price bot (`scripts/price_scrape/runner.rb`) fetches each source page once per run, LiteLLM at one pinned commit, adds LiteLLM-only Mistral rows only when models.dev lists their price within 1%, records keys a provider stopped listing in `metadata.absent_since` and drops them after 90 days; `cross_check.rb` then reports where LiteLLM, models.dev and the bundled prices disagree.
