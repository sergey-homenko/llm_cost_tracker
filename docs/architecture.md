# Architecture

LLM Cost Tracker is a provider-agnostic billing ledger. Core code should model durable billing concepts, not the naming quirks of one provider or one model family.

Core vocabulary belongs in provider-neutral terms:

- `input_tokens`
- `cache_read_input_tokens`
- `cache_write_input_tokens`
- `output_tokens`
- `hidden_output_tokens`
- `pricing_mode`
- `provider_response_id`

Provider-specific names belong only at ingestion boundaries: parsers, stream adapters, and price-source adapters. Those adapters translate raw fields into the canonical ledger vocabulary before data reaches `Tracker`, `Pricing`, storage, dashboard services, or reports.

Pricing logic should prefer generic mechanisms over provider branches. Use provider/model price entries only for lookup and rate selection. Use `pricing_mode` plus mode-prefixed price keys for alternate billing modes instead of adding model-specific conditionals.

Tags remain the extension point for app-specific attribution such as tenant, user, feature, trace, job, workflow, or agent session. Do not promote those dimensions into first-class columns unless the ledger itself needs them for provider-agnostic billing behavior.

Hot-path guardrails must not aggregate over the growing call ledger. ActiveRecord period budgets should read maintained rollup tables such as `llm_cost_tracker_monthly_totals` and `llm_cost_tracker_daily_totals`; dashboard analytics may run grouped queries because they are user-initiated reporting paths.
