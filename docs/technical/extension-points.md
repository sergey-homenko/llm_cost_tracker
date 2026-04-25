# Extension Points

Extensions should plug into existing provider-agnostic boundaries. If a new feature needs a provider-specific branch outside ingestion or price-source code, revisit the design first.

## Custom Parsers

Use parser registration when a provider or gateway has a response shape the built-ins do not cover.

Expected parser contract:

- `match?(url)` detects supported request URLs.
- `parse(request_url, request_body, response_status, response_body)` returns `ParsedUsage` or `nil`.
- `parse_stream(request_url, request_body, response_status, events)` returns `ParsedUsage` or `nil`.
- `streaming_request?(request_url, request_body)` detects streaming requests when the provider does not use a simple `stream: true` field.
- `provider_names` returns provider names that can be used by `track_stream(provider: ...)`.

Use `Parsers::Base` helpers for URL matching and stream-event extraction. Use `Parsers::OpenaiUsage` only for OpenAI-shaped usage hashes.

## OpenAI-Compatible Gateways

Use `config.openai_compatible_providers` when a gateway speaks the OpenAI request and response shape.

This is for shape compatibility, not pricing. Gateway-specific model IDs or discounts belong in `prices_file` or `pricing_overrides`.

## Prices

Use `config.prices_file` for the app's source-controlled price snapshot.

Use `config.pricing_overrides` for urgent or environment-specific overrides that are easier to keep in Ruby.

Supported canonical keys:

- `input`
- `output`
- `cache_read_input`
- `cache_write_input`
- `batch_input`
- `batch_output`
- mode-prefixed keys such as `priority_input` or `batch_cache_read_input`

Provider-specific price-source fields must be translated before they reach runtime pricing.

## Tags

Tags are the extension point for application attribution:

- tenant
- user
- feature
- trace
- job
- workflow
- agent session

Use `config.default_tags`, middleware `tags:`, explicit metadata, and `LlmCostTracker.with_tags`. Do not add first-class columns for app dimensions unless the ledger needs that field for provider-agnostic billing behavior.

## Storage

Use `storage_backend = :custom` only when the host app needs to own persistence completely.

Custom storage receives a canonical `Event`. Returning `false` tells the tracker not to run budget checks for that event.

ActiveRecord storage is the production path for dashboards and cross-process budgets.

## Dashboard

Dashboard additions should be read-only services under `app/services/llm_cost_tracker/dashboard`.

Keep controller actions thin:

- parse params
- build filtered scope
- call services
- render views

Keep view logic in helpers when it is reused across pages. Do not add JavaScript for dashboard behavior.

## Generators

Generators are installation contracts. New generator behavior should be:

- additive when possible
- idempotent where Rails generator APIs allow it
- explicit about destructive or table-rewriting operations
- covered by generator template specs

Fresh install templates and upgrade generators should stay aligned. If a fresh install gains a column or index, the upgrade path needs a generator unless the next release intentionally makes a breaking install path.
