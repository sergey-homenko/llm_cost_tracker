# Cookbook

Short integration recipes for common Ruby clients. Prefer SDK integrations or middleware. Use `track` and `track_stream` only as fallback helpers for unsupported clients.

| Client | Best path | Why |
|---|---|---|
| RubyLLM | `config.instrument :ruby_llm` | The integration wraps RubyLLM's provider layer without adding a third-party instrumentation gem. |
| Official `openai` gem | `config.instrument :openai` | The integration wraps SDK resource methods without changing call sites. |
| Official `anthropic` gem | `config.instrument :anthropic` | The integration records returned message usage without changing call sites. |
| `ruby-openai` | Faraday middleware | The client is built on Faraday and accepts middleware via the constructor block. |
| Groq | Faraday middleware | Groq's official SDKs are Python and JavaScript/TypeScript; Ruby uses the OpenAI-compatible HTTP path. |
| OpenAI-compatible proxy | Faraday middleware | Point a Faraday connection at the proxy host. |
| Custom Faraday client | Faraday middleware | The middleware can parse known provider responses automatically. |
| Other clients | Explicit tracking | Use `track` or `track_stream` when the client has no supported SDK/Faraday hook. |

## RubyLLM

Enable the integration once, then keep normal RubyLLM calls unchanged.

```ruby
LlmCostTracker.configure do |config|
  config.instrument :ruby_llm
end

LlmCostTracker.with_tags(feature: "support_chat") do
  RubyLLM.chat.ask("Hello")
  RubyLLM.embed("text to embed")
end
```

The RubyLLM integration supports `ruby_llm >= 1.15.0` and checks RubyLLM's provider contract at boot. Chat, embedding, transcription, image generation, and moderation calls are captured. Tool execution that runs through chat completions is captured as additional chat rows, not as a separate tool ledger row.

## Official OpenAI SDK

Enable the integration once, then keep normal `openai` gem calls unchanged.

```ruby
LlmCostTracker.configure do |config|
  config.instrument :openai
end

client = OpenAI::Client.new(api_key: ENV["OPENAI_API_KEY"])

client.responses.create(model: "gpt-4o", input: "Hello")
client.chat.completions.create(
  model: "gpt-4o",
  messages: [{ role: "user", content: "Hello" }]
)

client.responses.stream(model: "gpt-4o", input: "Hello").each do |event|
  puts event.type
end

client.responses.stream_raw(model: "gpt-4o", input: "Hello").each do |event|
  puts event.type
end

client.chat.completions.stream_raw(
  model: "gpt-4o",
  messages: [{ role: "user", content: "Hello" }],
  stream_options: { include_usage: true }
).each do |event|
  puts event
end
```

The OpenAI SDK integration supports `openai >= 0.59.0`. Streaming calls are recorded after the returned stream is consumed. Chat Completions streams need `stream_options: { include_usage: true }` for final usage.

## OpenAI Realtime

Realtime WebSocket/WebRTC sessions do not flow through the Faraday middleware. Capture final `response.done` events explicitly:

```ruby
LlmCostTracker.track_stream(provider: "openai", model: "gpt-realtime-1.5", tags: { feature: "voice" }) do |stream|
  realtime_session.on(:response_done) { |event| stream.event(event.to_h, type: "response.done") }
end
```

The OpenAI parser reads Realtime `input_token_details.audio_tokens` and `output_token_details.audio_tokens` from the final response usage.

## Official Anthropic SDK

Enable the integration once, then keep normal `anthropic` gem calls unchanged.

```ruby
LlmCostTracker.configure do |config|
  config.instrument :anthropic
end

client = Anthropic::Client.new(api_key: ENV["ANTHROPIC_API_KEY"])

client.messages.create(
  max_tokens: 1024,
  model: "claude-sonnet-4-6",
  messages: [{ role: "user", content: "Hello" }]
)

client.messages.stream(
  max_tokens: 1024,
  model: "claude-sonnet-4-6",
  messages: [{ role: "user", content: "Hello" }]
).each do |event|
  puts event.type
end

client.messages.stream_raw(
  max_tokens: 1024,
  model: "claude-sonnet-4-6",
  messages: [{ role: "user", content: "Hello" }]
).each do |event|
  puts event.type
end
```

