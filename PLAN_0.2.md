# llm_cost_tracker v0.2.0 Plan

## Goal

Ship an opt-in Rails dashboard engine:

```ruby
require "llm_cost_tracker/engine"

mount LlmCostTracker::Engine => "/llm-costs"
```

The dashboard is read-only and shows where a Rails app spends money on LLM APIs:

- spend over time
- top models
- recent calls
- call details
- tag breakdowns such as `feature`
- optional monthly budget status

The first milestone is a useful Overview page that can be used as the README screenshot.

## Non-Goals

These are intentionally out of scope for v0.2.0:

- built-in authorization
- CSV or JSON export
- alerts, webhooks, or Slack notifications
- JavaScript charts or live updates
- editing settings from the dashboard
- persistent budget models
- `/budgets`
- `/tags` index or automatic tag-key discovery
- timezone-aware SQL bucketing
- hourly period grouping
- SaaS or remote sync

## Compatibility Decisions

### Core Gem

The core gem remains lightweight and usable outside Rails:

- keep `activesupport >= 7.0, < 9.0`
- do not add `railties` as a runtime dependency
- keep middleware-only usage working for plain Faraday, Sinatra, Hanami, and service objects

### Dashboard Engine

The Engine is Rails-only and opt-in:

- users must `require "llm_cost_tracker/engine"`
- Engine requires Rails 7.1+
- the Rails version guard must run at top level in `engine.rb`, before defining `class Engine < ::Rails::Engine`
- `railties` is a development/test dependency only

Example guard:

```ruby
unless Gem::Version.new(Rails.version) >= Gem::Version.new("7.1.0")
  raise LlmCostTracker::Error, "LlmCostTracker::Engine requires Rails 7.1+"
end
```

## Phase 1: Public Query Primitive

Add SQL-side period grouping to `LlmCostTracker::LlmApiCall`.

### API

```ruby
LlmCostTracker::LlmApiCall.group_by_period(:day).sum(:total_cost)
LlmCostTracker::LlmApiCall.group_by_period(:month).count
LlmCostTracker::LlmApiCall.group_by_period(:day, column: :created_at)
```

Default column: `:tracked_at`.

### Supported Periods

Only:

- `:day`
- `:month`

Do not add `:hour` or `:week` in v0.2.0.

### Return Keys

Return string keys across all adapters:

```ruby
:day   # "2026-04-18"
:month # "2026-04"
```

### SQL Strategy

- PostgreSQL: `TO_CHAR(DATE_TRUNC(...), ...)`
- MySQL: `DATE_FORMAT(...)`
- SQLite: `strftime(...)`

### Validation

- period must be whitelisted
- column must exist in `column_names`
- invalid period or column raises `ArgumentError`
- no `time_zone:` parameter in v0.2.0

### Tests

- real SQLite grouping specs
- generated SQL expression specs for PostgreSQL/MySQL if those adapters are not in CI
- injection tests for period and column
- composition test:

```ruby
LlmCostTracker::LlmApiCall
  .this_month
  .by_provider("openai")
  .group_by_period(:day)
  .sum(:total_cost)
```

## Phase 2: Engine Skeleton

Add the minimal Rails Engine structure:

```text
lib/llm_cost_tracker/engine.rb
app/controllers/llm_cost_tracker/application_controller.rb
app/controllers/llm_cost_tracker/dashboard_controller.rb
app/views/layouts/llm_cost_tracker/application.html.erb
config/routes.rb
spec/dummy/
```

### Requirements

- isolated namespace: `isolate_namespace LlmCostTracker`
- no automatic loading for non-Rails users
- no asset pipeline dependency
- no JavaScript
- inline CSS in the Engine layout
- all CSS classes prefixed with `.lct-`
- minimal `spec/dummy` Rails app for Engine request specs

### Acceptance

- dummy app mounts the Engine at `/llm-costs`
- `GET /llm-costs` returns 200
- empty database shows an intentional empty state
- missing `llm_api_calls` table shows a friendly setup error

## Phase 3: Dashboard Data Layer

Use plain Ruby objects under:

```text
app/services/llm_cost_tracker/dashboard/
```

### Filter

Parses dashboard params and returns an ActiveRecord relation.

Supported params:

- `from`
- `to`
- `provider`
- `model`
- `tag[key]=value`

Rules:

- parse `from` and `to` with `Date.iso8601`
- ignore invalid dates
- use AR placeholders for provider/model
- parse all `params[:tag]` keys as a hash
- pass multi-key tag filters to `by_tags`
- validate tag keys with the same whitelist as `group_by_tag`

Example:

```text
?tag[feature]=chat&tag[user_id]=42
```

becomes:

```ruby
scope.by_tags("feature" => "chat", "user_id" => "42")
```

### Page

Use a small immutable object, not a large service:

```ruby
Dashboard::Page = Data.define(:page, :per)
```

Rules:

- `page` minimum: 1
- `per` default: 50
- `per` maximum: 200
- expose `limit`, `offset`, `prev_page?`, and `next_page?`

### OverviewStats

Compute:

- total spend
- total calls
- average cost per call
- average latency only if `latency_ms` exists
- monthly budget status only if `LlmCostTracker.configuration.monthly_budget` is set

