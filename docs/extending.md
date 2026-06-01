# Extending LLM Cost Tracker

Extensions belong at clear boundaries: OpenAI-compatible host mappings, local
price registries, notification subscribers, and explicit tracking calls for
unsupported response shapes.

## Supported Extension Points

| Need | Extension point |
| --- | --- |
| Gateway speaks OpenAI-compatible HTTP | `config.openai_compatible_providers` |
| Gateway or contract rates differ from bundled prices | `prices_file` or `pricing_overrides` |
| Unsupported client has known usage totals | `LlmCostTracker.track` |
| Unsupported stream exposes provider events | `LlmCostTracker.track_stream` |
| App needs attribution dimensions | Tags |
| App needs budget alerts | `on_budget_exceeded` |
| App wants event notifications | `ActiveSupport::Notifications` subscriber |

Storage backends, parser registries, and arbitrary SDK registration hooks are not
public extension points. Unsupported shapes should use explicit tracking until
they become first-class built-ins.

## OpenAI-Compatible Gateways

Use host mapping only when the gateway speaks OpenAI-compatible request and
response shapes:

```ruby
LlmCostTracker.configure do |config|
  config.openai_compatible_providers["llm.internal.example"] = "internal_gateway"
end
```

This affects provider identity and parser selection. It does not define prices.

## Local Prices

Use `config.prices_file` for a source-controlled JSON/YAML registry:

```ruby
config.prices_file = Rails.root.join("config/llm_cost_tracker_prices.yml")
```

Use `config.pricing_overrides` for small Ruby-side overrides:

```ruby
config.pricing_overrides = {
  "internal_gateway/my-model" => {
    input: 1.00,
    output: 2.00
  }
}
```

Canonical token price keys are owned by `Usage::Dimension`:

| Component | Registry key |
| --- | --- |
| Input text tokens | `input` |
| Output text tokens | `output` |
| Cache reads | `cache_read_input` |
| Standard cache writes | `cache_write_input` |
| Extended cache writes | `cache_write_extended_input` |
| Audio input tokens | `audio_input` |
| Audio output tokens | `audio_output` |

Mode-prefixed forms use the same base terms: `batch_input`,
`priority_output`, `flex_audio_input`, `data_residency_cache_read_input`, and
similar keys.

Long-context tiers use `_context_price_threshold_tokens` and `above_context_*`
fields.

Tool and runtime rates (web search, code execution, grounding, container
sessions, file search) live under `service_charges`:

```yaml
service_charges:
  openai:
    web_search_request: 10.0
    file_search_call: 2.5
  anthropic:
    web_search_request: 10.0
```

These keys map to `Usage::Dimension` entries with matching names. Add a rate
only when the captured quantity matches the published or contract basis.

## Explicit Tracking

For unsupported non-streaming clients:

```ruby
LlmCostTracker.track(
  provider: "custom",
  model: "gateway-model",
  tokens: { input_tokens: 1_000, output_tokens: 200 },
  tags: { feature: "summarizer" }
)
```

To attach tool / runtime charges (web search, code execution, container
sessions, …) alongside tokens, pass `service_line_items:` with one hash per
component:

```ruby
LlmCostTracker.track(
  provider: "custom",
  model: "gateway-model",
  tokens: { input_tokens: 1_000, output_tokens: 200 },
  service_line_items: [
    { component_key: :web_search_request, quantity: 3, provider_field: "tool_calls" }
  ],
  tags: { feature: "research" }
)
```

`component_key` must match an entry in `Usage::Dimension`.

For unsupported streams:

```ruby
LlmCostTracker.track_stream(provider: "openai", model: "gpt-4o") do |stream|
  client.each_event { |event| stream.event(event.to_h) }
end
```

Use provider-neutral token names when calling explicit APIs. Provider field names
belong at the translation boundary.

## Notifications

LLM Cost Tracker emits `llm_request.llm_cost_tracker` through
`ActiveSupport::Notifications` after event build. Subscribers receive the
canonical event payload — token usage, tags, pricing status, and the priced
line items (tokens + tool/runtime charges in one shape).

## Dashboard Extensions

Dashboard additions should be read-only services under
`app/services/llm_cost_tracker/dashboard`, with thin controllers and ERB views.
Do not add JavaScript for dashboard behavior.
