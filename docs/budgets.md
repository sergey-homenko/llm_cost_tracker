# Budgets and Guardrails

Budgets are production guardrails — not invoice reconciliation, and not a
transactional quota system.

## Configuration

```ruby
LlmCostTracker.configure do |config|
  config.monthly_budget = 500.00
  config.daily_budget = 50.00
  config.per_call_budget = 2.00
  config.budget_exceeded_behavior = :notify
  config.on_budget_exceeded = ->(payload) { BudgetNotifier.call(payload) }
end
```

Budgets evaluate only when an event has a known cost. Unknown-cost events
are stored and surfaced on the Data Quality page, but they don't draw down
a numeric budget until pricing lands.

## Behaviors

| Behavior | Timing | Result |
| --- | --- | --- |
| `:notify` | After a priced event is recorded | Calls `on_budget_exceeded` once per budget type the event crossed (an event that pushes both daily and monthly over fires the callback twice — once per limit) |
| `:raise` | After a priced event is recorded | Raises `LlmCostTracker::BudgetExceededError` |
| `:block_requests` | Before supported requests and again after recording | Blocks the request when prior spend plus a character-count estimate of this call would cross a daily / monthly limit, or when the estimate alone crosses `per_call_budget`. Preflight blocks do not fire `on_budget_exceeded`; the callback only fires post-record on the event that first crossed the limit |

`:raise` records first, then raises. The call that crossed the budget
remains visible in the ledger.

`:block_requests` reads accumulated spend (see Budget Reads below) and
also estimates the current call's input cost via a character-count
heuristic (chars / 4 ≈ tokens, provider-agnostic, no external
tokenizer). It blocks before send when prior spend plus the estimate
would cross a daily / monthly limit, or when the estimate alone
crosses `per_call_budget`. Output tokens stay unknown pre-send and
are caught by the existing post-record check. Approximate by design —
runway-stop, not precise prediction. Unknown models (no pricing
match) skip the estimate and fall through to the prior-spend
preflight.

Under concurrency, multiple workers can clear preflight before each
other's spend is visible. It stops the next request once overspend
lands — it doesn't make provider spend transactional.

## Budget Reads

Where the monthly/daily totals come from depends on
`config.cache_rollups` and `config.ingestion`:

| Source | When read |
| --- | --- |
| Live `SUM(total_cost)` from `llm_cost_tracker_calls` | Default when `cache_rollups = false` |
| `llm_cost_tracker_call_rollups` fast path | When `cache_rollups = true` |
| Pending `llm_cost_tracker_ingestion_inbox_entries` totals | Added on top when `ingestion = :async` (events sit in the inbox until the worker drains them) |

Per-call budgets are checked from the current event only.

Monthly preflight runs before daily preflight. Post-record checks report
daily before monthly so short-term operational alerts stay prominent.

Budget aggregation assumes a single-currency ledger. The rollups table
partitions buckets by currency on the write side (so a `prices_file`
with `metadata.currency: "EUR"` lands EUR rows separately from
bundled USD), but `Period::Totals` sums across currency rows without a
filter and `llm_cost_tracker_calls` has no currency column to filter
the live aggregate against. In practice this is correct for the only
two realistic setups — USD-only (the default) or a fully non-USD
`prices_file` — because every row in the period is denominated in
the same currency. Mixing currencies inside one ledger (some models
bundled USD, others priced from a non-USD `prices_file`) leaves the
budget total summed across units and is not supported.

## Error and Callback Payload

`BudgetExceededError` and `on_budget_exceeded` payloads expose:

| Key | Meaning |
| --- | --- |
| `budget_type` | `:monthly`, `:daily`, or `:per_call` |
| `total` | Observed total for the budget type. For `stage == :pre_send`: prior spend plus the call's estimate for daily / monthly, and the estimate alone for `per_call`. |
| `budget` | Configured threshold |
| `last_event` | Event that triggered the check when available (`nil` for `stage == :pre_send` because the call has not yet been made) |
| `stage` | `:pre_send` for preflight blocks under `:block_requests`, `:post_spend` for post-record checks |

## Operational Notes

When `config.cache_rollups = true`, `llm_cost_tracker:doctor` verifies
the rollups table and its `(period, period_start, currency, provider)`
unique index. With `cache_rollups = false`, doctor warns instead if a
stale rollups table is found and confirms that budget reads aggregate
live from the calls table.

Live aggregation works fine on small/medium ledgers thanks to the
`tracked_at` index on `llm_cost_tracker_calls`. Flip `cache_rollups`
on once monthly/daily SUMs become slow at your call volume.

For strict quotas, use provider-side limits or a transactional counter
in your own app.
