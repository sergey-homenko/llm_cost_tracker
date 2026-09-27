# Budgets and Guardrails

Budgets are production guardrails — not invoice reconciliation, and not a transactional quota system.

## Configuration

```ruby
LlmCostTracker.configure do |config|
  config.budgets.monthly = 500.00
  config.budgets.daily = 50.00
  config.budgets.per_call = 2.00
  config.budgets.exceeded_behavior = :notify
  config.budgets.on_exceeded = ->(payload) { BudgetNotifier.call(payload) }
end
```

Budgets evaluate only when an event has a known cost. Unknown-cost events are stored and surfaced on the Data Quality page, but they don't draw down a numeric budget until pricing lands.

## Behaviors

| Behavior | Timing | Result |
| --- | --- | --- |
| `:notify` | After a priced event is recorded | Calls `budgets.on_exceeded` once per budget type the event crossed (an event that pushes both daily and monthly over fires the callback twice — once per limit) |
| `:raise` | After a priced event is recorded | Raises `LlmCostTracker::BudgetExceededError` |
| `:block_requests` | Before supported requests (through the Faraday middleware, only `POST` requests) and again after recording | Blocks the request when prior spend plus a character-count estimate of this call would cross a daily / monthly limit, or when the estimate alone crosses `budgets.per_call`. Preflight blocks do not fire `budgets.on_exceeded`; the callback only fires post-record on the event that first crossed the limit |

`:raise` records first, then raises. The call that crossed the budget remains visible in the ledger. Every limit the call crossed, per-tag rules included, gets its `on_exceeded` call before the error for the first one is raised.

`:block_requests` reads accumulated spend (see Budget Reads below) and also estimates the current call's input cost via a character-count heuristic (chars / 4 ≈ tokens, provider-agnostic, no external tokenizer). Base64 image, PDF and audio data is not counted. It blocks before send when prior spend plus the estimate would cross a daily / monthly limit, or when the estimate alone crosses `budgets.per_call`. Output tokens stay unknown pre-send and are caught by the existing post-record check. Approximate by design — runway-stop, not precise prediction. Unknown models (no pricing match) skip the estimate and fall through to the prior-spend preflight.

Under concurrency, multiple workers can clear preflight before each other's spend is visible. It stops the next request once overspend lands — it doesn't make provider spend transactional.

`on_exceeded` is not exactly-once. Each call checks its budgets right after its own row is written, against the rows visible at that moment. When two calls to the same budget land so close together that neither crosses the limit alone and both rows are visible to both checks, a per-tag rule fires for both: the earlier-stamped call cannot tell whether the later call's check already counted it, and staying silent would lose the alert whenever that check ran first. A call that commits after a later-stamped call was checked, such as one inside a slow transaction of your own or on a host whose clock runs ahead, can likewise make the global daily and monthly budgets fire twice, or not at all when the crossing is split between the two calls. On MySQL, a call recorded inside a transaction of your own is checked against the snapshot InnoDB's default REPEATABLE READ isolation took at that transaction's first read, so spend other calls committed since then is not counted and any budget, per-tag rules included, can miss a crossing split between them; record outside the transaction, or open it with `isolation: :read_committed`, to avoid this. The gem does not add a database lock for this: the lock would have to cover each call's write, commit and check, so inside your own transaction it would be held until you commit and stall every other call to the same budget, and outside one it would queue all recording per budget. With `ingestion.mode = :async`, per-tag rules are scored by the one worker that drains the inbox, so each crossing fires once.

If the budget read fails (database unavailable, statement timeout), `:block_requests` raises that error to your code and the request is not sent.

## Per-Tag Budgets

`budgets.per_tag` applies one budget to every distinct value of a tag, for as many tags as you declare:

```ruby
config.budgets.per_tag = {
  tenant_id: { monthly: 1000.00, weekly: 300.00 },
  user_id:   { daily: 25.00, behavior: :notify }
}
```

Each `tenant_id` gets its own 1000 a month, and each `user_id` its own 25 a day. The budgets are not shared, and the number of values does not change the configuration.

Scoped spend is read from `llm_cost_tracker_call_tags`, which carries a copy of the call's `total_cost` and `tracked_at` so a budget check reads one table with no join. A fresh install already has both columns and the index they need. An install created before v0.14 adds them with:

```bash
bin/rails generate llm_cost_tracker:upgrade_per_tag_budgets
bin/rails db:migrate
```

The migration only adds the columns and replaces the `(key, value)` index with `(key, value, tracked_at)` — the old one is a prefix of the new one, so the index count stays the same. Rows recorded before the migration keep a null cost and are not counted; to count them, backfill in batches afterwards:

```bash
bin/rails llm_cost_tracker:backfill_tag_costs
```

It is safe to run more than once and skips rows already filled. Until the columns exist the option logs a warning once and enforces nothing; calls are still recorded.

Repricing keeps the copies honest: `llm_cost_tracker:backfill_unknown_pricing` and `llm_cost_tracker:reprice` update the tag rows along with the call.

Scoped checks run after the global ones, even when a global limit raises. By default each rule follows the global `exceeded_behavior` and `on_exceeded`, and may override either:

```ruby
config.budgets.per_tag = {
  tenant_id: {
    monthly: 1000.00,
    behavior: :notify,
    on_exceeded: ->(payload) { TenantBudgetMailer.warn(payload).deliver_later }
  }
}
```

That lets an app block on the global ceiling while only warning a tenant that overspends, or the other way round — a rule set to `:block_requests` blocks pre-send even when the global policy is `:notify`.

