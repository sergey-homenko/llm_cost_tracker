# Roadmap

The gem is a **runtime LLM cost tracker** for a Rails app. Capture, price,
attribute, budget. No proxy, no prompt storage, no traces, no evals, no
warehouse. The 0.8 line-item rebuild is the foundation; everything below
keeps that boundary.

Architecture: [Architecture](architecture.md). Data model:
[Data model](data-model.md). Original billing design: [RFC 0001](rfcs/0001-line-item-billing.md).

## Validation discipline

Every roadmap item must clear three filters before it gets started:

1. **Pain** — 3+ independent GitHub issues, forum threads, or HN comments
   from real developers describe the problem. Vendor blog posts don't count.
2. **Concept** — does not break the load-bearing constraints: no proxy, no
   prompt storage, Rails-native, ActiveRecord-only, hot path makes no
   network calls and never reads the ledger.
3. **Implementation** — reachable without admin-tier API keys, without
   adding heavy infra, without depending on another vendor SaaS.

If a candidate fails any filter, it stays in the anti-roadmap until
evidence shifts. If a shipped feature gets no traction in six months,
it goes to maintenance mode, not the next minor.

## v0.9 → v1.0 — sharpen the core

Four items, all backed by verified pain. These are what users actually
hit in production.

1. **Pre-send budget enforcement.**
   Provider hard limits don't reliably stop spend (OpenAI forum:
   `$563.88` debt on a `$5` prepaid account; "hard limit was bypassed"
   threads). The gem already has a budget API; extend it with a
   pre-call hook that estimates token cost via a heuristic (character
   count for all providers; `tiktoken_ruby` optional for OpenAI) and
   blocks before send when the budget is exhausted. After the call,
   recalibrate against real usage. No network in the hot path.

2. **Cache-aware cost accuracy.**
   Cache cost calculation is broken across the ecosystem (LiteLLM
   `#19681` — 10× overcharge; `#27191` — 67%, both with reproductions).
   The line-item schema already models `cache_read_input`,
   `cache_write_input`, and `cache_write_extended_input`. Lock the
   accuracy in with regression fixtures derived from the public bug
   reports above, plus per-provider cache-tier rate matrices that
   capture Anthropic's 5-min vs 1-hour TTL split.

3. **Per-tenant chargeback report templates.**
   Multi-tenant SaaS teams need "what did Acme Corp cost us last
   month" (HN `$50K` MCP attribution comment; AWS Bedrock granular
   attribution post; AgentPulse "surprise bills"). Tags already carry
   `tenant_id` / `feature` / `user_id`. Add a rake task and a
   dashboard view that groups cost by tag value with an optional
   resolver hook into the host app's `accounts` / `organizations`
   table.

4. **Tokenizer fingerprint capture.**
   Stealth re-pricing via tokenizer changes is now an established
   pattern (Claude Opus 4.7, April 2026: same headline price, +32-34%
   tokens on production prompts). Add a `tokenizer_version` column on
   calls; parsers populate it from response headers/metadata where
   available; doctor warns when an unexpected tokenizer version
   appears for a known model.

## v1.0 → v1.2 — agentic attribution (gated on signals)

Pre-condition: at least 5 GitHub issues describing real production
agentic-cost-attribution problems. If that signal doesn't arrive,
defer.

- First-class `trace_id` / `parent_call_id` columns (not tag
  conventions). Optional, nullable, indexed. Materialized rollups by
  user action.
- Tool-charge accuracy audit. Web search, file search GB-day, code
  execution sessions, container minutes — capture as line items with
  fixtures matching real provider responses (OpenAI forum blake24
  thread: `$4.41` charged when `$1.71` expected).
- Pricing snapshot drift detection. Doctor alert when bundled prices
  change between releases for already-recorded calls.

## v1.2+ — reactive

Not planned in advance. Each item ships only against verified demand.

- Automated price scraper polish (foundations exist in
  `pricing/sync.rb`, `pricing/scrape/runner.rb`).
- Optional OpenTelemetry GenAI emitter, when the semantic conventions
  stabilize (likely 2027). Dual-emit: keep the local ledger, also
  publish to whatever OTel backend the host app runs.
- Regional billing dimensions, if EU AI Act enforcement creates real
  customer demand for region-aware cost rows.
- Real-time / voice API line items, if users start shipping them.
- New provider integrations, when a provider crosses ~5% enterprise
  share.

## Anti-roadmap

Explicit rejections. Every item below was considered and ruled out:

- **Reconciliation expansion.** v0.9 ships an experimental opt-in
  side mode (admin-key security plane, lazy-loaded, isolated). Zero
  developer-pain evidence found in the wild — the original Reddit
  comment was a drive-by. Stays experimental, no expansion.
- **Cost forecasting.** Vendor blog posts only; no developer demand.
- **Cross-provider price comparison** ("compare gpt-4o vs claude on
  the same workload by cost"). Vendors talk about it, developers
  don't ask.
- **Multi-modal cost explainers.** Provider calculators already cover
  this.
- **Generic evals / traces / prompt management.** Different product;
  the `$200`-`$2,499`/mo SaaS tier wins that lane.
- **MCP-specific billing metadata.** No metering layer to integrate
  with.
- **OpenRouter-as-primary integration.** Direct provider integration
  is the core; aggregators stay best-effort via OpenAI-compatible
  Faraday.
- **Proxy mode.** Breaks the "direct calls only" identity.
- **Prompt content storage.** Breaks the privacy pillar.
- **Standalone service / paid SaaS.** OSS gem is the moat; a SaaS
  fork would dilute it.

## Tag conventions

Agentic workflows produce many calls per user action. Cost is meaningful
at the workflow level, not the call level. The gem treats these as a tag
convention rather than schema columns so applications can opt in without
a migration:

- `workflow_id` — long-lived process the user kicked off
- `run_id` — one execution of a workflow
- `user_action_id` — single user request that produced this run
- `agent_name` — which agent role recorded the call

Dashboards group and filter by these tag keys when present. If real
demand surfaces (see v1.0 → v1.2), they get promoted to first-class
columns; until then they stay tag conventions.

## Standing constraints

- Runtime tracking never makes a network call or scans the ledger. Hot
  path reads `pricing_overrides` → file snapshot → bundled snapshot,
  then enqueues to the durable inbox.
- Header is a projection. Per-component costs live in
  `llm_cost_tracker_call_line_items`; rollups stay a hot-path cache.
- Postgres and MySQL parity. Every ledger query must run on both.
- Reconciliation must stay isolated from core (autoload, gated proxy
  via `LlmCostTracker.reconciliation_enabled?`, no constant references
  from core paths). See the isolation contract in
  [Architecture](architecture.md).
- No silent migrations. Schema changes ship behind generators with
  upgrade notes; doctor surfaces missing schema before per-event
  branching is introduced.
