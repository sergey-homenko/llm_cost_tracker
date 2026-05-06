# Querying and Reports

Once calls land in the ledger they're yours — query from a console, a
scheduled job, an admin UI, or the mounted dashboard.

## Common Scopes

```ruby
calls = LlmCostTracker::Call

calls.today.total_cost
calls.this_month.total_tokens
calls.this_month.cost_by_model
calls.this_month.cost_by_provider
calls.this_month.cost_by_tag("feature")
calls.by_tags(user_id: 42, feature: "chat").this_month.total_cost
calls.daily_costs(days: 7)
```

## Time and Cost Scopes

| Scope/helper | Purpose |
| --- | --- |
| `today` | Calls since UTC start of day |
| `this_week` | Calls since UTC start of week |
| `this_month` | Calls since UTC start of month |
| `between(from, to)` | Calls inside a timestamp range |
| `with_cost` | Calls with known total cost |
| `without_cost` | Calls with nil total cost |
| `unknown_pricing` | Calls with nil, unknown, or partial pricing |
| `streaming` | Streaming calls |
| `non_streaming` | Non-streaming calls |
| `by_usage_source(source)` | Calls by usage source |
| `with_provider_response_id` | Calls with provider response IDs |
| `missing_provider_response_id` | Calls without provider response IDs |
| `streaming_missing_usage` | Stream rows without final usage |

## Aggregates

| Helper | Return shape |
| --- | --- |
| `total_cost` | Numeric total over the current relation |
| `total_tokens` | Integer token total over the current relation |
| `cost_by_model(limit: nil)` | Relation with `name` and `total_cost` |
| `cost_by_provider(limit: nil)` | Relation with `name` and `total_cost` |
| `cost_by_tag(key, limit: nil)` | Relation with tag value `name` and `total_cost` |
| `daily_costs(days: 30)` | Hash grouped by day string |
| `average_latency_ms` | Average latency for the relation |
| `latency_by_model` | Hash of model to average latency |
| `latency_by_provider` | Hash of provider to average latency |

Tag aggregations join through `llm_cost_tracker_call_tags` so the same query
shape works on PostgreSQL and MySQL.

## Line items

Per-component cost rows hang off each call. Tokens and tool charges share the
same shape:

```ruby
call = LlmCostTracker::Call.includes(:line_items).first
call.line_items.map { |item| [item.kind, item.cost] }

# Just the non-token charges (tools, runtime, etc.)
call.line_items.where.not(unit: "token")
```

Useful scopes on `LlmCostTracker::CallLineItem`:

| Scope | Returns |
| --- | --- |
| `tokens` | Token line items only |
| `by_kind(kind)` | Filter by component kind |
| `by_direction(:input)` | Input vs output |
| `by_modality(:audio)` | Text, audio, image, video |
| `cached` | Items with a cache state other than `none` |
| `priced` / `unpriced` | Cost status filter |

The parent call's `total_cost` already sums priced line items.

## Report Task

```bash
bin/rails llm_cost_tracker:report
DAYS=7 bin/rails llm_cost_tracker:report
```

`config.report_tag_breakdowns` controls extra tag sections in the text report.

## CSV Export

The dashboard Calls page exports filtered rows as CSV. Values that look like
spreadsheet formulas are prefixed before export.
