# frozen_string_literal: true

module AccountingCases
  def refusal_fallback_client
    Anthropic::Client.new(api_key: "sk-ant-test", max_retries: 0,
                          middleware: [Anthropic::BetaRefusalFallbackMiddleware.new([{ model: "claude-opus-4-8" }])])
  end

  def refusal_fallback_request
    anthropic_request("claude-fable-5-1", request_options: { fallback_state: Anthropic::BetaFallbackState.new })
  end

  def refusal(category, fallback_credit_token: "tok")
    { type: "refusal", category: category, explanation: nil, fallback_credit_token: fallback_credit_token,
      fallback_has_prefill_claim: false }
  end

  def refusal_fallback_reply(model, output_tokens, stop_details = nil, stream: false)
    usage = { input_tokens: 5_000, output_tokens: output_tokens }
    stop = { stop_reason: stop_details ? "refusal" : "end_turn", stop_details: stop_details }
    if stream
      body = anthropic_stream_body(id: "msg_css_#{model}", model: model, start_usage: usage.merge(output_tokens: 1),
                                   delta_usage: usage, blocks: output_tokens.zero? ? [] : [%w[text x]], delta: stop)
      return { status: 200, headers: { "Content-Type" => "text/event-stream" }, body: body }
    end
    content = output_tokens.zero? ? [] : [{ type: "text", text: "x" }]
    message = anthropic_message(id: "msg_cs_#{model}", model: model, usage: usage, content: content).merge(stop)
    { status: 200, headers: JSON_HEADERS, body: JSON.generate(message) }
  end

  def stub_refusal_fallback(*replies)
    WebMock.stub_request(:post, %r{\Ahttps://api\.anthropic\.com/v1/messages}).to_return(*replies)
  end

  define_case "anthropic sdk messages: 5m and 1h cache writes with cache reads", instrument: :anthropic do
    usage = anthropic_usage(120, 35, cache_read: 50, cache_5m: 20, cache_1h: 10)
    stub_json(:post, ANTHROPIC_MESSAGES,
              anthropic_message(id: "msg_s1", model: "claude-sonnet-4-5-20250929", usage: usage))
    anthropic_client.messages.create(**anthropic_request)
  end

  define_case "anthropic sdk messages: cache write total above its breakdown", instrument: :anthropic do
    usage = anthropic_usage(200, 500, cache_5m: 1000, cache_1h: 2000).merge(cache_creation_input_tokens: 4500)
    stub_json(:post, ANTHROPIC_MESSAGES, anthropic_message(id: "msg_s1b", model: "claude-sonnet-4-6", usage: usage))
    anthropic_client.messages.create(**anthropic_request("claude-sonnet-4-6"))
  end

  define_case "anthropic sdk messages: thinking token details", instrument: :anthropic do
    usage = { input_tokens: 120, output_tokens: 90, output_tokens_details: { thinking_tokens: 64 } }
    stub_json(:post, ANTHROPIC_MESSAGES,
              anthropic_message(id: "msg_s2", model: "claude-sonnet-4-5-20250929", usage: usage))
    anthropic_client.messages.create(**anthropic_request)
  end

  define_case "anthropic sdk messages: served on priority", instrument: :anthropic do
    stub_json(:post, ANTHROPIC_MESSAGES,
              anthropic_message(id: "msg_s3", model: "claude-sonnet-4-5-20250929",
                                usage: anthropic_usage(100, 30, extra: { service_tier: "priority" })))
    anthropic_client.messages.create(**anthropic_request)
  end

  define_case "anthropic sdk messages: served on the batch tier", instrument: :anthropic do
    stub_json(:post, ANTHROPIC_MESSAGES,
              anthropic_message(id: "msg_s4", model: "claude-sonnet-4-5-20250929",
                                usage: anthropic_usage(100, 30, extra: { service_tier: "batch" })))
    anthropic_client.messages.create(**anthropic_request)
  end

  define_case "anthropic sdk messages: fast and us requested on opus-4-6 with us reported", instrument: :anthropic do
    stub_json(:post, ANTHROPIC_MESSAGES,
              anthropic_message(id: "msg_s5", model: "claude-opus-4-6",
                                usage: { input_tokens: 100, output_tokens: 30, inference_geo: "us" }))
    anthropic_client.messages.create(**anthropic_request("claude-opus-4-6", speed: "fast", inference_geo: "us"))
  end

  define_case "anthropic sdk messages: fast served on opus-5-5", instrument: :anthropic do
    stub_json(:post, ANTHROPIC_MESSAGES,
              anthropic_message(id: "msg_s5b", model: "claude-opus-5-5",
                                usage: anthropic_usage(10_000, 1000, extra: { speed: "fast" })))
    anthropic_client.messages.create(**anthropic_request("claude-opus-5-5", speed: "fast"))
  end

  define_case "anthropic sdk messages: web search and web fetch requests", instrument: :anthropic do
    usage = { input_tokens: 100, output_tokens: 30,
              server_tool_use: { web_search_requests: 2, web_fetch_requests: 1 } }
    stub_json(:post, ANTHROPIC_MESSAGES,
              anthropic_message(id: "msg_s6", model: "claude-sonnet-4-5-20250929", usage: usage))
    anthropic_client.messages.create(**anthropic_request)
  end

  define_case "anthropic sdk messages: sonnet-4-6 with 400K input tokens", instrument: :anthropic do
    stub_json(:post, ANTHROPIC_MESSAGES,
              anthropic_message(id: "msg_s7", model: "claude-sonnet-4-6",
                                usage: anthropic_usage(400_000, 3000, cache_read: 100_000)))
    anthropic_client.messages.create(**anthropic_request("claude-sonnet-4-6"))
  end

  define_case "anthropic sdk beta messages: opus-4-6 with 1h cache writes", instrument: :anthropic do
    usage = anthropic_usage(3000, 800, cache_1h: 5000)
    message = anthropic_message(id: "msg_s8", model: "claude-opus-4-6", usage: usage)
    stub_json(:post, %r{api\.anthropic\.com/v1/messages}, message)
    anthropic_client.beta.messages.create(**anthropic_request("claude-opus-4-6"), betas: ["context-1m-2025-08-07"])
  end

  define_case "anthropic sdk stream helper: dated sonnet-4-5", instrument: :anthropic do
    stub_sse(:post, ANTHROPIC_MESSAGES,
             anthropic_stream_body(id: "msg_ss1", model: "claude-sonnet-4-5-20250929",
                                   start_usage: { input_tokens: 120, output_tokens: 1 },
                                   delta_usage: { output_tokens: 64 }))
    anthropic_client.messages.stream(**anthropic_request).each { nil }
  end

  define_case "anthropic sdk stream_raw: haiku-4-5 with cache reads and writes", instrument: :anthropic do
    stub_sse(:post, ANTHROPIC_MESSAGES,
             anthropic_stream_body(id: "msg_ss2", model: "claude-haiku-4-5",
                                   start_usage: anthropic_usage(3000, 1, cache_read: 2000, cache_5m: 500),
                                   delta_usage: { output_tokens: 300 }))
    anthropic_client.messages.stream_raw(**anthropic_request("claude-haiku-4-5")).each { nil }
  end

  define_case "anthropic sdk stream helper: cache writes grow after message_start", instrument: :anthropic do
    start = { input_tokens: 79, cache_creation_input_tokens: 2600, cache_read_input_tokens: 0,
              cache_creation: { ephemeral_5m_input_tokens: 0, ephemeral_1h_input_tokens: 2600 }, output_tokens: 3 }
    delta = { input_tokens: 79, cache_creation_input_tokens: 7924, cache_read_input_tokens: 2600, output_tokens: 510,
              server_tool_use: { web_search_requests: 1 } }
    stub_sse(:post, ANTHROPIC_MESSAGES,
             anthropic_stream_body(id: "msg_ss3", model: "claude-sonnet-4-6", start_usage: start, delta_usage: delta,
                                   blocks: [%w[server_tool_use weather], %w[text Sunny]]))
    anthropic_client.messages.stream(**anthropic_request("claude-sonnet-4-6")).each { nil }
  end

  define_case "anthropic sdk stream helper: fast requested but standard served on opus-4-6",
              instrument: :anthropic do
    stub_sse(:post, ANTHROPIC_MESSAGES,
             anthropic_stream_body(id: "msg_ss4", model: "claude-opus-4-6",
                                   start_usage: { input_tokens: 20_000, output_tokens: 1, speed: "standard" },
                                   delta_usage: { output_tokens: 2000 }))
    anthropic_client.messages.stream(**anthropic_request("claude-opus-4-6", speed: "fast")).each { nil }
  end

  define_case "anthropic sdk stream helper: fast requested but standard served on opus-5-5",
              instrument: :anthropic do
    stub_sse(:post, ANTHROPIC_MESSAGES,
             anthropic_stream_body(id: "msg_ss4b", model: "claude-opus-5-5",
                                   start_usage: { input_tokens: 20_000, output_tokens: 1, speed: "standard" },
                                   delta_usage: { output_tokens: 2000 }))
    anthropic_client.messages.stream(**anthropic_request("claude-opus-5-5", speed: "fast")).each { nil }
  end

  define_case "anthropic sdk stream helper: fast requested with usage without speed", instrument: :anthropic do
    stub_sse(:post, ANTHROPIC_MESSAGES,
             anthropic_stream_body(id: "msg_ss5", model: "claude-opus-5-5",
                                   start_usage: { input_tokens: 20_000, output_tokens: 1 },
                                   delta_usage: { output_tokens: 2000 }))
    anthropic_client.messages.stream(**anthropic_request("claude-opus-5-5", speed: "fast")).each { nil }
  end

  define_case "anthropic sdk stream helper: auto tier requested and standard served", instrument: :anthropic do
    stub_sse(:post, ANTHROPIC_MESSAGES,
             anthropic_stream_body(id: "msg_ss6", model: "claude-sonnet-4-5",
                                   start_usage: { input_tokens: 5000, output_tokens: 1, service_tier: "standard" },
                                   delta_usage: { output_tokens: 500 }))
    anthropic_client.messages.stream(**anthropic_request("claude-sonnet-4-5", service_tier: :auto)).each { nil }
  end

  define_case "anthropic sdk stream helper: auto tier requested and priority served", instrument: :anthropic do
    stub_sse(:post, ANTHROPIC_MESSAGES,
             anthropic_stream_body(id: "msg_ss7", model: "claude-sonnet-4-5",
                                   start_usage: { input_tokens: 5000, output_tokens: 1, service_tier: "priority" },
                                   delta_usage: { output_tokens: 500 }))
    anthropic_client.messages.stream(**anthropic_request("claude-sonnet-4-5", service_tier: :auto)).each { nil }
  end

  define_case "anthropic sdk stream helper: us inference geo requested but not reported", instrument: :anthropic do
    stub_sse(:post, ANTHROPIC_MESSAGES,
             anthropic_stream_body(id: "msg_ss8", model: "claude-sonnet-4-6",
                                   start_usage: { input_tokens: 5000, output_tokens: 1 },
                                   delta_usage: { output_tokens: 500 }))
    anthropic_client.messages.stream(**anthropic_request("claude-sonnet-4-6", inference_geo: "us")).each { nil }
  end

  define_case "anthropic sdk stream helper: thinking blocks", instrument: :anthropic do
    stub_sse(:post, ANTHROPIC_MESSAGES,
             anthropic_stream_body(id: "msg_ss9", model: "claude-opus-4-6", start_usage: anthropic_usage(900, 1),
                                   delta_usage: { output_tokens: 3000 }, blocks: [%w[thinking hmm], %w[text ok]]))
    request = anthropic_request("claude-opus-4-6", thinking: { type: "adaptive" })
    anthropic_client.messages.stream(**request).each { nil }
  end

  define_case "anthropic sdk stream_raw: message_delta repeats the full usage with breakdown",
              instrument: :anthropic do
    start = anthropic_usage(500, 1, cache_read: 1000, cache_5m: 300, cache_1h: 200)
    delta = anthropic_usage(500, 800, cache_read: 1000, cache_5m: 300, cache_1h: 200)
    stub_sse(:post, ANTHROPIC_MESSAGES,
             anthropic_stream_body(id: "msg_sfd", model: "claude-sonnet-4-5", start_usage: start, delta_usage: delta))
    anthropic_client.messages.stream_raw(**anthropic_request("claude-sonnet-4-5")).each { nil }
  end

  define_case "anthropic sdk stream helper: message_delta with a grown total and its own breakdown",
              instrument: :anthropic do
    start = anthropic_usage(79, 3, cache_1h: 2600)
    delta = { input_tokens: 79, output_tokens: 510, cache_read_input_tokens: 2600, cache_creation_input_tokens: 7924,
              cache_creation: { ephemeral_5m_input_tokens: 5324, ephemeral_1h_input_tokens: 2600 } }
    stub_sse(:post, ANTHROPIC_MESSAGES,
             anthropic_stream_body(id: "msg_sdg", model: "claude-sonnet-4-6", start_usage: start, delta_usage: delta))
    anthropic_client.messages.stream(**anthropic_request("claude-sonnet-4-6")).each { nil }
  end

  define_case "anthropic sdk stream helper: fast and us served on opus-5-5", instrument: :anthropic do
    stub_sse(:post, ANTHROPIC_MESSAGES,
             anthropic_stream_body(id: "msg_sgf", model: "claude-opus-5-5",
                                   start_usage: { input_tokens: 10_000, output_tokens: 1, speed: "fast",
                                                  inference_geo: "us" },
                                   delta_usage: { output_tokens: 1000 }))
    anthropic_client.messages.stream(**anthropic_request("claude-opus-5-5", speed: "fast", inference_geo: "us"))
                    .each { nil }
  end

  define_case "anthropic sdk messages: fast requested but standard served", instrument: :anthropic do
    stub_json(:post, ANTHROPIC_MESSAGES,
              anthropic_message(id: "msg_crs", model: "claude-opus-5-5",
                                usage: anthropic_usage(10_000, 1000, extra: { speed: "standard" })))
    anthropic_client.messages.create(**anthropic_request("claude-opus-5-5", speed: "fast"))
  end

  define_case "anthropic sdk messages: fast requested with usage without speed", instrument: :anthropic do
    stub_json(:post, ANTHROPIC_MESSAGES,
              anthropic_message(id: "msg_crn", model: "claude-opus-5-5",
                                usage: { input_tokens: 10_000, output_tokens: 1000 }))
    anthropic_client.messages.create(**anthropic_request("claude-opus-5-5", speed: "fast"))
  end

  define_case "anthropic sdk messages: sonnet-5 executor with an opus-5 advisor", instrument: :anthropic do
    stub_json(:post, ANTHROPIC_MESSAGES,
              anthropic_message(id: "msg_adv2", model: "claude-sonnet-5", usage: advisor_usage))
    anthropic_client.messages.create(**anthropic_request("claude-sonnet-5"))
  end

  define_case "anthropic sdk stream helper: advisor iterations in message_delta", instrument: :anthropic do
    stub_sse(:post, ANTHROPIC_MESSAGES,
             anthropic_stream_body(id: "msg_adv3", model: "claude-sonnet-5",
                                   start_usage: { input_tokens: 1_760, cache_read_input_tokens: 412, output_tokens: 1 },
                                   delta_usage: advisor_usage))
    anthropic_client.messages.stream(**anthropic_request("claude-sonnet-5")).each { nil }
  end

  define_case "anthropic sdk stream helper: server-side fallback after partial output", instrument: :anthropic do
    stub_sse(:post, ANTHROPIC_MESSAGES,
             anthropic_stream_body(id: "msg_fb3", model: "claude-fable-5-1",
                                   start_usage: { input_tokens: 5_000, output_tokens: 1 },
                                   delta_usage: FALLBACK_AFTER_OUTPUT_USAGE))
    anthropic_client.messages.stream(**anthropic_request("claude-fable-5-1")).each { nil }
  end

  define_case "anthropic sdk refusal fallback middleware: bio refusal, then the fallback model",
              instrument: :anthropic do
    stub_refusal_fallback(refusal_fallback_reply("claude-fable-5-1", 0, refusal("bio")),
                          refusal_fallback_reply("claude-opus-4-8", 400))
    refusal_fallback_client.beta.messages.create(**refusal_fallback_request)
  end

  define_case "anthropic sdk refusal fallback middleware: cyber refusal, then the fallback model",
              instrument: :anthropic do
    stub_refusal_fallback(refusal_fallback_reply("claude-fable-5-1", 0, refusal("cyber")),
                          refusal_fallback_reply("claude-opus-4-8", 400))
    refusal_fallback_client.beta.messages.create(**refusal_fallback_request)
  end

  define_case "anthropic sdk refusal fallback middleware stream: bio refusal, then the fallback model",
              instrument: :anthropic do
    stub_refusal_fallback(refusal_fallback_reply("claude-fable-5-1", 0, refusal("bio"), stream: true),
                          refusal_fallback_reply("claude-opus-4-8", 400, stream: true))
    refusal_fallback_client.beta.messages.stream(**refusal_fallback_request).each { nil }
  end

  define_case "anthropic sdk refusal fallback middleware stream: cyber refusal after output, then the fallback model",
              instrument: :anthropic do
    stub_refusal_fallback(refusal_fallback_reply("claude-fable-5-1", 300, refusal("cyber"), stream: true),
                          refusal_fallback_reply("claude-opus-4-8", 400, stream: true))
    refusal_fallback_client.beta.messages.stream(**refusal_fallback_request).each { nil }
  end

  define_case "anthropic sdk refusal fallback middleware stream: every model refuses, then a plain stream",
              instrument: :anthropic do
    stub_refusal_fallback(
      refusal_fallback_reply("claude-fable-5-1", 0, refusal("bio"), stream: true),
      refusal_fallback_reply("claude-opus-4-8", 0, refusal("bio", fallback_credit_token: nil), stream: true),
      refusal_fallback_reply("claude-fable-5-1", 50, stream: true)
    )
    client = refusal_fallback_client
    2.times { client.beta.messages.stream(**refusal_fallback_request).each { nil } }
  end
end
