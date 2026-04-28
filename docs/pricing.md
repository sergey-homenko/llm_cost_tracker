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

Mode-prefixed fields use the same base terms:

- `batch_input`
- `batch_output`
- `priority_input`
- `batch_cache_read_input`

## Pricing Modes

Pass `pricing_mode: :batch` when usage came from a provider batch job or another
discounted mode:

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
mode-prefixed fields when present, then falls back to the base field for missing
mode-specific rates.

## Price Explain

Use `prices:explain` when Data Quality shows unknown pricing or a local override
does not behave as expected:

```bash
PROVIDER=openai MODEL=gpt-4o PRICING_MODE=batch bin/rails llm_cost_tracker:prices:explain
```

Optional token env vars let the command check the exact buckets that a call used:

```bash
PROVIDER=custom MODEL=gateway-model INPUT_TOKENS=1000 OUTPUT_TOKENS=200 CACHE_READ_INPUT_TOKENS=50 bin/rails llm_cost_tracker:prices:explain
```

The command reports the matched source, matched key, match strategy, effective
rates, and any missing rate needed to price the event.

Provider-specific pricing pages belong in scrapers and snapshots. Runtime
pricing should stay in canonical billing terms.
