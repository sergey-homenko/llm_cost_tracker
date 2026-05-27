# Streaming Capture

Streams record when the provider emits final usage, when the SDK wrapper
collects final usage events, or when the app passes explicit totals. Missing
final usage becomes an unknown-cost stream row instead of vanishing.

## Faraday Streaming

The Faraday middleware tees `on_data`, keeps chunks flowing to the caller, and
records usage after the response completes.

OpenAI Chat Completions streaming (and OpenAI-compatible gateways such as
OpenRouter, DeepSeek, Groq, and any host configured under
`config.openai_compatible_providers`) needs:

```ruby
stream_options: { include_usage: true }
```

The gem auto-injects this flag for you when:

- `config.auto_enable_stream_usage` is `true` (the default)
- the matched parser is OpenAI or OpenAI-compatible
- the URL ends with `/chat/completions`
- the request body is JSON with `stream: true`
- the caller has not already set `stream_options.include_usage` (any
  explicit value, including `false`, is preserved)

Other entries inside `stream_options` are merged, not replaced. Bodies
that aren't JSON, requests for the Responses API, and non-streaming
requests are left untouched.

Set `config.auto_enable_stream_usage = false` if you want to manage the
flag yourself; in that case, when the final usage chunk is missing the
gem still records the call with `usage_source: "unknown"` and emits a
warning rather than failing silently:

```
[LlmCostTracker] OpenAI-compatible chat-completions stream finished without
a final usage chunk. Set `stream_options: { include_usage: true }` in your
request body so the gem can record token counts. This call was stored with
usage_source=unknown.
```

The Responses API and the official OpenAI SDK streaming helpers do not
need the flag — usage is emitted automatically.

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
| OpenAI | `responses.stream`, `responses.stream_raw`, `responses.retrieve_streaming`, `chat.completions.stream`, `chat.completions.stream_raw`, `images.generate_stream_raw`, `images.edit_stream_raw`, `audio.transcriptions.create_streaming` |
| Anthropic | `messages.stream`, `messages.stream_raw`, beta Messages stream helpers |
| RubyLLM | `RubyLLM::Provider#complete` (captured for both blocking and streaming calls; `Chat#ask` reaches this transitively) |

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
line items when the event shape exposes them.

If the client already knows totals, pass explicit usage instead of provider
events:

```ruby
LlmCostTracker.track_stream(
  provider: "custom",
  model: "gateway-model",
  pricing_mode: :batch
) do |stream|
  stream.usage(
    input_tokens: 120,
    output_tokens: 45,
    cache_read_input_tokens: 20,
    provider_response_id: "resp_123",
    provider_project_id: "proj_123"
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
| `provider_project_id`, `provider_api_key_id`, `provider_workspace_id` | Provider grouping dimensions when captured |
| `batch` | Derived from `pricing_mode` (true when the mode contains the `batch` token); set `pricing_mode: :batch` on `track_stream` to flag a batch-tier call |
| `cost_status` | `free`, `complete`, `partial`, or `unknown` |

The collector caps captured event bytes so a long stream can't grow memory
unbounded. When the cap hits, the call is recorded with `usage_source:
unknown` regardless of what was buffered — partial-prefix usage extraction
is intentionally disabled because the prefix shape is provider-specific
and inferring totals from a truncated stream is unsafe. Image and audio
event payloads (`b64_json`, `partial_image_b64`, any single string field
over 8 KB) are dropped before the cap is consulted, so a multi-megabyte
image chunk doesn't push the trailing `usage` event past the limit.
