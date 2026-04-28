# Operations

Production use is mostly about choosing the right storage backend, keeping the
database healthy, and understanding where the gem is intentionally best effort.

The operational guide is moving here from the README: retention, tag storage,
thread safety, connection pools, and deployment notes.

## Canonical Sources

Until this page is expanded, use:

- [Privacy](../README.md#privacy)
- [Known limitations](../README.md#known-limitations)
- [Technical operational notes](technical/operational-notes.md)

## Production Defaults

- Use `storage_backend = :active_record` for the shared ledger, dashboard, and
  cross-process budget guardrails.
- Size the ActiveRecord connection pool for your app plus ledger writes.
- Keep `storage_error_behavior = :warn` unless losing the LLM response is better
  than losing the ledger event.
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

Tags are JSONB with a GIN index on PostgreSQL and JSON text elsewhere. The
dashboard and query helpers work across supported adapters, but PostgreSQL is the
strongest path for large tag-heavy ledgers.
