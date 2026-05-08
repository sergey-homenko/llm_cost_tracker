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
| `:notify` | After a priced event is durably staged | Calls `on_budget_exceeded` once for the crossed limit |
| `:raise` | After a priced event is durably staged | Raises `LlmCostTracker::BudgetExceededError` |
| `:block_requests` | Before supported requests and again after recording | Blocks when maintained call rollups are already over budget |

`:raise` records first, then raises. The call that crossed the budget remains
visible in the ledger.

`:block_requests` reads from maintained call rollups plus pending inbox
totals. Under concurrency, multiple workers can clear preflight before each
other's spend is visible. It stops the next request once overspend lands —
it doesn't make provider spend transactional.

## Budget Types

| Budget | Source |
| --- | --- |
| Monthly | `llm_cost_tracker_call_rollups` plus pending inbox totals for the current month |
| Daily | `llm_cost_tracker_call_rollups` plus pending inbox totals for the current day |
| Per call | The current event total cost |

Monthly preflight runs before daily preflight. Post-record checks report daily
before monthly so short-term operational alerts stay prominent.

## Error and Callback Payload

`BudgetExceededError` and `on_budget_exceeded` payloads expose:

| Key | Meaning |
| --- | --- |
| `budget_type` | `:monthly`, `:daily`, or `:per_call` |
| `total` | Observed total for the budget type |
| `budget` | Configured threshold |
| `last_event` | Event that triggered the check when available |

## Operational Notes

`llm_cost_tracker:doctor` verifies the call rollups table and the unique
`(period, period_start, currency, provider)` index. Without current rollups,
hot-path budget checks fail outright instead of falling back to a full
ledger scan.

For strict quotas, use provider-side limits or a transactional counter in
your own app.
