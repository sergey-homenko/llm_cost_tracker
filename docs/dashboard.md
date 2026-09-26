# Dashboard

The dashboard is an optional page for reviewing spend, attribution, and data quality — the engine always loads, mounting its route is what turns it on. Server-rendered ERB, no JavaScript bundle, reads straight from your ledger tables.

## Mounting

Fresh installs can run setup:

```bash
bin/rails llm_cost_tracker:setup
```

If the gem is already installed, the dashboard needs no migration and no generator — mount the route and you are done. `--dashboard` only prints the mounting reminder below, and re-running the installer over an existing migration aborts unless you pass `--skip`:

```bash
bin/rails generate llm_cost_tracker:install --dashboard --skip
```

The generator does **not** write the route automatically. Mount the engine in `config/routes.rb` behind your app's authentication:

```ruby
authenticate :admin do
  mount LlmCostTracker::Engine => "/llm-costs"
end
```

The engine ships without built-in authentication. Leaving it unauthenticated exposes spend totals, tags, and provider IDs to anyone who can reach the host.

## Tables Read

The dashboard reads:

| Table | Purpose |
| --- | --- |
| `llm_cost_tracker_calls` | Header rows: token totals, total cost, pricing status, snapshots |
| `llm_cost_tracker_call_line_items` | Per-component cost breakdown (tokens + tool charges) |
| `llm_cost_tracker_call_tags` | Tag attribution for filters and breakdowns |
| `llm_cost_tracker_call_rollups` (optional) | Overview monthly budget status when `config.budgets.monthly` is set and `config.budgets.totals_source = :cache` |
| `llm_cost_tracker_ingestion_inbox_entries` (optional) | Pending budget totals and ingestion health when `config.ingestion.mode = :async` |

## Pages

| Page | Route | Purpose |
| --- | --- | --- |
| Overview | `/` | Spend trend, budget status, anomaly banner, provider rollup, top models |
| Models | `/models` | Spend and usage by provider/model, top 200 |
| Calls | `/calls` | Filterable ledger, call details, CSV export |
| Tags | `/tags` and `/tags/:key` | Tag key explorer and tag value breakdowns |
| Data Quality | `/data_quality` | Incomplete pricing, partial costs, missing latency, incomplete streams, tool/runtime charge coverage, budgeted tags no call carries |
| Pricing | `/pricing` | Per-model rates as separate tabs — Overrides, Custom file, Bundled; the active source (first non-empty in priority order) is highlighted, with last-updated date and currency next to the row count. |

## Filters

Dashboard pages share date/provider/model/tag filtering when the page supports those dimensions. Dates and daily charts follow the app's `Time.zone`; daily charts need the database to know the zone name (PostgreSQL through its tzdata, MySQL through the server's time zone tables loaded with `mysql_tzinfo_to_sql`) and otherwise stay on UTC days. Tag filters use the same sanitized tag keys accepted by `LlmCostTracker.with_tags` and `track(tags:)`.

A page accepts at most 10 tag filters, counting a tag value page's own value, and each filter takes a single value, not a list. Invalid filters, including on the CSV export, render a bad-request page instead of raising through your app.

## Security

Dashboard links and filter forms carry only the dashboard's own query parameters; anything else in the URL is dropped, and a query string over 16 KB is a bad request.

The dashboard intentionally stores and displays no prompts or completions. However, tags are app-controlled data. They render in the Calls list, tag pages, call details, and CSV export, and they are visible to anyone with dashboard or database access.

## Tags Hygiene

Do not put personal data, prompt bodies, customer messages, API keys, bearer tokens, or long free-form text in tags. Prefer stable operational identifiers such as internal numeric IDs, tenant slugs, feature names, job names, or environment labels. Configure `tags.redacted_keys` for known secret-like keys, but treat it as a guardrail rather than a privacy boundary.

## Styling Contract

Dashboard UI uses the engine stylesheet served through `LlmCostTracker::AssetsController`. It remains plain CSS and server-rendered ERB; there is no JavaScript bundle to compile or deploy.
