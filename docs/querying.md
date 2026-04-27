# Querying and Reports

Once calls are in `llm_api_calls`, the host app owns the data. Query it from a
console, a scheduled job, your admin UI, or the mounted dashboard.

The full querying reference is moving here from the README: ActiveRecord scopes,
reporting helpers, tag breakdowns, and SQL-side grouping patterns.

## Canonical Sources

Until this page is expanded, use:

- [Querying](../README.md#querying)
- [Dashboard](dashboard.md)
- [Operations](operations.md)

## Common Queries

```ruby
LlmCostTracker::LlmApiCall.today.total_cost
LlmCostTracker::LlmApiCall.this_month.cost_by_model
LlmCostTracker::LlmApiCall.this_month.cost_by_provider
LlmCostTracker::LlmApiCall.this_month.cost_by_tag("feature")
LlmCostTracker::LlmApiCall.by_tags(user_id: 42, feature: "chat").this_month.total_cost
LlmCostTracker::LlmApiCall.daily_costs(days: 7)
```

## Report Task

```bash
bin/rails llm_cost_tracker:report
DAYS=7 bin/rails llm_cost_tracker:report
```

This page is scoped to cost scopes, tag grouping, period grouping, latency
helpers, unknown-pricing queries, and report tag breakdowns.
