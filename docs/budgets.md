# Budgets and Guardrails

Budgets are production guardrails. They are not invoice reconciliation and they
are not a transactional quota system.

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

Budgets are evaluated only when the event has known cost. Unknown-cost events are
stored and surfaced through Data Quality, but they cannot consume a numeric
budget until pricing is known.

## Behaviors

| Behavior | Timing | Result |
| --- | --- | --- |
| `:notify` | After a priced event is durably staged | Calls `on_budget_exceeded` once for the crossed limit |
| `:raise` | After a priced event is durably staged | Raises `LlmCostTracker::BudgetExceededError` |
| `:block_requests` | Before supported requests and again after recording | Blocks when maintained period totals are already over budget |

`:raise` records first, then raises. The call that crossed the budget remains
visible in the ledger.

`:block_requests` uses maintained ActiveRecord period totals plus pending inbox
totals. Under concurrency, multiple workers can pass preflight before one
another's spend is visible. It stops the next request after overspend appears; it
does not make provider spend transactional.

## Budget Types

| Budget | Source |
| --- | --- |
| Monthly | `llm_cost_tracker_period_totals` plus pending inbox totals for the current month |
| Daily | `llm_cost_tracker_period_totals` plus pending inbox totals for the current day |
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

`llm_cost_tracker:doctor` verifies the period totals table and unique
`(period, period_start)` index. Without current period rollups, hot-path budget
checks fail rather than scanning the full ledger.

For strict quotas, use provider-side limits or a host-app transactional counter
outside this gem.
