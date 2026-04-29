# Extension Points

Extensions should plug into existing provider-agnostic boundaries. If a new feature needs a provider-specific branch outside ingestion code, revisit the design first.

## SDK Integrations

Use SDK integrations when a popular Ruby client does not expose a Faraday middleware stack but returns stable usage objects. RubyLLM and the official `openai` and `anthropic` gems qualify. Faraday-based clients that expose a middleware hook, such as `ruby-openai`'s constructor block, are covered by the Faraday middleware instead. Clients with no stable hook must use the explicit `track` / `track_stream` fallback until an integration exists.

Expected integration contract:

- no hard dependency on the provider SDK
- fail-fast boot when an explicitly enabled SDK is missing or below the minimum supported version
- install-time checks for the target classes and methods
- idempotent `Module#prepend` around narrow resource methods
- no tracking when the integration is not enabled in configuration
- canonical usage fields passed to `Tracker.record`

SDK integrations belong under `LlmCostTracker::Integrations`. Do not put SDK object-shape handling in parsers, storage, or pricing.

## OpenAI-Compatible Gateways

Use `config.openai_compatible_providers` when a gateway speaks the OpenAI request and response shape.

This is for shape compatibility, not pricing. Gateway-specific model IDs or discounts belong in `prices_file` or `pricing_overrides`.

Providers or gateways with non-compatible response shapes should use explicit `LlmCostTracker.track` / `track_stream` calls until a built-in parser exists.

## Prices

Use `config.prices_file` for the app's source-controlled price snapshot.

Use `config.pricing_overrides` for urgent or environment-specific overrides that are easier to keep in Ruby.

Supported canonical keys:

- `input`
- `output`
- `cache_read_input`
- `cache_write_input`
- `cache_write_1h_input`
- `batch_input`
- `batch_output`
- mode-prefixed keys such as `priority_input` or `batch_cache_read_input`

Provider-specific pricing details must be translated before they reach runtime pricing.

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

Storage is not an extension point. LLM Cost Tracker writes canonical `Event`
objects to the host Rails app's ActiveRecord ledger.

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