`enforce_budget: true` overrides all of that for one call. On `LlmCostTracker.track` the call is recorded first and then raised on, because `track` reports a request the provider has already served — the spend is real and stays in the ledger, and the error carries `stage: :post_spend`. On `LlmCostTracker.track_stream` the check runs before your block does, so it raises with `stage: :pre_send` and nothing is spent. Either way every rule matching the call's tags is checked, so a rule set to `:notify` raises too. The exception is `track` under `ingestion.mode = :async`: there only the global budgets raise, and scoped rules are checked later from the drain, which only notifies. Leave it off to let each rule's own behavior decide.

The payload and `BudgetExceededError` carry `scope`:

```ruby
{ budget_type: :monthly, scope: { key: "tenant_id", value: "42" }, total: ..., budget: ... }
```

`scope` is `nil` for the global budgets.

Calls that do not carry a declared tag are subject to the global budgets only. A budget on a tag name nothing sends is accepted — the name is well formed, and the gem cannot know at boot which tags your code will use — so it simply never fires. The Data Quality page names budgeted tags no recorded call carries, and drops them from the list as soon as one arrives.

### Budget high-cardinality tags only

A budget check costs one indexed query per window of every declared tag present on the call — a rule with `daily`, `weekly` and `monthly` limits is three reads, not one — and each read's speed follows how many distinct values that tag has. Measured on 2M calls with 4M tag rows:

| Tag | Distinct values | Monthly read |
| --- | --- | --- |
| `tenant_id` | 500 | 6 ms |
| `environment` | 2 | 246 ms |

A tag with few values covers most of the ledger, so no index helps and every call pays for a near-full scan. Budget a tenant, account, or user id — not `environment`, `feature`, or anything else with a handful of values. When a read crosses 100 ms the gem logs a warning once per tag naming the offender.

Two more limits. The weekly window follows the host app's `Date.beginning_of_week`. And with `ingestion.mode = :async`, a scoped total counts only what the worker has already drained: `on_exceeded` fires from the drain rather than from the request, pre-send blocking sees spend late by the drain interval, and a rule set to `:block_requests` can only notify from the drain, since the request it would have blocked is long gone — and if no `on_exceeded` is set for it, that rule produces no post-spend signal at all under `:async`. A batch is scored per window it touches, so a drain that runs after midnight still scores the previous day against that day.

## Budget Reads

Where the monthly/daily totals come from depends on `config.budgets.totals_source` and `config.ingestion.mode`:

| Source | When read |
| --- | --- |
| Live `SUM(total_cost)` from `llm_cost_tracker_calls` | The whole window with `config.budgets.totals_source = :ledger` (the default); only today (UTC) with `:cache` |
| Daily rows of `llm_cost_tracker_call_rollups` | Days of the month before today when `config.budgets.totals_source = :cache` |
| Pending `llm_cost_tracker_ingestion_inbox_entries` totals | Added on top when `ingestion.mode = :async` (events sit in the inbox until the worker drains them) |

Per-call budgets are checked from the current event only.

Monthly preflight runs before daily preflight. Post-record checks report daily before monthly so short-term operational alerts stay prominent.

Budget aggregation assumes a single-currency ledger. The rollups table partitions buckets by currency on the write side (so a `pricing.file` with `metadata.currency: "EUR"` lands EUR rows separately from bundled USD), but `Period::Totals` sums across currency rows without a filter and `llm_cost_tracker_calls` has no currency column to filter the live aggregate against. In practice this is correct for the only two realistic setups — USD-only (the default) or a fully non-USD `pricing.file` — because every row in the period is denominated in the same currency. Mixing currencies inside one ledger (some models bundled USD, others priced from a non-USD `pricing.file`) leaves the budget total summed across units and is not supported.

## Error and Callback Payload

`BudgetExceededError` and `budgets.on_exceeded` payloads expose:

| Key | Meaning |
| --- | --- |
| `budget_type` | `:monthly`, `:daily`, `:per_call`, or — for a per-tag rule — `:weekly` |
| `total` | Observed total for the budget type. For `stage == :pre_send`: prior spend plus the call's estimate for daily / monthly, and the estimate alone for `per_call`. |
| `budget` | Configured threshold |
| `last_event` | Event that triggered the check when available (`nil` for `stage == :pre_send` because the call has not yet been made) |
| `stage` | `:pre_send` for preflight blocks under `:block_requests`, `:post_spend` for post-record checks |
| `scope` | `{ key:, value: }` for a `budgets.per_tag` check, `nil` for the global budgets |

## Operational Notes

When `config.budgets.totals_source = :cache`, `llm_cost_tracker:doctor` checks that the rollups table exists and carries the expected columns, and warns when this month's day rollups before today do not add up to the calls ledger. It does not inspect indexes, so a table created by hand without the `(period, period_start, currency, provider)` unique index passes doctor and then breaks the upsert — create it with the generator. With `config.budgets.totals_source = :ledger`, doctor warns instead if a stale rollups table is found.

With `budgets.totals_source = :ledger`, a monthly budget read sums every call of the month, so its cost grows with the ledger even with the `tracked_at` index. `:cache` reads the finished days of the month from the rollups table and sums only today's calls, so a monthly read costs about as much as a daily one: on PostgreSQL with 1M calls in the month it took 7 ms instead of 35 ms. The finished days are trusted as the rollups hold them, and the rollups count only calls recorded while `:cache` is on. Once `:cache` is deployed, run `bin/rails llm_cost_tracker:rebuild_rollups` at a quiet time (a call recorded while it writes can be missed), and again if the log reports a failed rollup increment; until then earlier days of the month are under-counted.

For strict quotas, use provider-side limits or a transactional counter in your own app.
