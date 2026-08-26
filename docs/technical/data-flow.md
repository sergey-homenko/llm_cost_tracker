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
5. For streaming SDK calls, the wrapper passes the SDK stream through `Capture::StreamTracker` so the app still consumes the same stream object.
6. Streaming wrappers snapshot tags before returning the stream to the app.
7. The wrapper measures latency, extracts usage and provider tier data from the SDK response object or collected stream events, and sends `Event` to `Tracker.record`.
8. If an explicitly enabled SDK is not loaded or does not satisfy the install contract, boot raises before the app silently misses usage.

## Explicit Tracking

1. Your app calls `LlmCostTracker.track` with known usage totals, or `LlmCostTracker.track_stream` with stream events.
2. `track` accepts explicit `tokens:` and `tags:`, builds `Event`, and sends it to `Tracker.record`.
3. `track_stream` snapshots tags when the stream collector is created.
4. `track_stream` uses `Capture::StreamCollector`, then `Parsers.find_for_provider` when events need parsing.
5. `Tracker.record` prices and persists the event.

## Canonical Event Build

`Event.build` normalizes the raw capture — a blank model identifier becomes `unknown`, and usage source, stream flag and response identity are settled there. `Tracker.record` then normalizes tags and latency and drives the rest:

1. `Event` carries provider identity, model identity, stream metadata, response identity, provider grouping dimensions, `pricing_mode`, and `Usage::TokenUsage`.
3. `Pricing::Calculation` (built via `Pricing::Calculation.for`) prices token counters with the normalized `pricing_mode`, applies the same rates to token line items, and falls back to `Pricing::ServiceRates.charge_rate` for service line items when the registry has a reliable rate for the captured quantity basis. It exposes the header cost (or `nil` for unknown pricing), the rate snapshot, and the priced line items.
4. `Charges::CostStatus` combines token pricing and service line pricing into `free`, `complete`, `partial`, or `unknown`.
5. Tags are merged from the current or captured tag context, middleware tags, and explicit tags.
5. Persistence runs through `Ledger::Store.insert` (default) or `Ingestion::Inbox` when `config.ingestion.mode = :async`.
6. The persisted event is emitted through `ActiveSupport::Notifications`.
7. Budget checks run last. `enforce_budget: true` on `LlmCostTracker.track` makes them raise even when the configured behavior is `:notify`; the call is already recorded and the error carries `stage: :post_spend`. `LlmCostTracker.track_stream` instead checks before your block runs and raises `stage: :pre_send`.

## Ledger Storage

When `config.ingestion.mode = :inline` (default):

1. `Ledger::Store.insert` writes the call header, line items, and tag rows in a single transaction on the caller's ActiveRecord connection. If the caller is inside an open transaction, this write joins it — a caller-side `ActiveRecord::Rollback` discards the tracked event with the rest of the work. Switch to `config.ingestion.mode = :async` if you need ledger writes to survive caller rollbacks.
2. When `config.budgets.totals_source = :cache`, the rollup rows are incremented after that transaction commits, so a rollup failure is logged without failing the ledger write; otherwise rollups are skipped entirely.
3. Budget reads always aggregate live from `llm_cost_tracker_calls`. Under `config.budgets.totals_source = :cache` the query takes the greater of that aggregate and the rollup row, so a cache that has drifted low cannot make a budget under-report.

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
3. `Pricing::Sync` validates schema compatibility, gem-version compatibility, model price shape, and tool/runtime charge sections.
4. `RegistryWriter` writes a local JSON or YAML registry.
5. Runtime pricing loads the local file once and memoizes it. The file's mtime is recorded as the source version; changing the file in a running process has no effect until `LlmCostTracker.configure` runs again or the app reloads.

The gem never fetches pricing from the network during normal request tracking.
