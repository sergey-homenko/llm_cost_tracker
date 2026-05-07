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

## v0.9

1. **Provider invoice reconciliation.** Import provider-side cost/usage rows
   into `llm_cost_tracker_provider_invoices`, diff against local rollups and
   line items per `(provider, period_start, period_end)` and the captured
   `provider_project_id` / `provider_api_key_id` / `provider_workspace_id`
   dimensions, surface drift in the dashboard. This is the reason the v0.8
   schema carries those dimensions and the placeholder table — the gem moves
   from "estimate spend" to "reconcile against provider truth". Design: RFC
   0002 (in progress).
2. **Explicit rate basis enum on service charges.**
   `per_request` / `per_1k_requests` / `per_session` / `per_hour` /
   `per_gb_day`. Removes the per-1 vs per-1000 ambiguity that the
   `service_charges` config still leaves implicit. One migration, additive.
3. **`pricing_mode` as a normalized set internally.** Keep the column as a
   string for compatibility, but represent it as a sorted array of
   modifiers (`%i[priority batch data_residency]`) inside the gem. Drops the
   permutation guesswork and makes mode checks `include?` instead of string
   matching.
4. **MySQL/MariaDB smoke as a release gate.** Real container, real
   migrations, real `bin/check`. CI matrix already runs the suite, but
   without an end-to-end smoke a MySQL-only regression can ship.

## v0.10

5. **Multi-meter tools.** File-search storage (per-GB-day), container
   memory and session windows, search-content tokens, URL context fetches,
   embeddings-backed retrieval. Extends `Billing::Components` with new
   `pricing_basis` shapes feeding the reconciliation diff.
6. **Price registry reproducibility.** Snapshot freshness checks, signed
   `source_version`, drift detection between bundled and remote snapshots,
   no runtime network. Builds on the existing `pricing_snapshot` /
   `pricing_overrides` plumbing.

## Standing constraints

- Runtime tracking never makes a network call or scans the ledger. Hot path
  reads `pricing_overrides` → file snapshot → bundled snapshot, then
  enqueues to the durable inbox.
- Header is a projection. Per-component costs and provider-side usage
  evidence live in `llm_cost_tracker_call_line_items` and
  `llm_cost_tracker_provider_invoices`. Rollups stay a hot-path cache.
- Postgres and MySQL parity. Every ledger query must run on both.
- No silent migrations. Schema changes ship behind generators with
  upgrade notes; doctor surfaces missing schema before per-event branching
  is introduced.
