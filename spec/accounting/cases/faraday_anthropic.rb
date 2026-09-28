# frozen_string_literal: true

module AccountingCases
  define_case "faraday anthropic messages: dated sonnet-4-5 response" do
    faraday_json(ANTHROPIC_MESSAGES, anthropic_request("claude-sonnet-4-5"),
                 anthropic_message(id: "msg_fa1", model: "claude-sonnet-4-5-20250929",
                                   usage: anthropic_usage(2000, 500)))
  end

  define_case "faraday anthropic messages: 5m and 1h cache writes with cache reads" do
    usage = anthropic_usage(200, 500, cache_read: 30_000, cache_5m: 4000, cache_1h: 6000)
    faraday_json(ANTHROPIC_MESSAGES, anthropic_request("claude-sonnet-4-6"),
                 anthropic_message(id: "msg_fa2", model: "claude-sonnet-4-6", usage: usage))
  end

  define_case "faraday anthropic messages: cache write total without breakdown" do
    usage = { input_tokens: 200, output_tokens: 500, cache_read_input_tokens: 1000, cache_creation_input_tokens: 5000 }
    faraday_json(ANTHROPIC_MESSAGES, anthropic_request("claude-haiku-4-5"),
                 anthropic_message(id: "msg_fa3", model: "claude-haiku-4-5", usage: usage))
  end

  define_case "faraday anthropic messages: cache write total above its 5m and 1h breakdown" do
    usage = anthropic_usage(200, 500, cache_5m: 1000, cache_1h: 2000).merge(cache_creation_input_tokens: 4500)
    faraday_json(ANTHROPIC_MESSAGES, anthropic_request("claude-sonnet-4-6"),
                 anthropic_message(id: "msg_fa4", model: "claude-sonnet-4-6", usage: usage))
  end

  define_case "faraday anthropic messages: cache write total below its 5m and 1h breakdown" do
    usage = anthropic_usage(200, 500, cache_5m: 1000, cache_1h: 2000).merge(cache_creation_input_tokens: 2500)
    faraday_json(ANTHROPIC_MESSAGES, anthropic_request("claude-sonnet-4-6"),
                 anthropic_message(id: "msg_fa4b", model: "claude-sonnet-4-6", usage: usage))
  end

  define_case "faraday anthropic messages: thinking content with thinking token details" do
    usage = anthropic_usage(120, 900).merge(output_tokens_details: { thinking_tokens: 640 })
    content = [{ type: "thinking", thinking: "hmm", signature: "sig" }, { type: "text", text: "ok" }]
    faraday_json(ANTHROPIC_MESSAGES,
                 anthropic_request("claude-opus-4-6", thinking: { type: "enabled", budget_tokens: 2048 }),
                 anthropic_message(id: "msg_fa5", model: "claude-opus-4-6", usage: usage, content: content))
  end

  define_case "faraday anthropic messages: web search and web fetch requests" do
    usage = anthropic_usage(8000, 700).merge(server_tool_use: { web_search_requests: 2, web_fetch_requests: 1 })
    faraday_json(ANTHROPIC_MESSAGES,
                 anthropic_request("claude-sonnet-4-5", tools: [{ type: "web_search_20250305", name: "web_search" }]),
                 anthropic_message(id: "msg_fa6", model: "claude-sonnet-4-5", usage: usage))
  end

  define_case "faraday anthropic messages: served on priority" do
    faraday_json(ANTHROPIC_MESSAGES, anthropic_request("claude-sonnet-4-5", service_tier: "auto"),
                 anthropic_message(id: "msg_fa7", model: "claude-sonnet-4-5",
                                   usage: anthropic_usage(2000, 500, extra: { service_tier: "priority" })))
  end

  define_case "faraday anthropic messages: served on the batch tier" do
    faraday_json(ANTHROPIC_MESSAGES, anthropic_request("claude-sonnet-4-5"),
                 anthropic_message(id: "msg_fa8", model: "claude-sonnet-4-5",
                                   usage: anthropic_usage(2000, 500, extra: { service_tier: "batch" })))
  end

  define_case "faraday anthropic messages: us inference geo with cache reads" do
    usage = anthropic_usage(10_000, 1000, cache_read: 5000, extra: { inference_geo: "us" })
    faraday_json(ANTHROPIC_MESSAGES, anthropic_request("claude-sonnet-4-6", inference_geo: "us"),
                 anthropic_message(id: "msg_fa9", model: "claude-sonnet-4-6", usage: usage))
  end

  define_case "faraday anthropic messages: global inference geo" do
    faraday_json(ANTHROPIC_MESSAGES, anthropic_request("claude-sonnet-4-6"),
                 anthropic_message(id: "msg_fa10", model: "claude-sonnet-4-6",
                                   usage: anthropic_usage(10_000, 1000, extra: { inference_geo: "global" })))
  end

  define_case "faraday anthropic messages: fast speed on opus-4-6" do
    faraday_json(ANTHROPIC_MESSAGES, anthropic_request("claude-opus-4-6", speed: "fast"),
                 anthropic_message(id: "msg_fa11", model: "claude-opus-4-6",
                                   usage: anthropic_usage(10_000, 1000, extra: { speed: "fast" })))
  end

  define_case "faraday anthropic messages: fast speed on opus-5-5" do
    faraday_json(ANTHROPIC_MESSAGES, anthropic_request("claude-opus-5-5", speed: "fast"),
                 anthropic_message(id: "msg_fa12", model: "claude-opus-5-5",
                                   usage: anthropic_usage(10_000, 1000, extra: { speed: "fast" })))
  end

  define_case "faraday anthropic messages: fast requested but standard served" do
    faraday_json(ANTHROPIC_MESSAGES, anthropic_request("claude-opus-5-5", speed: "fast"),
                 anthropic_message(id: "msg_fa13", model: "claude-opus-5-5",
                                   usage: anthropic_usage(10_000, 1000, extra: { speed: "standard" })))
  end

  define_case "faraday anthropic messages: sonnet-4-5 with 250K input tokens" do
    faraday_json(ANTHROPIC_MESSAGES, anthropic_request("claude-sonnet-4-5"),
                 anthropic_message(id: "msg_fa14", model: "claude-sonnet-4-5", usage: anthropic_usage(250_000, 4000)))
  end

  define_case "faraday anthropic messages: claude-3-haiku dated id" do
    faraday_json(ANTHROPIC_MESSAGES, anthropic_request("claude-3-haiku-20240307"),
                 anthropic_message(id: "msg_fa15", model: "claude-3-haiku-20240307",
                                   usage: anthropic_usage(2000, 500, cache_5m: 100)))
  end

  define_case "faraday anthropic count_tokens: records nothing" do
    faraday_json("https://api.anthropic.com/v1/messages/count_tokens", anthropic_request("claude-sonnet-4-5"),
                 { input_tokens: 1234 })
  end

  define_case "faraday anthropic stream: dated sonnet-4-5" do
    faraday_sse(ANTHROPIC_MESSAGES, anthropic_request("claude-sonnet-4-5", stream: true),
                anthropic_stream_body(id: "msg_fs1", model: "claude-sonnet-4-5-20250929",
                                      start_usage: anthropic_usage(2000, 1), delta_usage: { output_tokens: 480 }))
  end

  define_case "faraday anthropic stream: cache writes grow after message_start" do
    start = { input_tokens: 79, cache_creation_input_tokens: 2600, cache_read_input_tokens: 0,
              cache_creation: { ephemeral_5m_input_tokens: 0, ephemeral_1h_input_tokens: 2600 }, output_tokens: 3 }
    delta = { input_tokens: 79, cache_creation_input_tokens: 7924, cache_read_input_tokens: 2600, output_tokens: 510,
              server_tool_use: { web_search_requests: 1 } }
    faraday_sse(ANTHROPIC_MESSAGES, anthropic_request("claude-sonnet-4-6", stream: true),
                anthropic_stream_body(id: "msg_fs2", model: "claude-sonnet-4-6", start_usage: start, delta_usage: delta,
                                      blocks: [%w[server_tool_use weather], %w[text Sunny]]))
  end

  define_case "faraday anthropic stream: message_delta repeats the full usage" do
    start = anthropic_usage(500, 1, cache_read: 1000, cache_5m: 300, cache_1h: 200)
    delta = anthropic_usage(500, 800, cache_read: 1000, cache_5m: 300, cache_1h: 200)
    faraday_sse(ANTHROPIC_MESSAGES, anthropic_request("claude-sonnet-4-5", stream: true),
                anthropic_stream_body(id: "msg_fs3", model: "claude-sonnet-4-5", start_usage: start,
                                      delta_usage: delta))
  end

  define_case "faraday anthropic stream: thinking blocks" do
    faraday_sse(ANTHROPIC_MESSAGES,
                anthropic_request("claude-opus-4-6", stream: true, thinking: { type: "enabled", budget_tokens: 4000 }),
                anthropic_stream_body(id: "msg_fs4", model: "claude-opus-4-6", start_usage: anthropic_usage(900, 1),
                                      delta_usage: { output_tokens: 3000 }, blocks: [%w[thinking hmm], %w[text ok]]))
  end

  define_case "faraday anthropic stream: fast requested but standard served" do
    faraday_sse(ANTHROPIC_MESSAGES, anthropic_request("claude-opus-4-6", stream: true, speed: "fast"),
                anthropic_stream_body(id: "msg_fs5", model: "claude-opus-4-6",
                                      start_usage: { input_tokens: 20_000, output_tokens: 1, speed: "standard" },
                                      delta_usage: { output_tokens: 2000 }))
  end

  define_case "faraday anthropic stream: fast requested with usage without speed" do
    faraday_sse(ANTHROPIC_MESSAGES, anthropic_request("claude-opus-5-5", stream: true, speed: "fast"),
                anthropic_stream_body(id: "msg_fs6", model: "claude-opus-5-5",
                                      start_usage: { input_tokens: 20_000, output_tokens: 1 },
                                      delta_usage: { output_tokens: 2000 }))
  end

  define_case "faraday anthropic stream: no message_delta usage" do
    message = { id: "msg_fs7", type: "message", role: "assistant", model: "claude-sonnet-4-5", content: [],
                usage: { input_tokens: 10, output_tokens: 1 } }
    faraday_sse(ANTHROPIC_MESSAGES, anthropic_request("claude-sonnet-4-5", stream: true),
                sse(["message_start", { type: "message_start", message: message }],
                    ["message_stop", { type: "message_stop" }]))
  end

  define_case "faraday anthropic stream: us inference geo in message_start usage" do
    faraday_sse(ANTHROPIC_MESSAGES, anthropic_request("claude-opus-4-6", stream: true, inference_geo: "us"),
                anthropic_stream_body(id: "msg_fs8", model: "claude-opus-4-6",
                                      start_usage: { input_tokens: 5000, output_tokens: 1, inference_geo: "us",
                                                     service_tier: "standard" },
                                      delta_usage: { output_tokens: 700 }))
  end

  define_case "faraday anthropic stream: read through an on_data callback" do
    faraday_sse(ANTHROPIC_MESSAGES, anthropic_request("claude-haiku-4-5", stream: true),
                anthropic_stream_body(id: "msg_fs9", model: "claude-haiku-4-5",
                                      start_usage: anthropic_usage(3000, 1, cache_5m: 1000),
                                      delta_usage: { output_tokens: 250 }), on_data: true)
  end

  define_case "faraday anthropic messages: us inference geo with web search requests" do
    usage = anthropic_usage(8000, 700, extra: { inference_geo: "us", server_tool_use: { web_search_requests: 3 } })
    faraday_json(ANTHROPIC_MESSAGES, anthropic_request("claude-sonnet-4-6"),
                 anthropic_message(id: "msg_wsus", model: "claude-sonnet-4-6", usage: usage))
  end

  define_case "faraday anthropic messages: code execution requests" do
    server_tool_use = { web_search_requests: 0, code_execution_requests: 2 }
    usage = anthropic_usage(8000, 700, extra: { server_tool_use: server_tool_use })
    faraday_json(ANTHROPIC_MESSAGES, anthropic_request("claude-sonnet-4-5"),
                 anthropic_message(id: "msg_ce", model: "claude-sonnet-4-5", usage: usage))
  end

  define_case "faraday anthropic messages: sonnet-5 executor with an opus-5 advisor" do
    faraday_json(ANTHROPIC_MESSAGES, anthropic_request("claude-sonnet-5"),
                 anthropic_message(id: "msg_adv1", model: "claude-sonnet-5", usage: advisor_usage))
  end

  define_case "faraday anthropic stream: advisor iterations in message_delta" do
    faraday_sse(ANTHROPIC_MESSAGES, anthropic_request("claude-sonnet-5", stream: true),
                anthropic_stream_body(id: "msg_adv4", model: "claude-sonnet-5", delta_usage: advisor_usage,
                                      start_usage: { input_tokens: 1_760, cache_read_input_tokens: 412,
                                                     output_tokens: 1 }))
  end

  define_case "faraday anthropic messages: advisor iterations with us inference geo" do
    faraday_json(ANTHROPIC_MESSAGES, anthropic_request("claude-sonnet-5"),
                 anthropic_message(id: "msg_adv8", model: "claude-sonnet-5", usage: advisor_usage(inference_geo: "us")))
  end

  define_case "faraday anthropic messages: fast opus-5 executor with a fable-5-1 advisor" do
    usage = { input_tokens: 2_000, output_tokens: 300, speed: "fast",
              iterations: [{ type: "advisor_message", model: "claude-fable-5-1", input_tokens: 1_500,
                             output_tokens: 1_000 }] }
    faraday_json(ANTHROPIC_MESSAGES, anthropic_request("claude-opus-5", speed: "fast"),
                 anthropic_message(id: "msg_adv9", model: "claude-opus-5", usage: usage))
  end

  define_case "faraday anthropic messages: advisor on an unpriced model" do
    faraday_json(ANTHROPIC_MESSAGES, anthropic_request("claude-sonnet-5"),
                 anthropic_message(id: "msg_adv10", model: "claude-sonnet-5",
                                   usage: advisor_usage(advisor: "claude-mystery-9")))
  end

  define_case "faraday anthropic messages: advisor on an unpriced model with unknown models raising",
              configure: ->(config) { config.pricing.unknown_model_behavior = :raise } do
    expect do
      faraday_json(ANTHROPIC_MESSAGES, anthropic_request("claude-sonnet-5"),
                   anthropic_message(id: "msg_adv11", model: "claude-sonnet-5",
                                     usage: advisor_usage(advisor: "claude-mystery-9")))
    end.to raise_error(LlmCostTracker::UnknownPricingError)
  end

  define_case "faraday anthropic messages: server-side fallback after partial output" do
    faraday_json(ANTHROPIC_MESSAGES, anthropic_request("claude-fable-5-1"),
                 anthropic_message(id: "msg_fb1", model: "claude-opus-4-8", usage: FALLBACK_AFTER_OUTPUT_USAGE))
  end

  define_case "faraday anthropic messages: server-side fallback on a bio refusal before output" do
    content = [{ type: "fallback", from: { model: "claude-fable-5" }, to: { model: "claude-opus-4-8" },
                 trigger: { type: "refusal", category: "bio" } }, { type: "text", text: "Hi" }]
    usage = { input_tokens: 412, output_tokens: 264,
              iterations: [{ type: "message", model: "claude-fable-5", input_tokens: 535, output_tokens: 0 },
                           { type: "fallback_message", model: "claude-opus-4-8", input_tokens: 412,
                             output_tokens: 264 }] }
    faraday_json(ANTHROPIC_MESSAGES, anthropic_request("claude-fable-5"),
                 anthropic_message(id: "msg_fb2", model: "claude-opus-4-8", usage: usage, content: content))
  end

  define_case "faraday anthropic messages: server-side fallback model refuses too" do
    content = [{ type: "fallback", from: { model: "claude-opus-6" }, to: { model: "claude-opus-5" },
                 trigger: { type: "refusal", category: "bio" } }]
    usage = { input_tokens: 2_400, output_tokens: 0,
              iterations: [{ type: "message", model: "claude-opus-6", input_tokens: 2_400, output_tokens: 0 },
                           { type: "fallback_message", model: "claude-opus-5", input_tokens: 2_400,
                             output_tokens: 0 }] }
    message = anthropic_message(id: "msg_fb4", model: "claude-opus-5", usage: usage, content: content,
                                stop_reason: "refusal")
    faraday_json(ANTHROPIC_MESSAGES, anthropic_request("claude-opus-6"),
                 message.merge(stop_details: { type: "refusal", category: "cyber" }))
  end
end
