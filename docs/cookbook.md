# Cookbook

Short integration recipes for common Ruby clients. Prefer SDK integrations or middleware. Use `track` and `track_stream` only as fallback helpers for unsupported clients.

| Client | Best path | Why |
|---|---|---|
| Official `openai` gem | `config.instrument :openai` | The SDK uses `net/http`, so LLM Cost Tracker wraps the SDK resource methods. |
| Official `anthropic` gem | `config.instrument :anthropic` | The SDK uses `net/http`, so LLM Cost Tracker records returned message usage. |
| `ruby-openai` | Faraday middleware | The client is built on Faraday and accepts middleware via the constructor block. |
| OpenAI-compatible proxy | Faraday middleware | Use `ruby-openai` or a direct Faraday client against the proxy host. |
| Custom Faraday client | Faraday middleware | The middleware can parse known provider responses automatically. |
| Other clients | Adapter first, fallback helpers second | Add a stable integration instead of scattering per-call ledger code. |

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
```

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
```

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

Azure's v1 API works with OpenAI-compatible HTTP shapes, but pricing and deployment names are yours. Use the Faraday middleware path and keep Azure-specific prices in `prices_file` or `pricing_overrides`.

```ruby
client = OpenAI::Client.new(
  access_token: ENV["AZURE_OPENAI_API_KEY"],
  uri_base: "#{ENV.fetch("AZURE_OPENAI_BASE_URL")}/openai/v1/"
) do |f|
  f.use :llm_cost_tracker, tags: { feature: "chat" }
end

client.responses.create(parameters: { model: "gpt-4o-prod", input: "Hello" })
```

## Gemini API

Google does not currently publish an official Ruby SDK for the Gemini API. Use a Faraday client against the REST API so the Gemini parser can capture usage automatically.

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
