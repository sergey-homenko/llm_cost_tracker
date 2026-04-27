# Dashboard

The dashboard is a Rails Engine for humans reviewing spend, attribution, and data
quality. It is server-rendered ERB, has no JavaScript bundle, and reads from the
host app's `llm_api_calls` table.

The detailed dashboard guide is moving here from the README: mounting, route
constraints, authentication examples, page map, and operational notes.

## Canonical Sources

Until this page is expanded, use:

- [Dashboard](../README.md#dashboard)
- [Privacy](../README.md#privacy)
- [Operations](operations.md)

## Mounting

```ruby
mount LlmCostTracker::Engine => "/llm-costs"
```

Use `storage_backend = :active_record` for apps that mount the dashboard.

## Pages

- Overview: spend trend, budget status, anomaly banner, provider rollup, top models
- Models: spend and usage by provider and model
- Calls: filterable call ledger with CSV export
- Tags: tag keys and tag value breakdowns
- Data Quality: unknown pricing, untagged calls, missing latency, incomplete streams

## Authentication

The gem does not ship dashboard auth. Mount the engine behind the host app's
existing authentication layer: Devise, basic auth, Cloudflare Access, or your own
constraints.
