# Dashboard

The dashboard is an optional Rails Engine for reviewing spend, attribution, and
data quality. It is server-rendered ERB, has no JavaScript bundle, and reads
from the host app's ActiveRecord ledger tables.

## Mounting

Fresh installs can run setup:

```bash
bin/rails llm_cost_tracker:setup
```

For apps that are already installed, mount the dashboard with the generator:

```bash
bin/rails generate llm_cost_tracker:install --dashboard
bin/rails db:migrate
```

Or mount manually:

```ruby
mount LlmCostTracker::Engine => "/llm-costs"
```

The engine does not ship authentication. Mount it behind the host app's existing
admin/auth layer.

## Tables Read

The dashboard reads:

| Table | Purpose |
| --- | --- |
| `llm_api_calls` | Calls, token buckets, costs, tags, pricing status, snapshots |
| `llm_cost_tracker_service_charges` | Provider-reported tool/runtime usage tied to calls |
| `llm_cost_tracker_period_totals` | Budget status and operational rollups |
| `llm_cost_tracker_inbox_events` | Pending budget totals and ingestion health |

## Pages

| Page | Route | Purpose |
| --- | --- | --- |
| Overview | `/` | Spend trend, budget status, anomaly banner, provider rollup, top models |
| Models | `/models` | Spend and usage by provider/model |
| Calls | `/calls` | Filterable ledger, call details, CSV export |
| Tags | `/tags` and `/tags/:key` | Tag key explorer and tag value breakdowns |
| Data Quality | `/data_quality` | Unknown pricing, partial costs, missing latency, incomplete streams, service charge coverage |

## Filters

Dashboard pages share date/provider/model/tag filtering when the page supports
those dimensions.
Tag filters use the same sanitized tag keys accepted by `LlmCostTracker.with_tags`
and `track(tags:)`.

Invalid filters render a bad-request page instead of raising through the host
app.

## Security

The dashboard intentionally stores and displays no prompts or completions.
However, tags are app-controlled data. They render in the overview, tag pages,
call details, and CSV export, and they are visible to anyone with dashboard or
database access.

## Tags Hygiene

Do not put personal data, prompt bodies, customer messages, API keys, bearer
tokens, or long free-form text in tags. Prefer stable operational identifiers
such as internal numeric IDs, tenant slugs, feature names, job names, or
environment labels. Configure `redacted_tag_keys` for known secret-like keys, but
treat it as a guardrail rather than a privacy boundary.

## Styling Contract

Dashboard UI uses the engine stylesheet served through
`LlmCostTracker::AssetsController`. It remains plain CSS and server-rendered ERB;
there is no JavaScript bundle to compile or deploy.
