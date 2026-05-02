# Pricing and Price Refresh

LLM Cost Tracker prices calls locally from recorded usage and a versioned price
registry. Providers usually return token counts, not a stable per-request price,
so the gem stores the calculated cost with each ledger row.

The full pricing reference is moving here from the README: registry shape,
refresh tasks, precedence, provider-qualified keys, and mode-specific rates.

## Canonical Sources

Until this page is expanded, use:

- [Pricing](../README.md#pricing)
- [Supported providers](../README.md#supported-providers)
- [Known limitations](../README.md#known-limitations)

## Registry Rules

- Built-in prices live in `lib/llm_cost_tracker/prices.json`.
- Local snapshots live wherever `config.prices_file` points.
- Precedence is `pricing_overrides`, then `prices_file`, then bundled prices.
- Provider-qualified keys like `openai/gpt-4o-mini` win over model-only keys.
- Historical rows keep the cost calculated when the call was recorded.

## Refresh Commands

```bash
bin/rails generate llm_cost_tracker:prices
bin/rails llm_cost_tracker:prices:refresh
bin/rails llm_cost_tracker:prices:check
PROVIDER=openai MODEL=gpt-4o bin/rails llm_cost_tracker:prices:explain
```

The refresh task reads the maintained LLM Cost Tracker snapshot and writes to
`ENV["OUTPUT"]`, then `config.prices_file`, then
`config/llm_cost_tracker_prices.yml`.

## Price Fields

Base fields:

- `input`
- `output`
- `cache_read_input`
- `cache_write_input`
- `cache_write_1h_input`

`cache_write_input` is the standard cache-write bucket. `cache_write_1h_input`
is priced separately when provider usage exposes that longer retention bucket.

Mode-prefixed fields use the same base terms:

- `batch_input`
- `batch_output`
- `priority_input`
- `batch_cache_read_input`
- `priority_cache_write_1h_input`

Long-context entries may also include `_context_price_threshold_tokens` and
`above_context_*` fields. When the effective input side is above the threshold,
the calculator uses the matching `above_context_input`,
`above_context_output`, `above_context_cache_read_input`, or
`above_context_<mode>_*` rate for the whole priced event.

## Pricing Modes

`pricing_mode` is the canonical field for alternate provider pricing tiers.
OpenAI, OpenAI-compatible, Anthropic, Gemini, and RubyLLM capture populate it
from provider tier data when the response exposes that field. Standard aliases
such as `standard`, `default`, `auto`, and `standard_only` are treated as normal
pricing.

Bundled prices include OpenAI `flex`, `priority`, and regional processing
`data_residency` rates, Gemini `flex` and `priority`, Groq `flex`, and
Anthropic `fast` and `data_residency` rates where the official provider pages
publish them. OpenAI regional processing is captured from supported regional API
hosts for the model families whose uplift is published. Gemini Priority can
downgrade server-side, so Faraday capture trusts the `x-gemini-service-tier`
response header instead of assuming the requested tier was honored.

Pass `pricing_mode: :batch` when usage came from a batch job, a gateway, or
another path where the provider response does not expose the tier:

```ruby
LlmCostTracker.track(
  provider: "openai",
  model: "gpt-4o",
  input_tokens: 1_000_000,
  output_tokens: 250_000,
  pricing_mode: :batch,
  feature: "offline_eval"
)
```

The calculator uses `batch_input`, `batch_output`, and other matching
mode-prefixed fields when present. Missing positive-token mode rates make the
event unknown instead of silently using standard pricing. For batch mode, cache
rates can be derived from the input discount when the provider documents that
modifiers stack.

## Price Explain

Use `prices:explain` when Data Quality shows unknown pricing or a local override
does not behave as expected:

```bash
PROVIDER=openai MODEL=gpt-4o PRICING_MODE=batch bin/rails llm_cost_tracker:prices:explain
```

Optional token env vars let the command check the exact buckets that a call used:

```bash
PROVIDER=custom MODEL=gateway-model INPUT_TOKENS=1000 OUTPUT_TOKENS=200 CACHE_READ_INPUT_TOKENS=50 CACHE_WRITE_1H_INPUT_TOKENS=25 bin/rails llm_cost_tracker:prices:explain
```

The command reports the matched source, matched key, match strategy, effective
rates, and any missing rate needed to price the event.

Provider-specific pricing pages belong in scrapers and snapshots. Runtime
pricing should stay in canonical billing terms.

## Service Charges

`service_charges` store provider-reported tool or runtime usage that affects
billing context outside token prices. Current parsers use them for Anthropic
server tool usage, OpenAI hosted tool output items, and Gemini grounding
requests. Provider `service_charges` rates can price known charges; unknown-cost
service charges can make an event `partial` when token pricing is known, or
`unknown` when they are the only billable usage.

These rows are audit context, not invoice-grade pricing. They preserve the
provider item id, source key, quantity, component, applied rate, and status so
downstream reconciliation can join them back to provider records without the gem
inventing free tiers or private rates.
