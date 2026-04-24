# Cookbook

Short integration recipes for common Ruby clients. Use middleware when the client exposes Faraday. Use `track` or `track_stream` when it does not.

## ruby-openai

`ruby-openai` already lets you patch the Faraday stack, so auto-capture is the clean path.

```ruby
OpenAI.configure do |config|
  config.access_token = ENV["OPENAI_API_KEY"]
  config.faraday do |f|
    f.use :llm_cost_tracker, tags: -> { { feature: "chat", user_id: Current.user&.id } }
  end
end

client = OpenAI::Client.new
client.chat(
  parameters: {
    model: "gpt-4o",
    messages: [{ role: "user", content: "Hello" }],
    stream: proc { |chunk, _bytesize| puts chunk.dig("choices", 0, "delta", "content") },
    stream_options: { include_usage: true }
  }
)
```

## anthropic-sdk-ruby

The official Anthropic SDK does not go through Faraday, so wrap the SSE loop with `track_stream`.

```ruby
client = Anthropic::Client.new(api_key: ENV["ANTHROPIC_API_KEY"])

LlmCostTracker.track_stream(provider: "anthropic", model: "claude-sonnet-4-5-20250929") do |stream|
  response = client.messages.stream(
    max_tokens: 1024,
    model: :"claude-sonnet-4-5-20250929",
    messages: [{ role: :user, content: "Hello" }]
  )

  response.each { |event| stream.event(event.to_h) }
end
```

## gemini-ai

`gemini-ai` can stream raw Gemini events, which LLM Cost Tracker already knows how to parse.

```ruby
client = Gemini.new(
  credentials: {
    service: "generative-language-api",
    api_key: ENV["GOOGLE_API_KEY"]
  },
  options: { model: "gemini-2.5-flash", server_sent_events: true }
)

LlmCostTracker.track_stream(provider: "gemini", model: "gemini-2.5-flash") do |stream|
  events = client.stream_generate_content(
    contents: { role: "user", parts: { text: "Hello" } }
  )

  events.each { |event| stream.event(event) }
end
```

## langchainrb

Langchain.rb already gives you provider-neutral token totals on the response object. Record them at the boundary where you call the LLM.

```ruby
llm = Langchain::LLM::OpenAI.new(
  api_key: ENV["OPENAI_API_KEY"],
  default_options: { chat_model: "gpt-4o" }
)

result = llm.chat(messages: [{ role: "user", content: "Hello" }])

LlmCostTracker.track(
  provider: "openai",
  model: "gpt-4o",
  input_tokens: result.prompt_tokens,
  output_tokens: result.completion_tokens,
  feature: "chat"
)
```

Swap `Langchain::LLM::OpenAI` for `Langchain::LLM::Anthropic` or `Langchain::LLM::GoogleGemini` and keep the ledger call the same.

## Azure OpenAI

Azure's v1 API works with the OpenAI client shape, but pricing and deployment names are yours. Track it explicitly and keep Azure-specific prices in `prices_file` or `pricing_overrides`.

```ruby
client = OpenAI::Client.new(
  base_url: "#{ENV.fetch("AZURE_OPENAI_BASE_URL")}/openai/v1/",
  api_key: ENV["AZURE_OPENAI_API_KEY"]
)

LlmCostTracker.track_stream(provider: "azure_openai", model: "gpt-4o-prod") do |stream|
  response = client.responses.create(
    model: "gpt-4o-prod",
    input: "Hello",
    stream: true
  )

  response.each { |event| stream.event(event.to_h) }
end
```

## LiteLLM proxy

LiteLLM Proxy speaks an OpenAI-compatible HTTP shape, so register the proxy host once and keep using the normal middleware path.

```ruby
LlmCostTracker.configure do |config|
  config.openai_compatible_providers["proxy.internal.example"] = "litellm"
end

OpenAI.configure do |config|
  config.access_token = ENV["LITELLM_API_KEY"]
  config.uri_base = "https://proxy.internal.example"
  config.faraday do |f|
    f.use :llm_cost_tracker, tags: -> { { gateway: "litellm" } }
  end
end

client = OpenAI::Client.new
client.chat(parameters: { model: "openai/gpt-5-mini", messages: [{ role: "user", content: "Hello" }] })
```

If your proxy exposes custom model IDs or discounts, add them in `prices_file` or `pricing_overrides`.
