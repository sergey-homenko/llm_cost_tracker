# Cookbook

Short integration recipes for common Ruby clients. Prefer SDK integrations or middleware. Use `track` and `track_stream` only as fallback helpers for unsupported clients.

| Client | Best path | Why |
|---|---|---|
| RubyLLM | `config.instrument :ruby_llm` | The integration wraps RubyLLM's provider layer without adding a third-party instrumentation gem. |
| Official `openai` gem | `config.instrument :openai` | The integration wraps SDK resource methods without changing call sites. |
| Official `anthropic` gem | `config.instrument :anthropic` | The integration records returned message usage without changing call sites. |
| `ruby-openai` | Faraday middleware | The client is built on Faraday and accepts middleware via the constructor block. |
| OpenAI-compatible proxy | Faraday middleware | Use `ruby-openai` or a direct Faraday client against the proxy host. |
| Custom Faraday client | Faraday middleware | The middleware can parse known provider responses automatically. |
| Other clients | Adapter first, fallback helpers second | Add a stable integration instead of scattering per-call ledger code. |

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

The RubyLLM integration supports `ruby_llm >= 1.14.1` and checks RubyLLM's provider contract at boot. Chat, embedding, and transcription calls are captured. Image generation, moderation, and tool execution are not recorded as separate ledger rows.

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

## Official Anthropic SDK

Enable the integration once, then keep normal `anthropic` gem calls unchanged.

```ruby
LlmCostTracker.configure do |config|
  config.instrument :anthropic
end

client = Anthropic::Client.new(api_key: ENV["ANTHROPIC_API_KEY"])

client.messages.create(
  max_tokens: 1024,
  model: "claude-sonnet-4-5-20250929",
  messages: [{ role: "user", content: "Hello" }]
)

client.messages.stream(
  max_tokens: 1024,
  model: "claude-sonnet-4-5-20250929",
  messages: [{ role: "user", content: "Hello" }]
).each do |event|
  puts event.type
end

client.messages.stream_raw(
  max_tokens: 1024,
  model: "claude-sonnet-4-5-20250929",
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
    stream: proc { |chunk, _bytesize| puts chunk.dig("choices", 0, "delta", "content") },
    stream_options: { include_usage: true }
  }
)
```

Use the constructor block on every client you build, or wrap client creation in your own factory.

## Azure OpenAI

Azure's v1 API works with OpenAI-compatible HTTP shapes, but pricing and deployment names are yours. Register the Azure host, use the Faraday middleware path, and keep Azure-specific prices in `prices_file` or `pricing_overrides`.

```ruby
LlmCostTracker.configure do |config|
  config.openai_compatible_providers["my-resource.openai.azure.com"] = "azure_openai"
end

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
  config.openai_compatible_providers["proxy.internal.example"] = "litellm"
end

client = OpenAI::Client.new(
  access_token: ENV["LITELLM_API_KEY"],
  uri_base: "https://proxy.internal.example"
) do |f|
  f.use :llm_cost_tracker, tags: { gateway: "litellm" }
end

client.chat(parameters: { model: "openai/gpt-5-mini", messages: [{ role: "user", content: "Hello" }] })
```

If your proxy exposes custom model IDs or discounts, add them in `prices_file` or `pricing_overrides`.
