# Upgrading

LLM Cost Tracker is still moving quickly, so upgrades should be explicit:
inspect the changelog, run doctor, and bring the ledger tables to the current
schema before deploying the new gem version.

The version-by-version upgrade guide is moving here from the README.

## Canonical Sources

Until this page is expanded, use:

- [Changelog](../CHANGELOG.md)
- [Quickstart](../README.md#quickstart)
- [Operations](operations.md)

## Schema Generators

Existing installs can add missing current-schema pieces through focused generators:

```bash
bin/rails generate llm_cost_tracker:add_period_totals
bin/rails generate llm_cost_tracker:add_ingestion
bin/rails generate llm_cost_tracker:add_streaming
bin/rails generate llm_cost_tracker:add_provider_response_id
bin/rails generate llm_cost_tracker:add_token_usage
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

Doctor tells you which current-schema and production-hardening pieces are still
missing. Missing current ledger columns are errors; apply the listed generators
and migrate before serving dashboard or tracking traffic on the upgraded version.
