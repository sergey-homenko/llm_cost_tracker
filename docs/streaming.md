# Streaming Capture

Streaming calls are recorded when the provider emits final usage, when the SDK
wrapper can collect final usage events, or when the app supplies explicit totals.
Missing final usage becomes an unknown-cost stream row instead of disappearing.

## Faraday Streaming

The Faraday middleware tees `on_data`, keeps chunks flowing to the caller, and
records usage after the response completes.

OpenAI Chat Completions streaming needs:

```ruby
stream_options: { include_usage: true }
```

Without the final usage chunk, the event is stored with
`usage_source: "unknown"` and appears on Data Quality.

Gemini `streamGenerateContent` and Anthropic streaming responses are parsed from
their provider event shapes when usage metadata is present.

OpenAI Realtime WebSocket/WebRTC sessions are not normal Faraday responses. Use
explicit `track_stream` and pass final `response.done` events when you need
Realtime capture.

## SDK Streaming

Official OpenAI and Anthropic SDK streams are captured when the provider
integration is enabled:

```ruby
LlmCostTracker.configure do |config|
  config.instrument :openai
  config.instrument :anthropic
end
```

Captured SDK helpers:

| Provider | Helpers |
| --- | --- |
| OpenAI | `responses.stream`, `responses.stream_raw`, `responses.retrieve_streaming`, `chat.completions.stream_raw` |
| Anthropic | `messages.stream`, `messages.stream_raw`, beta Messages stream helpers |

The returned stream object is preserved. Usage is recorded after the stream is
consumed.

Tags are snapshotted when the stream starts, so delayed or cross-thread
consumption keeps the original request/user attribution.

## Explicit Streaming

Use `track_stream` when the client has no built-in integration and no Faraday
hook:

```ruby
LlmCostTracker.track_stream(provider: "openai", model: "gpt-4o", tags: { feature: "chat" }) do |stream|
  my_client.stream(...) { |event| stream.event(event.to_h) }
end
```

The provider parser is selected by `provider:`. Parsed stream events can set
model, response ID, usage source, token buckets, pricing mode, and service
charges when the event shape exposes them.

If the client already knows totals, pass explicit usage instead of provider
events:

```ruby
LlmCostTracker.track_stream(provider: "custom", model: "gateway-model") do |stream|
  stream.usage(
    input_tokens: 120,
    output_tokens: 45,
    cache_read_input_tokens: 20,
    provider_response_id: "resp_123",
    provider_project_id: "proj_123",
    batch: true
  )
end
```

`stream.usage` accepts token fields owned by `TokenUsage`, plus
provider response and grouping dimensions.

## Data Quality

Stream rows include:

| Field | Meaning |
| --- | --- |
| `stream` | `true` for captured streaming calls |
| `usage_source` | `stream_final`, `manual`, or `unknown` |
| `provider_response_id` | Provider ID when exposed |
| `provider_project_id`, `provider_api_key_id`, `provider_workspace_id`, `batch` | Provider grouping dimensions when captured |
| `cost_status` | `free`, `complete`, `partial`, or `unknown` |

The collector bounds captured event bytes so a long stream cannot grow memory
without limit. When the cap is hit, already-buffered events stay available to
the parser; the call is recorded as unknown only when no usage can be extracted
from the retained prefix.
