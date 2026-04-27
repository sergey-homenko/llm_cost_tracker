# Budgets and Guardrails

Budgets are safety rails for a Rails app using LLMs in production. They are not
invoice reconciliation and they are not a transactional quota system.

The full behavior reference is moving here from the README: monthly, daily, and
per-call budgets; notification payloads; preflight behavior; and failure modes.

## Canonical Sources

Until this page is expanded, use:

- [Budgets](../README.md#budgets)
- [Known limitations](../README.md#known-limitations)
- [Operations](operations.md)

## Behaviors

- `:notify`: call `on_budget_exceeded` after a priced event crosses a limit.
- `:raise`: record the event, then raise `BudgetExceededError`.
- `:block_requests`: preflight future calls when stored period totals are
  already over budget.

```ruby
config.monthly_budget = 500.00
config.daily_budget = 50.00
config.per_call_budget = 2.00
config.budget_exceeded_behavior = :block_requests
```

`:block_requests` needs ActiveRecord storage for shared period totals. Under
concurrency it stops the next request after overspend is visible; it does not
make provider spend transactional.

## Error Payload

`BudgetExceededError` exposes:

- `budget_type`
- `total`
- `budget`
- `monthly_total`
- `daily_total`
- `call_cost`
- `last_event`
