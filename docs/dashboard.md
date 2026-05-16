# Dashboard

The dashboard is an optional Rails Engine for reviewing spend, attribution, and
data quality. Server-rendered ERB, no JavaScript bundle, reads straight from
your ledger tables.

## Mounting

Fresh installs can run setup:

```bash
bin/rails llm_cost_tracker:setup
```

If the gem is already installed, add the dashboard with the generator:

```bash
bin/rails generate llm_cost_tracker:install --dashboard
bin/rails db:migrate
```

The generator does **not** write the route automatically. Mount the engine
in `config/routes.rb` behind your app's authentication:

```ruby
authenticate :admin do
  mount LlmCostTracker::Engine => "/llm-costs"
end
```

The engine ships without built-in authentication. Leaving it
unauthenticated exposes spend totals, tags, and provider IDs to anyone
who can reach the host.

## Tables Read

The dashboard reads:

| Table | Purpose |
| --- | --- |
| `llm_cost_tracker_calls` | Header rows: token totals, total cost, pricing status, snapshots |
| `llm_cost_tracker_call_line_items` | Per-component cost breakdown (tokens + tool charges) |
| `llm_cost_tracker_call_tags` | Tag attribution for filters and breakdowns |
| `llm_cost_tracker_call_rollups` (optional) | Budget status and operational aggregates when `config.cache_rollups = true` |
| `llm_cost_tracker_ingestion_inbox_entries` (optional) | Pending budget totals and ingestion health when `config.ingestion = :async` |

## Pages

| Page | Route | Purpose |
| --- | --- | --- |
| Overview | `/` | Spend trend, budget status, anomaly banner, provider rollup, top models |
| Models | `/models` | Spend and usage by provider/model |
| Calls | `/calls` | Filterable ledger, call details, CSV export |
| Tags | `/tags` and `/tags/:key` | Tag key explorer and tag value breakdowns |
| Data Quality | `/data_quality` | Unknown pricing, partial costs, missing latency, incomplete streams, tool/runtime charge coverage |
| Reconciliation | `/reconciliation` | Experimental opt-in. Hidden unless `config.reconciliation_enabled = true` and the optional generator has been run. See [Configuration](configuration.md#reconciliation-experimental-opt-in). |

## Filters

Dashboard pages share date/provider/model/tag filtering when the page supports
those dimensions.
Tag filters use the same sanitized tag keys accepted by `LlmCostTracker.with_tags`
and `track(tags:)`.

Invalid filters render a bad-request page instead of raising through your app.

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
