# Roadmap

Direction of travel after the 0.8 line-item rebuild. Scope stays inside the
**runtime LLM cost tracker** remit: capture, price, persist, attribute,
and budget against LLM provider spend from a Rails app. No OTel, eval,
cache, warehouse, or finance-reconciler extensions.

The shipped schema and architecture are described in
[Data model](data-model.md) and [Architecture](architecture.md). The original
billing-rebuild design lives in [RFC 0001](rfcs/0001-line-item-billing.md).

## Strategic direction

0.8 left a hybrid. Header columns (`total_cost`, token counters) are still
read by overview/sort/aggregate paths, but line items + `pricing_snapshot`
are the bookkeeping truth. Header stays a projection/cache, line items
stay the ledger.

Provider invoice reconciliation (v0.9) is an **experimental side mode**,
not the strategic direction. The core gem is and remains a runtime
tracker. Reconciliation lives behind two opt-ins, loads lazily, and
doesn't touch core code paths — see [Architecture](architecture.md) for
the isolation contract.

## v0.9

1. **Provider invoice reconciliation.** ⚠️ Shipped as **experimental**.
   Two opt-ins required (`config.reconciliation_enabled = true` plus a
   separate generator). Built on architectural intuition rather than
   validated user demand — public API may change in v0.9.x based on real
   feedback. If no concrete user demand surfaces by v1.0, reconciliation
   stays in maintenance mode (bug fixes only) or moves to a companion
   gem. Design: [RFC 0002](rfcs/0002-invoice-reconciliation.md).
2. **Explicit rate basis enum on service charges.** ✓ Shipped.
   `Billing::RATE_BASES = %i[per_million_tokens per_request per_1k_requests
   per_session per_hour per_gb_day]`. `Billing::Component#rate_basis`
   exposes the explicit unit semantics; `Pricing::ServiceCharges` derives
   `rate_quantity` from it instead of the prior `unit == :request ? 1000
   : 1` heuristic.
3. **`pricing_mode` as a normalized set internally.** ✓ Shipped.
   `Pricing::Mode` value object parses any `pricing_mode:` input into a
   sorted modifier set (`%i[batch data_residency]`), drops the
   permutation guesswork in `EffectivePrices`, and round-trips back to a
   canonical string. The DB column stays a string for compatibility.
4. **MySQL/MariaDB smoke as a release gate.** Real container, real
   migrations, real `bin/check`. CI matrix already runs the suite, but
   without an end-to-end smoke a MySQL-only regression can ship.
   Deferred from the v0.9.0 cut.

## Scope policy

The gem is `llm_cost_tracker` — a **runtime LLM cost tracker** for a
Rails app. Capture, price, persist, attribute. That's the product.

It is **not** an LLM finance reconciler, not a billing platform, not a
warehouse. Reconciliation in v0.9 is an experimental opt-in side mode
(separate config flag, separate generator, separate security plane via
admin/org keys) — not a commitment to grow the gem in that direction.

Reconciliation does not graduate from experimental without **validated
user demand** (concrete GitHub issues from real installations, not
architectural intuition). If demand doesn't surface, reconciliation
stays in maintenance mode or moves to a companion gem
(`llm_cost_reconciler`).

## v0.10 — core tracker improvements

The next cycle stays inside the runtime cost tracker remit. Likely
candidates, ordered by user value over architectural ambition:

- Per-tag / per-feature budgets (the "who burned the money" question
  gets sharper).
- Cost forecasting on the dashboard (extrapolate the current trend).
- Optimization hints (cache hit ratio, model substitution, token
  hotspots).
- More provider integrations as their official SDKs and OpenAI-compat
  endpoints stabilise (Mistral, Cohere, Together, Groq, Perplexity).
- Per-tenant chargeback report templates.
- Drift alerts on local cost (anomaly detection on rollups).

Each item is decided by GitHub issues / discussions, not roadmap
inertia. Items only ship when at least one real user describes the
shape of the problem they hit.

Reconciliation follow-ups (multi-meter tools, Gemini/Vertex billing
import, `line_item` match basis, signed price registry source version)
are explicitly **out of scope for v0.10** unless reconciliation itself
graduates first.

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