The Anthropic SDK integration supports `anthropic >= 1.36.0`. Streaming calls are recorded after the returned stream is consumed.

## ruby-openai

`ruby-openai` is a community client that occupies the same `OpenAI::Client` constant as the official gem; only one of the two can be loaded. `config.instrument :openai` is for the official gem. For `ruby-openai`, attach the Faraday middleware via the constructor block:

```ruby
client = OpenAI::Client.new(access_token: ENV["OPENAI_API_KEY"]) do |f|
  f.use :llm_cost_tracker, tags: { feature: "chat" }
end

client.chat(
  parameters: {
    model: "gpt-4o",
    messages: [{ role: "user", content: "Hello" }],
    stream: proc { |chunk| puts chunk.dig("choices", 0, "delta", "content") },
    stream_options: { include_usage: true }
  }
)
```

Use the constructor block for each client, or wrap client creation in an app factory.

## Groq

Groq is auto-detected on `api.groq.com`. The official `openai` gem does not use Faraday, so reach Groq through a Faraday connection of your own:

```ruby
client = Faraday.new(url: "https://api.groq.com/openai/v1") do |f|
  f.request :json
  f.response :json
  f.use :llm_cost_tracker, tags: { feature: "chat" }
  f.adapter Faraday.default_adapter
end

client.post("chat/completions") do |req|
  req.headers["Authorization"] = "Bearer #{ENV.fetch('GROQ_API_KEY')}"
  req.body = {
    model: "openai/gpt-oss-20b",
    messages: [{ role: "user", content: "Hello" }],
    service_tier: "on_demand"
  }
end
```

## Azure OpenAI

Azure's classic deployment endpoints (`/openai/deployments/{name}/...`) and the v1 endpoints (`/openai/v1/...`) are both captured out of the box on the `*.openai.azure.com` and `*.services.ai.azure.com` hostnames — no `capture.openai_compatible_providers` registration needed. Keep Azure-specific deltas in `pricing.overrides` with the `azure_openai/<model>` prefix; everything else falls back to the matching `openai/<model>` entry.

```ruby
conn = Faraday.new(url: "https://my-resource.openai.azure.com") do |f|
  f.use :llm_cost_tracker, tags: { feature: "chat" }
  f.request :json
  f.response :json
  f.adapter Faraday.default_adapter
end

conn.post(
  "/openai/v1/responses",
  { model: "gpt-4o-prod", input: "Hello" },
  { "api-key" => ENV.fetch("AZURE_OPENAI_API_KEY") }
)
```

## Gemini API

Google's official Gemini SDKs do not include Ruby. Use a Faraday client against the REST API so the Gemini parser can capture usage automatically.

```ruby
conn = Faraday.new(url: "https://generativelanguage.googleapis.com") do |f|
  f.use :llm_cost_tracker, tags: { feature: "chat" }
  f.request :json
  f.response :json
  f.adapter Faraday.default_adapter
end

conn.post(
  "/v1beta/models/gemini-2.5-flash:generateContent?key=#{ENV.fetch("GOOGLE_API_KEY")}",
  { contents: [{ role: "user", parts: [{ text: "Hello" }] }] }
)
```

## LiteLLM proxy

LiteLLM Proxy speaks an OpenAI-compatible HTTP shape, so register the proxy host once and keep using the normal middleware path.

```ruby
LlmCostTracker.configure do |config|
  config.capture.openai_compatible_providers["proxy.internal.example"] = "litellm"
end

client = Faraday.new(url: "https://proxy.internal.example") do |f|
  f.request :json
  f.response :json
  f.use :llm_cost_tracker, tags: { gateway: "litellm" }
  f.adapter Faraday.default_adapter
end

client.post("chat/completions") do |req|
  req.headers["Authorization"] = "Bearer #{ENV.fetch('LITELLM_API_KEY')}"
  req.body = { model: "openai/gpt-5-mini", messages: [{ role: "user", content: "Hello" }] }
end
```

If your proxy exposes custom model IDs or discounts, add them in `pricing.file` or `pricing.overrides`.
