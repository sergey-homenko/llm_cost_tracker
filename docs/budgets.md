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
| `:notify` | After a priced event is recorded | Calls `on_budget_exceeded` once for the crossed limit |
| `:raise` | After a priced event is recorded | Raises `LlmCostTracker::BudgetExceededError` |
| `:block_requests` | Before supported requests and again after recording | Blocks the next request once accumulated spend crosses the budget |

`:raise` records first, then raises. The call that crossed the budget
remains visible in the ledger.

`:block_requests` reads accumulated spend (see Budget Reads below).
Under concurrency, multiple workers can clear preflight before each
other's spend is visible. It stops the next request once overspend
lands — it doesn't make provider spend transactional.

## Budget Reads

Where the monthly/daily totals come from depends on
`config.cache_rollups` and `config.durable_ingestion`:

| Source | When read |
| --- | --- |
| Live `SUM(total_cost)` from `llm_cost_tracker_calls` | Default when `cache_rollups = false` |
| `llm_cost_tracker_call_rollups` fast path | When `cache_rollups = true` |
| Pending `llm_cost_tracker_ingestion_inbox_entries` totals | Added on top when `durable_ingestion = true` (events sit in the inbox until the worker drains them) |

Per-call budgets are checked from the current event only.

Monthly preflight runs before daily preflight. Post-record checks report
daily before monthly so short-term operational alerts stay prominent.

## Error and Callback Payload

`BudgetExceededError` and `on_budget_exceeded` payloads expose:

| Key | Meaning |
| --- | --- |
| `budget_type` | `:monthly`, `:daily`, or `:per_call` |
| `total` | Observed total for the budget type |
| `budget` | Configured threshold |
| `last_event` | Event that triggered the check when available |

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
