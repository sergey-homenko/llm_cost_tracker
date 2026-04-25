# Data Flow

This is the normal path from an application LLM call to stored ledger data.

## Faraday Requests

1. The host app sends an HTTP request through Faraday.
2. `LlmCostTracker::Middleware::Faraday` checks whether a parser matches the request URL.
3. For non-streaming responses, the middleware passes request and response data to the parser.
4. For streaming responses, the middleware tees `on_data`, collects stream events, and parses final usage when the stream completes.
5. The parser returns `ParsedUsage` with canonical fields.
6. `Tracker.record` prices and persists the event.

## SDK Integrations

1. The host app enables an integration with `config.instrument`.
2. `LlmCostTracker::Integrations` prepends a narrow wrapper to supported SDK resource methods.
3. The host app keeps calling the provider SDK normally.
4. The wrapper measures latency, extracts usage from the SDK response object, and sends canonical fields to `Tracker.record`.
5. If the provider SDK is not loaded, boot continues and `llm_cost_tracker:doctor` reports the missing integration.

## Explicit Tracking

1. The host app calls `LlmCostTracker.track` with known usage totals, or `LlmCostTracker.track_stream` with stream events.
2. `track` sends manual totals directly to `Tracker.record`.
3. `track_stream` uses `StreamCollector`, then parser lookup by provider when events need parsing.
4. `Tracker.record` prices and persists the event.

## Canonical Event Build

`Tracker.record` performs the central normalization step:

1. Blank model identifiers become `unknown`.
2. Input, output, cache-read, cache-write, hidden-output, and pricing-mode values are extracted from metadata.
3. `Pricing.cost_for` calculates a `Cost` object or returns `nil` for unknown pricing.
4. Tags are merged from `with_tags`, `default_tags`, middleware tags, and explicit metadata.
5. An `Event` is created and emitted through `ActiveSupport::Notifications`.
6. The configured storage backend receives the event.
7. Budget checks run unless storage explicitly returns `false`.

## ActiveRecord Storage

1. `Storage::ActiveRecordStore.save` converts tags for JSON or text storage.
2. Optional fields are written only when their columns exist.
3. The call row and period rollup updates happen in one transaction.
4. `ActiveRecordRollups.increment!` updates daily and monthly totals atomically.
5. Budget reads use period totals when available.

## Dashboard Reads

1. Controllers build a filtered `LlmApiCall` scope.
2. Dashboard services run targeted aggregate queries.
3. Helpers render filters, charts, pagination, CSV links, and numeric formatting.
4. Views render plain ERB with the engine CSS asset.

Dashboard reads do not mutate ledger state. They can be heavier than request-time code, but they still need explicit grouping and indexes.

## Pricing Refresh

1. `llm_cost_tracker:prices:sync` chooses `ENV["OUTPUT"]`, then `config.prices_file`.
2. Price-source adapters fetch structured LiteLLM and OpenRouter data.
3. `ModelCatalog`, `Merger`, and `Validator` normalize and validate entries.
4. `RegistryWriter` writes a local JSON or YAML registry.
5. Runtime pricing reloads the local file when its mtime changes.

The gem never fetches pricing from the network during normal request tracking.