Do not compute `known_pricing_rate` in v0.2.0.

### TimeSeries

Uses `group_by_period(:day).sum(:total_cost)`.

Rules:

- default range: last 30 days
- fill missing days with zero
- output array:

```ruby
[{ label: "2026-04-01", cost: 0.0 }]
```

### TopModels

Compute:

- provider
- model
- calls
- total cost
- average cost per call
- input tokens
- output tokens
- average latency if available

### TopTags

Only for configured keys.

Default keys:

```ruby
["feature"]
```

No automatic tag-key discovery in v0.2.0.

## Phase 4: Dashboard Pages

### Overview: `GET /`

The main screenshot-worthy page.

Show:

- total spend
- total calls
- average cost per call
- average latency if available
- monthly budget status if configured
- daily spend table with CSS bars
- top 5 models
- cost by `feature` tag if data exists

Budget wording:

> Soft monthly limit. Blocking is not atomic under concurrency.

### Calls Index: `GET /calls`

Filters:

- `from`
- `to`
- `provider`
- `model`
- `tag[key]=value`
- `page`
- `per`

Columns:

- created_at
- provider
- model
- input tokens
- output tokens
- cache tokens if present
- total cost
- latency if available
- tags summary
- details link

Rules:

- newest first
- max `per=200`
- one count query and one paginated query
- no N+1 behavior

### Call Details: `GET /calls/:id`

Show:

- all stored columns
- token breakdown
- cost breakdown
- latency if available
- tags as pretty JSON
- metadata if present

Missing records render a friendly 404 inside the Engine layout.

### Models: `GET /models`

Show rows grouped by provider/model:

- provider
- model
- calls
- total cost
- average cost per call
- input tokens
- output tokens
- average latency if available

Default sort: total cost descending.

### Tag Breakdown: `GET /tags/:key`

Validate `key` using the same tag-key whitelist as `group_by_tag`.

Show:

- tag value
- calls
- total cost
- average cost per call

Invalid keys render a friendly 400.

Do not add `/tags` index in v0.2.0.

## Graceful Degradation

The dashboard must not explode when optional pieces are missing.

Handle:

- empty database
- missing `llm_api_calls` table
- missing `latency_ms`
- text `tags` fallback instead of JSONB
- malformed legacy tag JSON
- unknown-pricing rows with `total_cost = nil`
- no configured monthly budget

## Security

- dashboard is read-only
- routes are GET-only
- keep `protect_from_forgery with: :exception`
- no built-in auth
- README must show Basic Auth and Devise examples
- validate every param through `Dashboard::Filter`
- do not log full tags or request details from the Engine

README warning:

> Do not expose this dashboard publicly. Tags may contain internal user, tenant, or feature identifiers.

## Styling

- ERB templates
- no JS
- no external fonts
- no external CSS
- no Chart.js
- no Tailwind dependency
- inline `<style>` in layout
- `.lct-` class prefix
- CSS bar charts through inline custom properties

Example:

```html
<div class="lct-bar" style="--lct-width: 73%"></div>
```

## Testing Plan

### Core Specs

- `group_by_period(:day)`
- `group_by_period(:month)`
- invalid period
- invalid column
- composition with existing scopes

### Engine Request Specs

- `/` empty DB
- `/` seeded DB
- `/calls`
- `/calls` filters narrow results
- `/calls/:id`
- `/calls/:missing`
- `/models`
- `/tags/feature`
- invalid tag key returns 400
- missing table renders setup error

### Service Specs

- `Dashboard::Filter`
- `Dashboard::Page`
- `Dashboard::TimeSeries`
- `Dashboard::OverviewStats`
- `Dashboard::TopModels`
- `Dashboard::TopTags`

### CI

- Ruby 3.1, 3.2, 3.3
- Rails Engine specs on Rails 7.1, 7.2, 8.0
- SQLite default
- PostgreSQL job for period grouping and tag grouping
- MySQL best-effort only; not required for v0.2.0 CI

## Documentation

README additions:

- Dashboard quick start
- mount snippet
- Basic Auth snippet
- Devise snippet
- warning not to expose dashboard publicly
- note that Engine requires Rails 7.1+
- note that core middleware remains usable without Rails

## Release Strategy

1. Work on `codex/engine-dashboard`.
2. Implement `group_by_period`.
3. Add Engine skeleton.
4. Build Overview first.
5. Build Calls index.
6. Build Call details.
7. Build Models.
8. Build `/tags/:key`.
9. Dogfood in a real Rails app.
10. Release `0.2.0.alpha1`.
11. Fix issues from real usage.
12. Release `0.2.0.rc1`.
13. Release final `0.2.0`.

## v0.2.0 Acceptance Criteria

The release is ready when:

- `group_by_period(:day/:month)` is tested and documented
- Engine is opt-in and requires Rails 7.1+
- non-Rails core usage does not gain Rails runtime dependencies
- `/llm-costs` renders without JS or asset pipeline dependencies
- empty DB and missing table states are friendly
- seeded dashboard shows useful spend data
- filters cannot SQL-inject
- Overview is good enough for README screenshot
- README includes auth snippets
- full test suite and RuboCop pass
- alpha has been tested in one real Rails app
