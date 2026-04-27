# Upgrading

LLM Cost Tracker is still moving quickly, so upgrades should be explicit:
inspect the changelog, run doctor, and apply only the generators your schema is
missing.

The version-by-version upgrade guide is moving here from the README.

## Canonical Sources

Until this page is expanded, use:

- [Changelog](../CHANGELOG.md)
- [Quickstart](../README.md#quickstart)
- [Operations](operations.md)

## Schema Generators

Existing installs can add newer optional columns through focused generators:

```bash
bin/rails generate llm_cost_tracker:add_period_totals
bin/rails generate llm_cost_tracker:add_streaming
bin/rails generate llm_cost_tracker:add_provider_response_id
bin/rails generate llm_cost_tracker:add_usage_breakdown
bin/rails generate llm_cost_tracker:upgrade_tags_to_jsonb
bin/rails generate llm_cost_tracker:upgrade_cost_precision
bin/rails generate llm_cost_tracker:add_latency_ms
bin/rails db:migrate
bin/rails llm_cost_tracker:doctor
```

On PostgreSQL, `upgrade_tags_to_jsonb` rewrites `llm_api_calls`. For large
tables, run it during a maintenance window or replace it with a two-phase
backfill.

## Upgrade Habit

Run:

```bash
bin/rails llm_cost_tracker:doctor
```

Doctor tells you which optional columns and production-hardening pieces are still
missing.
