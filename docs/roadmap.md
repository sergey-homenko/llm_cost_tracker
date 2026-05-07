# Roadmap

Direction of travel after the 0.8 line-item rebuild. Scope stays inside the
"Rails cost ledger" remit: capture, price, persist, reconcile, and budget
against LLM provider spend from a Rails app. No OTel, eval, cache, or
warehouse extensions.

The shipped schema and architecture are described in
[Data model](data-model.md) and [Architecture](architecture.md). The original
billing-rebuild design lives in [RFC 0001](rfcs/0001-line-item-billing.md).

## Strategic direction

0.8 left a hybrid. Header columns (`total_cost`, token counters) are still
read by overview/sort/aggregate paths, but line items + `pricing_snapshot`
are the bookkeeping truth. The 0.9-0.10 cycle should keep that boundary:
header stays a projection/cache, line items + invoices stay the ledger.

The reconciliation work is provider-meter reconciliation, not just invoice
import. Provider rows carry different kinds of evidence (financial cost
vs. usage counts vs. free quota vs. credits) and the diff treats them
separately rather than summing them blindly. Local ledger answers "what
the app did and how we priced it"; provider invoice ledger answers "what
the provider billed"; diff answers "where the truth diverged."

## v0.9

1. **Provider invoice reconciliation.** Import provider-side cost/usage
   rows into `llm_cost_tracker_provider_invoices`, diff against local
   rollups and line items per `(source, period_start, period_end)` and the
   captured `provider_project_id` / `provider_api_key_id` /
   `provider_workspace_id` dimensions, surface drift in the dashboard.
   `metadata` carries the meter envelope (`row_type`, `meter`, `authority`,
   `match_basis`) so cost rows, usage rows, free-quota rows, and credits
   stay distinct in the diff. OpenAI Costs API ships first because OpenAI
   docs explicitly call Costs the financial reconciliation source;
   Anthropic Cost/Usage ships second because of workspace + service-tier
   nuance. Design: RFC 0002.
2. **Explicit rate basis enum on service charges.**
   `per_request` / `per_1k_requests` / `per_session` / `per_hour` /
   `per_gb_day`. Removes the per-1 vs per-1000 ambiguity that the
   `service_charges` config still leaves implicit. Required ahead of
   multi-meter tools in v0.10. One migration, additive.
3. **`pricing_mode` as a normalized set internally.** Keep the column as a
   string for compatibility, but represent it as a sorted array of
   modifiers (`%i[priority batch data_residency]`) inside the gem. Drops
   the permutation guesswork and makes mode checks `include?` instead of
   string matching.
4. **MySQL/MariaDB smoke as a release gate.** Real container, real
   migrations, real `bin/check`. CI matrix already runs the suite, but
   without an end-to-end smoke a MySQL-only regression can ship.

## v0.10

5. **Multi-meter tools.** File-search storage (per-GB-day), container
   memory and session windows, search-content tokens, URL context
   fetches, embeddings-backed retrieval, context cache token-hour. Extends
   `Billing::Components` with the new `rate_basis` shapes from v0.9 and
   feeds the reconciliation diff.
6. **Price registry reproducibility.** Snapshot freshness checks, signed
   `source_version`, drift detection between bundled and remote
   snapshots, no runtime network. Builds on the existing
   `pricing_snapshot` / `pricing_overrides` plumbing.
7. **Gemini / Vertex billing export importer.** Free-quota and per-query
   grounding semantics need their own meter shape; ships once the v0.9
   meter envelope is in place.
8. **Rollup fast path for reconciliation diff.** Add a `provider` column
   to `llm_cost_tracker_call_rollups` so the reconciliation diff can read
   aligned-month `local_total` from rollups instead of scanning line
   items. Currently rollups are a global cache; once they are
   per-provider, the diff fast path falls out for free.

## Tag conventions

Agentic workflows produce many calls per user action. Cost is meaningful
at the workflow level, not the call level. The gem treats these as a tag
convention rather than schema columns so applications can opt in without
a migration:

- `workflow_id` — long-lived process the user kicked off
- `run_id` — one execution of a workflow
- `user_action_id` — single user request that produced this run
- `agent_name` — which agent role recorded the call

Dashboards group and filter by these tag keys when present. Treat them as
documented tag names, not enforced schema.

## Standing constraints

- Runtime tracking never makes a network call or scans the ledger. Hot
  path reads `pricing_overrides` → file snapshot → bundled snapshot, then
  enqueues to the durable inbox.
- Header is a projection. Per-component costs and provider-side usage
  evidence live in `llm_cost_tracker_call_line_items` and
  `llm_cost_tracker_provider_invoices`. Rollups stay a hot-path cache.
- Postgres and MySQL parity. Every ledger query must run on both.
- Importers are operational tools. They run off the hot path, must be
  idempotent on `external_id`, paginated and resumable across provider
  cursors.
- Diff totals are SQL aggregates (`SUM(...)`); the dashboard
  reconciliation page never loads provider invoices or calls into Ruby
  to add them up.
- No silent migrations. Schema changes ship behind generators with
  upgrade notes; doctor surfaces missing schema before per-event
  branching is introduced.
