# Extension Points

Extensions should plug into existing provider-agnostic boundaries. If a new feature needs a provider-specific branch outside ingestion code, revisit the design first.

## SDK Integrations

Use SDK integrations for Ruby clients that do not expose Faraday middleware but
return stable usage objects. RubyLLM and the official `openai` and `anthropic`
gems use this path. Faraday-based clients that expose a middleware hook, such as
`ruby-openai`'s constructor block, are covered by the Faraday middleware. Clients
with no stable hook use explicit `track` / `track_stream` calls until an
integration exists.

Expected integration contract:

- no hard dependency on the provider SDK
- fail-fast boot when an explicitly enabled SDK is missing or below the minimum supported version
- install-time checks for the target classes and methods
- idempotent `Module#prepend` around narrow resource methods
- no tracking when the integration is not enabled in configuration
- `Event` with `Usage::TokenUsage` passed to `Tracker.record`

SDK integrations belong under `LlmCostTracker::Integrations`. Do not put SDK object-shape handling in parsers, storage, or pricing.

## OpenAI-Compatible Gateways

Use `config.capture.openai_compatible_providers` when a gateway speaks the OpenAI request and response shape.

Host mapping controls shape compatibility, not pricing. Gateway-specific model
IDs or discounts belong in `prices_file` or `pricing_overrides`.

Providers or gateways with non-compatible response shapes should use explicit `LlmCostTracker.track` / `track_stream` calls until a built-in parser exists.

## Prices

Use `config.pricing.file` for the app's source-controlled price snapshot.

Use `config.pricing.overrides` for urgent or environment-specific Ruby-side
overrides.

Supported token price keys are owned by `Usage::Catalog`:

- `input`
- `output`
- `cache_read_input`
- `cache_write_input`
- `cache_write_extended_input`
- `audio_input`
- `audio_output`
- `batch_input`
- `batch_output`
- mode-prefixed keys such as `priority_input` or `batch_cache_read_input`
- `_context_price_threshold_tokens` with `above_context_*` rates for providers
  that publish a whole-session long-context tier

Tool and runtime rates live under `service_charges` keyed by provider and
component (web search, code execution, grounding, container session, file
search). Do not add a rate unless the parser captures the same quantity basis
the rate uses.

Provider-specific pricing details must be translated before they reach runtime pricing.
Do not rely on standard rates for missing alternate-mode prices; add explicit
mode-prefixed prices unless the provider documents a stackable multiplier.

## Tags

Tags are the extension point for application attribution:

- tenant
- user
- feature
- trace
- job
- workflow
- session

Use `config.tags.default`, middleware `tags:`, explicit `tags:`, and `LlmCostTracker.with_tags`. Do not add first-class columns for app dimensions unless the ledger needs that field for provider-agnostic billing behavior.

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
