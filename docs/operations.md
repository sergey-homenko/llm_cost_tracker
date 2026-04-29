# Operations

Production use is mostly about keeping the ActiveRecord ledger healthy and
understanding where the gem is intentionally best effort.

The operational guide is moving here from the README: retention, tag storage,
thread safety, connection pools, and deployment notes.

## Canonical Sources

Until this page is expanded, use:

- [Privacy](../README.md#privacy)
- [Known limitations](../README.md#known-limitations)
- [Technical operational notes](technical/operational-notes.md)

## Production Defaults

- Size the ActiveRecord connection pool for your app plus ledger writes.
- Treat `:block_requests` as a guardrail, not a hard quota.
- Keep `default_tags` callables fast and thread-safe.

## Retention

Retention is explicit. Use the prune task when the ledger should not grow
forever:

```bash
DAYS=90 bin/rails llm_cost_tracker:prune
```

When ActiveRecord period rollups are installed, pruning decrements the
affected daily and monthly buckets in the same batch transaction as the ledger
delete.

## Data Shape

Tags are JSONB with a GIN index on PostgreSQL and native JSON on MySQL. The
dashboard and query helpers work across both supported adapters, but PostgreSQL
is the strongest path for large tag-heavy ledgers.
