# Streaming Capture

Streaming calls should appear in the ledger instead of disappearing into a live
callback. LLM Cost Tracker records them when the provider emits final usage or
when the app supplies explicit totals.

The full streaming reference is moving here from the README: Faraday streaming,
`track_stream`, provider response IDs, final usage events, and data-quality
states.

## Canonical Sources

Until this page is expanded, use:

- [Capturing calls](../README.md#capturing-calls)
- [Known limitations](../README.md#known-limitations)
- [Cookbook](cookbook.md)

## Faraday Path

The middleware tees Faraday's `on_data` callback, keeps chunks flowing to the
caller, and records usage when the response completes.

OpenAI streams need final usage:

```ruby
stream_options: { include_usage: true }
```

Anthropic and Gemini are parsed from their provider stream event shapes when
usage is present.

## SDK Path

Official OpenAI and Anthropic SDK streams are captured when `config.instrument`
is enabled for the provider. The returned stream object is preserved, and usage
is recorded after the stream is consumed.

```ruby
config.instrument :openai
config.instrument :anthropic
```

Captured SDK helpers:

- OpenAI `responses.stream`, `responses.stream_raw`, `responses.retrieve_streaming`, and `chat.completions.stream_raw`.
- Anthropic `messages.stream` and `messages.stream_raw`.

OpenAI Chat Completions streams need final usage:

```ruby
stream_options: { include_usage: true }
```

## Manual Path

```ruby
LlmCostTracker.track_stream(provider: "openai", model: "gpt-4o") do |stream|
  my_client.stream(...) { |event| stream.event(event.to_h) }
end
```

If the client already knows totals, skip provider event parsing:

```ruby
stream.usage(input_tokens: 120, output_tokens: 45)
```

Missing final usage is stored with `usage_source: "unknown"` so the Data Quality
page can surface it.
