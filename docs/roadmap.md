# Roadmap

The gem is a **runtime LLM cost tracker** for a Rails app. Capture, price, attribute, budget. No proxy, no prompt storage, no traces, no evals, no warehouse. The 0.8 line-item rebuild is the foundation; everything below keeps that boundary.

Architecture: [Architecture](architecture.md). Data model: [Data model](data-model.md).

## Validation discipline

Every roadmap item must clear three filters before it gets started:

1. **Pain** — 3+ independent GitHub issues, forum threads, or HN comments from real developers describe the problem. Vendor blog posts don't count.
2. **Concept** — does not break the load-bearing constraints: no proxy, no prompt storage, Rails-native, ActiveRecord-only, hot path makes no network calls and never reads the ledger.
3. **Implementation** — reachable without admin-tier API keys, without adding heavy infra, without depending on another vendor SaaS.

If a candidate fails any filter, it stays in the anti-roadmap until evidence shifts. If a shipped feature gets no traction in six months, it goes to maintenance mode, not the next minor.

## v0.14 → v1.0 — sharpen the core

One item left, backed by verified pain. This is what users actually hit in production.

1. **Cache-aware cost accuracy.** Cache cost calculation is broken across the ecosystem (LiteLLM `#19681` — 10× overcharge; `#27191` — 67%, both with reproductions). The line-item schema already models `cache_read_input`, `cache_write_input`, and `cache_write_extended_input`. Lock the accuracy in with regression fixtures derived from the public bug reports above. Anthropic's 5-min vs 1-hour TTL split already lands in separate buckets; what is missing is the fixture coverage that keeps it from regressing.

## v1.0 → v1.x — capture & accuracy

After 1.0 stabilizes the API, capture grows where enterprise users hit real gaps and pricing accuracy keeps shipping behind regression fixtures. Each item still has to clear the three filters above.

1. **AWS Bedrock + Vertex AI native capture (Faraday path).** EU and regional residency for Anthropic models routes through Bedrock Frankfurt or Vertex Belgium with separate pricing — those calls currently miss the ledger or land with wrong rates. Ship: host detection for `bedrock-runtime.{region}.amazonaws.com` and `{region}-aiplatform.googleapis.com`; parsers that delegate to the existing Anthropic / Gemini body-parsing per publisher; regional rates via the existing `pricing_mode` machinery; price scrapers for the Bedrock and Vertex pricing pages. Anthropic family first (Messages + Converse on Bedrock; rawPredict on Vertex). Other Bedrock families (Llama, Mistral, Nova, Cohere) and Vertex Garden non-Anthropic stay out of scope until demand. The README will need to say that `aws-sdk-bedrockruntime` and `google-cloud-aiplatform` use their own HTTP clients (not Faraday) and need separate SDK integrations — tracked in v1.x+ reactive.

2. **Tool-charge pricing accuracy.** Same pattern as cache accuracy in v1.0. Capture for hosted tools (OpenAI web search reasoning vs non-reasoning, file search GB-day, code-interpreter sessions, container minutes; Anthropic web search / web fetch / code execution; Gemini grounding) already lives in line items — lock the math with regression fixtures derived from public bug reports (OpenAI forum blake24 thread: `$4.41` charged when `$1.71` expected).

## v1.x+ — reactive

Not planned in advance. Each item ships only against verified demand.

- `aws-sdk-bedrockruntime` SDK integration. Separate codepath from the Faraday-path parsers above (AWS SDK uses its own HTTP client, not Faraday). Gated on: first user issue that their Bedrock calls aren't captured despite the Faraday-path landing.
- `google-cloud-aiplatform` SDK integration. Same gate.
- Agentic workflow dashboard views over the existing tag conventions (`workflow_id`, `run_id`, `user_action_id`, `agent_name`). No schema change — aggregations against `call_tags`. Gated on real demand.
- Automated price scraper polish (foundations exist in `lib/llm_cost_tracker/pricing/sync.rb`, `scripts/price_scrape/runner.rb`).
- Deeper real-time / voice capture, if users start shipping it. The `response.done` path is already recorded through `track_stream`; what is missing is session-level capture without a passthrough.
- Other provider integrations (Cohere direct, xAI Grok direct, etc.), when a provider crosses ~5% enterprise share AND a developer asks.
- Regional billing dimensions beyond what the Bedrock / Vertex work already provides, if EU AI Act enforcement creates real demand for finer-grained region-aware cost rows.

## Anti-roadmap

Explicit rejections. Every item below was considered and ruled out:

- **First-class `trace_id` / `parent_call_id` columns.** Tag conventions plus the existing `call_tags` composite index cover trace attribution. Schema columns would lock the attribution shape and reduce flexibility — the whole point of tags is that the host app picks the dimensions.
- **Tokenizer fingerprint capture.** No provider exposes tokenizer version in responses, so the mechanism as originally drafted is unimplementable. Detecting stealth re-pricing by `tokens / char` ratio drift is a host-app monitoring concern (host apps already see drift in `total_tokens` per call against their own char counts); duplicating that inside the cost tracker is observability scope creep.
- **Per-tenant chargeback report templates.** `Call.cost_by_tag` + the dashboard tag detail page + CSV export already cover "what did Acme Corp cost us last month". A resolver hook for human-readable tag-value labels is a one-PR addition whenever someone asks — not a milestone-level feature.
- **Reconciliation.** Removed in v0.12 — never finished, never billing-accurate. Provider-side `provider_response_id` (captured on every call) covers the cross-reference use case. If we revisit invoice-vs-ledger reconciliation it ships as a separate gem.
- **Cost forecasting.** Vendor blog posts only; no developer demand.
- **Cross-provider price comparison** ("compare gpt-4o vs claude on the same workload by cost"). Vendors talk about it, developers don't ask.
- **Multi-modal cost explainers.** Provider calculators already cover this.
- **Generic evals / traces / prompt management.** Different product; the hosted observability vendors win that lane.
- **MCP-specific billing metadata.** No metering layer to integrate with.
- **OpenRouter-as-primary integration.** Direct provider integration is the core; aggregators stay best-effort via OpenAI-compatible Faraday.
- **Proxy mode.** Breaks the "direct calls only" identity.
- **Prompt content storage.** Breaks the privacy pillar.
- **Standalone service / paid SaaS.** OSS gem is the moat; a SaaS fork would dilute it.

## Tag conventions

Agentic workflows produce many calls per user action. Cost is meaningful at the workflow level, not the call level. The gem treats these as tag conventions — applications opt in without a migration and the schema stays flat:

- `workflow_id` — long-lived process the user kicked off
- `run_id` — one execution of a workflow
- `user_action_id` — single user request that produced this run
- `agent_name` — which agent role recorded the call

Dashboards group and filter by these tag keys when present. The existing `call_tags` composite index plus `cost_by_tag` / `group_by_tag` cover the aggregation; agentic dashboard views over these keys are tracked in v1.x+ reactive. These stay as tag conventions — promoting them to schema columns is in the anti-roadmap.

## Standing constraints

- Runtime tracking never makes a network call or scans the ledger. Hot path reads `pricing.overrides` → file snapshot → bundled snapshot, then writes inline through `Ledger::Store.insert` by default, or enqueues to the async inbox when `config.ingestion.mode = :async`.
- Header is a projection. Per-component costs live in `llm_cost_tracker_call_line_items`; rollups stay a hot-path cache.
- Postgres and MySQL parity. Every ledger query must run on both.
- No silent migrations. Schema changes ship behind generators with upgrade notes; doctor surfaces missing schema before per-event branching is introduced.
